import CoreImage
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// Runtime availability does not make new SDK symbols visible to older compilers.
/// Apple Swift 6.2 ships with SDK 26; custom toolchains can disable AI explicitly.
enum AIUpscalerSupport {
    static let isSupported: Bool = {
        #if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
        if #available(macOS 26.0, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        #endif
        return false
    }()
}

#if compiler(>=6.2) && !MONIVIEW_DISABLE_AI
@available(macOS 26.0, *)
final class AIUpscaler {
    /// Hardware scaler sessions accept bi-planar YUV only; forcing BGRA pools fails on device.
    /// The color-processed frame is converted inside the same command buffer, so the ML pass
    /// still runs in the preview's single-in-flight pipeline. BT.709 video range matches 420v.
    static let converterSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void bgraTo420v(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> yPlane [[texture(1)]],
                               texture2d<float, access::write> cPlane [[texture(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
            uint2 lp = gid * 2;
            float3 acc = float3(0);
            float ys[4];
            for (uint dy = 0; dy < 2; dy++) for (uint dx = 0; dx < 2; dx++) {
                float4 p = src.read(lp + uint2(dx, dy));
                float3 rgb = p.rgb; // Metal exposes logical RGBA even for BGRA storage.
                acc += rgb;
                float y = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b;
                ys[dy * 2 + dx] = (16.0 + 219.0 * y) / 255.0;
            }
            yPlane.write(float4(ys[0], 0, 0, 0), lp + uint2(0, 0));
            yPlane.write(float4(ys[1], 0, 0, 0), lp + uint2(1, 0));
            yPlane.write(float4(ys[2], 0, 0, 0), lp + uint2(0, 1));
            yPlane.write(float4(ys[3], 0, 0, 0), lp + uint2(1, 1));
            float3 m = acc * 0.25;
            float y = 0.2126 * m.r + 0.7152 * m.g + 0.0722 * m.b;
            float2 c = (128.0 + 224.0 * float2((m.b - y) / 1.8556, (m.r - y) / 1.5748)) / 255.0;
            cPlane.write(float4(c, 0, 0), gid);
        }
        """

    private struct Key: Equatable {
        let width: Int
        let height: Int
        let factor: Float
    }

    /// A session is prepared once, then used only by the main-thread draw path.
    /// Each submitted command retains it until completion, even after a setting changes.
    private final class Session {
        let key: Key
        let processor: VTFrameProcessor
        let sourcePool: CVPixelBufferPool
        let destinationPool: CVPixelBufferPool
        let textureCache: CVMetalTextureCache
        let bgra: MTLTexture
        let convert: MTLComputePipelineState
        private let cleanupQueue: DispatchQueue

        init(key: Key, device: MTLDevice, convert: MTLComputePipelineState, cleanupQueue: DispatchQueue) throws {
            guard key.width % 2 == 0, key.height % 2 == 0 else { throw SetupFailure.unavailable }
            let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: key.width, frameHeight: key.height, scaleFactor: key.factor)
            guard config.supportedPixelFormats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else { throw SetupFailure.unavailable }
            // Never override the pixel format: the hardware session dictates 420v bi-planar.
            let extra: [String: Any] = [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let source = try Self.makePool(config.sourcePixelBufferAttributes, extra: extra)
            let destination = try Self.makePool(config.destinationPixelBufferAttributes, extra: extra)
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw SetupFailure.unavailable }
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: key.width, height: key.height, mipmapped: false)
            textureDescriptor.storageMode = .private
            textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            guard let bgra = device.makeTexture(descriptor: textureDescriptor) else { throw SetupFailure.unavailable }
            let processor = VTFrameProcessor()
            do { try processor.startSession(configuration: config) }
            catch { processor.endSession(); throw error }
            self.key = key
            self.processor = processor
            sourcePool = source
            destinationPool = destination
            textureCache = cache
            self.bgra = bgra
            self.convert = convert
            self.cleanupQueue = cleanupQueue
        }

        private static func makePool(_ base: [String: Any], extra: [String: Any]) throws -> CVPixelBufferPool {
            var resolved: CFDictionary?
            guard CVPixelBufferCreateResolvedAttributesDictionary(nil, [base as CFDictionary, extra as CFDictionary] as CFArray, &resolved) == kCVReturnSuccess,
                  let resolved else { throw SetupFailure.unavailable }
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, resolved, &pool) == kCVReturnSuccess,
                  let pool else { throw SetupFailure.unavailable }
            return pool
        }

        deinit {
            // This cannot run until the last command retaining this session has completed.
            // Keep potentially expensive teardown away from capture, draw and UI queues.
            let processor = processor
            cleanupQueue.async { processor.endSession() }
        }
    }

    private enum SetupFailure: Error { case unavailable }
    private let videoColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
    private let device: MTLDevice
    private let convert: MTLComputePipelineState?
    private let prepareQueue = DispatchQueue(label: "dev.moniview.ai-upscale", qos: .userInitiated)
    // Everything below is main-thread only, including publication of prepared sessions.
    private var requestedKey: Key?
    private var session: Session?
    private var preparing = false
    private var generation: UInt64 = 0
    private var failedKey: Key?
    private var retryAfter = 0.0
    private var retryWakeup: DispatchWorkItem?
    var onStateChange: (() -> Void)?
    var isReady: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return session != nil && session?.key == requestedKey
    }

    init(device: MTLDevice) {
        self.device = device
        // Compile once; a failure permanently falls back to spatial scaling.
        let library = try? device.makeLibrary(source: AIUpscaler.converterSource, options: nil)
        let function = library?.makeFunction(name: "bgraTo420v")
        convert = function.flatMap { try? device.makeComputePipelineState(function: $0) }
    }

    /// Never exceed the caller's processing-size cap just to reach a supported AI factor.
    /// MetalFX/Lanczos remain available when no supported factor fits the requested budget.
    static func scaleFactor(for sourceWidth: Int, sourceHeight: Int, requested: Double) -> Float? {
        guard AIUpscalerSupport.isSupported, sourceWidth > 0, sourceHeight > 0, sourceWidth % 2 == 0, sourceHeight % 2 == 0, requested.isFinite else { return nil }
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: sourceWidth, frameHeight: sourceHeight)
            .filter { $0.isFinite && $0 > 1 && Double($0) <= requested + 0.000001 }
            .max()
    }

    func prepare(sourceWidth: Int, sourceHeight: Int, factor: Float, colorSpace: CGColorSpace) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(width: sourceWidth, height: sourceHeight, factor: factor)
        if requestedKey != key {
            requestedKey = key
            generation &+= 1
            session = nil // Never feed a new size into the previous session's pools.
            failedKey = nil
        }
        guard convert != nil, session == nil, !preparing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard failedKey != key || now >= retryAfter else { return }
        preparing = true
        let expectedGeneration = generation
        let device = device
        let convert = convert
        let queue = prepareQueue
        queue.async { [weak self] in
            let prepared = convert.flatMap { try? Session(key: key, device: device, convert: $0, cleanupQueue: queue) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard self.generation == expectedGeneration, self.requestedKey == key else {
                    // A newer request may have been blocked behind this single warmup.
                    if self.requestedKey != nil { self.onStateChange?() }
                    return
                }
                self.session = prepared
                if prepared != nil { self.onStateChange?() }
                if prepared == nil {
                    self.failedKey = key
                    // Only an actual failed attempt advances the deadline, not each arriving frame.
                    self.retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
                    self.scheduleRetryWakeup()
                }
            }
        }
    }

    private func scheduleRetryWakeup() {
        retryWakeup?.cancel()
        let expectedGeneration = generation
        let key = requestedKey
        let wakeup = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration, self.requestedKey == key, key != nil, self.session == nil else { return }
            self.onStateChange?() // Redraw the last frame; do not wait for a new capture callback.
        }
        retryWakeup = wakeup
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, retryAfter - ProcessInfo.processInfo.systemUptime), execute: wakeup)
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requestedKey != nil || session != nil else { return }
        retryWakeup?.cancel()
        retryWakeup = nil
        generation &+= 1 // Also invalidates a warmup that has not published a session yet.
        requestedKey = nil
        session = nil
        failedKey = nil
        // Leave preparing set until the outstanding attempt returns; at most one warmup exists.
    }

    func upscale(_ image: CIImage, context: CIContext, command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let session, session.key == requestedKey,
              Int(image.extent.width.rounded()) == session.key.width,
              Int(image.extent.height.rounded()) == session.key.height else { return nil }
        var sourceBuffer: CVPixelBuffer?
        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, session.sourcePool, &sourceBuffer) == kCVReturnSuccess, let sourceBuffer,
              CVPixelBufferPoolCreatePixelBuffer(nil, session.destinationPool, &destinationBuffer) == kCVReturnSuccess, let destinationBuffer else { return nil }
        let width = session.key.width
        let height = session.key.height
        guard CVPixelBufferGetPixelFormatType(sourceBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(sourceBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(sourceBuffer, 0) == width,
              CVPixelBufferGetHeightOfPlane(sourceBuffer, 0) == height,
              CVPixelBufferGetWidthOfPlane(sourceBuffer, 1) == width / 2,
              CVPixelBufferGetHeightOfPlane(sourceBuffer, 1) == height / 2,
              CVPixelBufferGetPixelFormatType(destinationBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(destinationBuffer) == Int(Float(width) * session.key.factor),
              CVPixelBufferGetHeight(destinationBuffer) == Int(Float(height) * session.key.factor) else { return nil }
        var yTextureRef: CVMetalTexture?
        var cTextureRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, sourceBuffer, nil, .r8Unorm, width, height, 0, &yTextureRef) == kCVReturnSuccess, let yTextureRef, let yTexture = CVMetalTextureGetTexture(yTextureRef),
              CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, sourceBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &cTextureRef) == kCVReturnSuccess, let cTextureRef, let cTexture = CVMetalTextureGetTexture(cTextureRef),
              let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: .zero) else { return nil }
        // Tell the scaler and Core Image how to interpret the YUV content.
        for buffer in [sourceBuffer, destinationBuffer] {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        // CVPixelBuffer rows are top-down; a default Metal texture render is bottom-up.
        // Use an explicit destination so both orientation and encoding errors are defined.
        let extent = image.extent
        let normalized = extent.origin == .zero ? image : image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let renderDestination = CIRenderDestination(mtlTexture: session.bgra, commandBuffer: command)
        renderDestination.colorSpace = videoColorSpace
        renderDestination.isFlipped = true
        let renderTask: CIRenderTask
        do {
            renderTask = try context.startTask(toRender: normalized, from: CGRect(x: 0, y: 0, width: width, height: height), to: renderDestination, at: .zero)
        } catch {
            self.session = nil
            failedKey = session.key
            retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
            scheduleRetryWakeup()
            return nil // Continue with the spatial path in the same command buffer.
        }
        // Retain the plane textures, pixel buffers and session until the GPU finishes.
        // Install this before encoding, so all submitted work has a complete lifetime owner.
        command.addCompletedHandler { [weak self] completed in
            withExtendedLifetime((session, parameters, sourceBuffer, destinationBuffer, yTextureRef, cTextureRef, renderTask)) {}
            guard completed.status != .completed else { return }
            DispatchQueue.main.async {
                // An obsolete command must never retire a newer configuration.
                guard let self, self.session === session else { return }
                self.session = nil
                self.failedKey = session.key
                self.retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
                self.scheduleRetryWakeup()
                self.onStateChange?()
            }
        }
        // Render the color-processed frame, convert RGB to bi-planar YUV, then upscale,
        // all inside the caller's single command buffer.
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(session.convert)
        encoder.setTexture(session.bgra, index: 0)
        encoder.setTexture(yTexture, index: 1)
        encoder.setTexture(cTexture, index: 2)
        encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        session.processor.process(with: command, parameters: parameters)
        return CIImage(cvPixelBuffer: destinationBuffer, options: [.colorSpace: videoColorSpace])
    }
}
#else
/// Older Apple SDK/toolchain builds keep the existing renderer interface and use spatial fallback.
@available(macOS 26.0, *)
final class AIUpscaler {
    init(device: MTLDevice) {}
    var onStateChange: (() -> Void)?
    var isReady: Bool { false }
    static func scaleFactor(for sourceWidth: Int, sourceHeight: Int, requested: Double) -> Float? { nil }
    func prepare(sourceWidth: Int, sourceHeight: Int, factor: Float, colorSpace: CGColorSpace) {}
    func stop() {}
    func upscale(_ image: CIImage, context: CIContext, command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? { nil }
}
#endif
