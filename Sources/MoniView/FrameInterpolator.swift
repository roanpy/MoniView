import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import VideoToolbox

enum FrameInterpolatorSupport {
    static let isSupported: Bool = {
        #if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
        if #available(macOS 26.0, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
        #endif
        return false
    }()
}

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
/// One midpoint, no frame queue or CPU/GPU wait. State and encoding are main-thread confined.
@available(macOS 26.0, *)
final class FrameInterpolator {
    private struct Key: Equatable { let width: Int; let height: Int }
    private enum Failure: Error { case unsupported }
    private struct PlaneTexture {
        let reference: CVMetalTexture
        let texture: MTLTexture
    }
    private struct ResampleInput {
        let sourceY: PlaneTexture
        let destinationY: PlaneTexture
        let sourceChroma: PlaneTexture
        let destinationChroma: PlaneTexture
        var references: [CVMetalTexture] {
            [sourceY.reference, destinationY.reference, sourceChroma.reference, destinationChroma.reference]
        }
    }
    private final class Session {
        let key: Key
        let processor: VTFrameProcessor
        let sourcePool: CVPixelBufferPool
        let destinationPool: CVPixelBufferPool
        let cache: CVMetalTextureCache
        let bgra: MTLTexture
        let convert: MTLComputePipelineState?
        let resize420v: MTLComputePipelineState?
        let cleanupQueue: DispatchQueue
        init(key: Key, device: MTLDevice, convert: MTLComputePipelineState?, resize420v: MTLComputePipelineState?, queue: DispatchQueue) throws {
            guard let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: key.width, frameHeight: key.height, numberOfInterpolatedFrames: 1),
                  config.supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                  convert != nil || resize420v != nil else { throw Failure.unsupported }
            sourcePool = try Self.pool(config.sourcePixelBufferAttributes)
            destinationPool = try Self.pool(config.destinationPixelBufferAttributes)
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw Failure.unsupported }
            self.cache = cache
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: key.width, height: key.height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.unsupported }
            bgra = texture
            let processor = VTFrameProcessor()
            do { try processor.startSession(configuration: config) }
            catch { processor.endSession(); throw error }
            self.processor = processor
            self.key = key
            self.convert = convert
            self.resize420v = resize420v
            cleanupQueue = queue
        }
        private static func pool(_ base: [String: Any]) throws -> CVPixelBufferPool {
            let extra: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var attributes: CFDictionary?
            guard CVPixelBufferCreateResolvedAttributesDictionary(nil, [base as CFDictionary, extra as CFDictionary] as CFArray, &attributes) == kCVReturnSuccess, let attributes else { throw Failure.unsupported }
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes, &pool) == kCVReturnSuccess, let pool else { throw Failure.unsupported }
            return pool
        }
        deinit { let processor = processor; cleanupQueue.async { processor.endSession() } }
    }
    private let device: MTLDevice
    private let convert: MTLComputePipelineState?
    private let resize420v: MTLComputePipelineState?
    private static let resize420vSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void resize420v(texture2d<float, access::sample> sourceY [[texture(0)]],
                               texture2d<float, access::write> destinationY [[texture(1)]],
                               texture2d<float, access::sample> sourceChroma [[texture(2)]],
                               texture2d<float, access::write> destinationChroma [[texture(3)]],
                               uint2 gid [[thread_position_in_grid]]) {
            constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            if (gid.x < destinationY.get_width() && gid.y < destinationY.get_height()) {
                float2 uv = (float2(gid) + 0.5f) / float2(destinationY.get_width(), destinationY.get_height());
                destinationY.write(sourceY.sample(linearSampler, uv), gid);
            }
            if (gid.x < destinationChroma.get_width() && gid.y < destinationChroma.get_height()) {
                float2 uv = (float2(gid) + 0.5f) / float2(destinationChroma.get_width(), destinationChroma.get_height());
                destinationChroma.write(sourceChroma.sample(linearSampler, uv), gid);
            }
        }
        """
    private let worker = DispatchQueue(label: "dev.moniview.frame-interpolation", qos: .userInitiated)
    private let videoSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private var session: Session?
    private var requested: Key?
    private var preparing = false
    private var generation: UInt64 = 0
    private var failed: Key?
    private var retryAfter = 0.0
    private var retryWakeup: DispatchWorkItem?
    var onStateChange: (() -> Void)?
    var isReady: Bool { dispatchPrecondition(condition: .onQueue(.main)); return session != nil && session?.key == requested }
    init(device: MTLDevice) {
        self.device = device
        let library = try? device.makeLibrary(source: AIUpscaler.converterSource, options: nil)
        convert = library?.makeFunction(name: "bgraTo420v").flatMap { try? device.makeComputePipelineState(function: $0) }
        let resizeLibrary = try? device.makeLibrary(source: Self.resize420vSource, options: nil)
        resize420v = resizeLibrary?.makeFunction(name: "resize420v").flatMap { try? device.makeComputePipelineState(function: $0) }
    }
    func prepare(width: Int, height: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else { stop(); return }
        let key = Key(width: width, height: height)
        if key != requested { requested = key; generation &+= 1; session = nil; failed = nil }
        guard session == nil, !preparing, convert != nil || resize420v != nil,
              failed != key || ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        preparing = true
        let expected = generation, device = device, worker = worker
        let convert = convert, resize420v = resize420v
        worker.async { [weak self] in
            let ready = try? Session(key: key, device: device, convert: convert, resize420v: resize420v, queue: worker)
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard self.generation == expected, self.requested == key else {
                    if self.requested != nil { self.onStateChange?() }; return
                }
                self.session = ready
                if ready == nil { self.fail(key) }
                self.onStateChange?()
            }
        }
    }
    private func fail(_ key: Key) {
        session = nil; failed = key
        retryAfter = ProcessInfo.processInfo.systemUptime + 3
        retryWakeup?.cancel()
        let expected = generation
        let wakeup = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, self.requested == key else { return }
            self.onStateChange?()
        }
        retryWakeup = wakeup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: wakeup)
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requested != nil || session != nil else { return }
        generation &+= 1; requested = nil; session = nil; failed = nil
        retryWakeup?.cancel(); retryWakeup = nil
    }

    private func hasAttachment(_ buffer: CVPixelBuffer, key: CFString, value: CFString) -> Bool {
        guard let attachment = CVBufferCopyAttachment(buffer, key, nil) else { return false }
        return CFEqual(attachment, value)
    }

    private func hasCenteredChromaLocation(_ buffer: CVPixelBuffer) -> Bool {
        for key in [kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey] {
            guard let location = CVBufferCopyAttachment(buffer, key, nil) else { continue }
            guard CFEqual(location, kCVImageBufferChromaLocation_Center) else { return false }
        }
        return true
    }

    private func isDirectInput(_ buffer: CVPixelBuffer, image: CIImage) -> Bool {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let extent = image.extent
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2, width >= 2, height >= 2, width % 2 == 0, height % 2 == 0,
              abs(extent.minX) < 0.001, abs(extent.minY) < 0.001,
              abs(extent.width - Double(width)) < 0.001, abs(extent.height - Double(height)) < 0.001,
              hasCenteredChromaLocation(buffer),
              hasAttachment(buffer, key: kCVImageBufferYCbCrMatrixKey, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2),
              hasAttachment(buffer, key: kCVImageBufferColorPrimariesKey, value: kCVImageBufferColorPrimaries_ITU_R_709_2),
              hasAttachment(buffer, key: kCVImageBufferTransferFunctionKey, value: kCVImageBufferTransferFunction_ITU_R_709_2) else { return false }
        if let orientation = CVBufferCopyAttachment(buffer, kCGImagePropertyOrientation, nil) {
            guard let number = orientation as? NSNumber,
                  number.uint32Value == CGImagePropertyOrientation.up.rawValue else { return false }
        }
        return true
    }

    private func planeTexture(buffer: CVPixelBuffer, cache: CVMetalTextureCache, format: MTLPixelFormat,
                              width: Int, height: Int, plane: Int) -> PlaneTexture? {
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane, &reference) == kCVReturnSuccess,
              let reference, let texture = CVMetalTextureGetTexture(reference) else { return nil }
        return PlaneTexture(reference: reference, texture: texture)
    }

    private func resampleInput(source: CVPixelBuffer, destination: CVPixelBuffer, cache: CVMetalTextureCache,
                               width: Int, height: Int) -> ResampleInput? {
        guard let sourceY = planeTexture(buffer: source, cache: cache, format: .r8Unorm,
                                        width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source), plane: 0),
              let destinationY = planeTexture(buffer: destination, cache: cache, format: .r8Unorm,
                                              width: width, height: height, plane: 0),
              let sourceChroma = planeTexture(buffer: source, cache: cache, format: .rg8Unorm,
                                              width: CVPixelBufferGetWidth(source) / 2, height: CVPixelBufferGetHeight(source) / 2, plane: 1),
              let destinationChroma = planeTexture(buffer: destination, cache: cache, format: .rg8Unorm,
                                                   width: width / 2, height: height / 2, plane: 1) else { return nil }
        return ResampleInput(sourceY: sourceY, destinationY: destinationY,
                             sourceChroma: sourceChroma, destinationChroma: destinationChroma)
    }

    private func encodeResample(_ input: ResampleInput, pipeline: MTLComputePipelineState,
                                width: Int, height: Int, command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input.sourceY.texture, index: 0)
        encoder.setTexture(input.destinationY.texture, index: 1)
        encoder.setTexture(input.sourceChroma.texture, index: 2)
        encoder.setTexture(input.destinationChroma.texture, index: 3)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        return true
    }

    /// Both unadjusted inputs are converted to the model's required SDR 420v pools on the
    /// caller's command buffer. Matching 420v/Rec.709 pixel buffers bypass RGB conversion;
    /// all other inputs keep the CI conversion path. Color/scale/sharpening are applied once
    /// after interpolation.
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer? = nil, currentBuffer: CVPixelBuffer? = nil,
                     fastInputResampling: Bool = false) -> CIImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session, session.key == requested, previousTime.isNumeric, currentTime.isNumeric, currentTime > previousTime else { return nil }
        let width = session.key.width, height = session.key.height
        var buffers: [CVPixelBuffer] = []
        for pool in [session.sourcePool, session.sourcePool, session.destinationPool] {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
                  CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
                  CVPixelBufferGetPlaneCount(buffer) == 2 else { return nil }
            for (key, value) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2), (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2), (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
                CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
            }
            buffers.append(buffer)
        }
        let midpoint = CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(CMTimeSubtract(currentTime, previousTime), multiplier: 0.5))
        guard let prior = VTFrameProcessorFrame(buffer: buffers[0], presentationTimeStamp: previousTime),
              let source = VTFrameProcessorFrame(buffer: buffers[1], presentationTimeStamp: currentTime),
              let output = VTFrameProcessorFrame(buffer: buffers[2], presentationTimeStamp: midpoint),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: source, previousFrame: prior, interpolationPhase: [0.5], destinationFrames: [output]) else { return nil }
        var textures: [CVMetalTexture] = []
        var tasks: [CIRenderTask] = []
        // Freeze complete lifetime ownership on every return, including partial encoding.
        defer { retain(session, parameters, buffers, textures, tasks, command: command) }
        var used420v = false
        if let previousBuffer, let currentBuffer, let resize420v,
           CVPixelBufferGetWidth(previousBuffer) == CVPixelBufferGetWidth(currentBuffer),
           CVPixelBufferGetHeight(previousBuffer) == CVPixelBufferGetHeight(currentBuffer),
           isDirectInput(previousBuffer, image: previous), isDirectInput(currentBuffer, image: current),
           let previousInput = resampleInput(source: previousBuffer, destination: buffers[0], cache: session.cache, width: width, height: height),
           let currentInput = resampleInput(source: currentBuffer, destination: buffers[1], cache: session.cache, width: width, height: height) {
            CVBufferPropagateAttachments(previousBuffer, buffers[0])
            CVBufferPropagateAttachments(currentBuffer, buffers[1])
            for buffer in buffers {
                for (key, value) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                                     (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                                     (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
                    CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
                }
            }
            buffers += [previousBuffer, currentBuffer]
            textures += previousInput.references + currentInput.references
            if encodeResample(previousInput, pipeline: resize420v, width: width, height: height, command: command),
               encodeResample(currentInput, pipeline: resize420v, width: width, height: height, command: command) {
                used420v = true
            }
        }
        if !used420v {
            guard let convert = session.convert else { return nil }
            for (index, image) in [previous, current].enumerated() {
                let input = buffers[index]
                var yRef: CVMetalTexture?, cRef: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, session.cache, input, nil, .r8Unorm, width, height, 0, &yRef) == kCVReturnSuccess, let yRef, let y = CVMetalTextureGetTexture(yRef),
                      CVMetalTextureCacheCreateTextureFromImage(nil, session.cache, input, nil, .rg8Unorm, width / 2, height / 2, 1, &cRef) == kCVReturnSuccess, let cRef, let c = CVMetalTextureGetTexture(cRef) else { return nil }
                let extent = image.extent
                guard extent.width > 0, extent.height > 0 else { return nil }
                var normalized = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                if extent.width != Double(width) || extent.height != Double(height) {
                    let verticalScale = Double(height) / extent.height
                    if fastInputResampling {
                        normalized = normalized.transformed(by: CGAffineTransform(scaleX: Double(width) / extent.width, y: verticalScale), highQualityDownsample: false)
                    } else {
                        normalized = normalized.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: verticalScale, kCIInputAspectRatioKey: (Double(width) / extent.width) / verticalScale])
                    }
                }
                let destination = CIRenderDestination(mtlTexture: session.bgra, commandBuffer: command)
                destination.colorSpace = videoSpace; destination.isFlipped = true
                do { tasks.append(try context.startTask(toRender: normalized, from: CGRect(x: 0, y: 0, width: width, height: height), to: destination, at: .zero)) }
                catch { fail(session.key); return nil }
                textures += [yRef, cRef]
                guard let encoder = command.makeComputeCommandEncoder() else { return nil }
                encoder.setComputePipelineState(convert)
                encoder.setTexture(session.bgra, index: 0); encoder.setTexture(y, index: 1); encoder.setTexture(c, index: 2)
                encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
                encoder.endEncoding()
            }
        }
        session.processor.process(with: command, parameters: parameters)
        return CIImage(cvPixelBuffer: buffers[2], options: [.colorSpace: videoSpace])
    }
    private func retain(_ owner: Session, _ parameters: VTLowLatencyFrameInterpolationParameters, _ buffers: [CVPixelBuffer], _ textures: [CVMetalTexture], _ tasks: [CIRenderTask], command: MTLCommandBuffer) {
        command.addCompletedHandler { [weak self] completed in
            withExtendedLifetime((owner, parameters, buffers, textures, tasks)) {}
            guard completed.status != .completed else { return }
            DispatchQueue.main.async {
                guard let self, self.session === owner else { return }
                self.fail(owner.key); self.onStateChange?()
            }
        }
    }
}
#else
@available(macOS 26.0, *)
final class FrameInterpolator {
    init(device: MTLDevice) {}
    var isReady: Bool { false }
    var onStateChange: (() -> Void)?
    func prepare(width: Int, height: Int) {}
    func stop() {}
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer? = nil, currentBuffer: CVPixelBuffer? = nil,
                     fastInputResampling: Bool = false) -> CIImage? { nil }
}
#endif
