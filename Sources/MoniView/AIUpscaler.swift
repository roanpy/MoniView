import CoreImage
import CoreVideo
import Metal
import VideoToolbox

/// Apple's low-latency ML super-resolution (macOS 26+). Processing is inserted into the app's
/// existing Metal command buffer, so it stays inside the preview's single-in-flight pipeline.
/// The session is prepared on a background queue because ML model loading can exceed a frame time.

/// Ungated support probe so UI code on older macOS versions can hide the AI option.
enum AIUpscalerSupport {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return VTLowLatencySuperResolutionScalerConfiguration.isSupported }
        return false
    }
}

@available(macOS 26.0, *)
final class AIUpscaler {
    private let processor = VTFrameProcessor()
    private var textureCache: CVMetalTextureCache?
    private let prepareQueue = DispatchQueue(label: "dev.moniview.ai-upscale", qos: .userInitiated)
    private var sessionKey: String?
    private var sourcePool: CVPixelBufferPool?
    private var destinationPool: CVPixelBufferPool?
    private var destinationSize = CGSize.zero
    /// Buffers handed to the command buffer are released only after the GPU finishes with them.
    private var inFlight: [AnyObject] = []
    private let lock = NSLock()
    private(set) var isReady = false
    private var lastPrepareAttempt = Date.distantPast

    init(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    /// Smallest supported scale factor that covers the requested scale, so the ML pass works at the
    /// lightest useful size; the final CI pass then lands on the exact drawable size.
    static func scaleFactor(for sourceWidth: Int, sourceHeight: Int, requested: Double) -> Float? {
        guard AIUpscalerSupport.isSupported else { return nil }
        let factors = VTLowLatencySuperResolutionScalerConfiguration.__supportedScaleFactors(forFrameWidth: sourceWidth, frameHeight: sourceHeight)
            .map { $0.floatValue }
            .sorted()
        guard !factors.isEmpty else { return nil }
        return factors.first { Double($0) >= requested - 0.01 } ?? factors.last
    }

    /// Warm up on a background queue; the caller falls back to MetalFX/Lanczos until ready.
    func prepare(sourceWidth: Int, sourceHeight: Int, factor: Float, colorSpace: CGColorSpace) {
        let key = "\(sourceWidth)x\(sourceHeight)@\(factor)"
        lock.lock()
        let unchanged = sessionKey == key && isReady
        // A failed or in-flight preparation is retried at most every couple of seconds.
        let throttled = !unchanged && Date().timeIntervalSince(lastPrepareAttempt) < 1.5
        if !unchanged { lastPrepareAttempt = Date() }
        lock.unlock()
        if unchanged || throttled { return }
        prepareQueue.async { [weak self] in
            guard let self else { return }
            let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: sourceWidth, frameHeight: sourceHeight, scaleFactor: factor)
            let sourceAttrs = self.resolve(config.sourcePixelBufferAttributes, extra: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ])
            let destinationAttrs = self.resolve(config.destinationPixelBufferAttributes, extra: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ])
            var sourcePool: CVPixelBufferPool?
            var destinationPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, sourceAttrs as CFDictionary, &sourcePool)
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, destinationAttrs as CFDictionary, &destinationPool)
            self.processor.endSession()
            do {
                try self.processor.startSession(configuration: config)
                guard let sourcePool, let destinationPool else { throw CaptureFailure.message("AI 超分初始化失败。") }
                self.lock.lock()
                self.sourcePool = sourcePool
                self.destinationPool = destinationPool
                self.destinationSize = CGSize(width: Int(Double(sourceWidth) * Double(factor)), height: Int(Double(sourceHeight) * Double(factor)))
                self.sessionKey = key
                self.isReady = true
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.isReady = false
                self.sessionKey = nil
                self.lock.unlock()
            }
        }
    }

    func stop() {
        lock.lock()
        let active = isReady || sessionKey != nil
        lock.unlock()
        guard active else { return }
        prepareQueue.async { [weak self] in
            self?.processor.endSession()
            if let cache = self?.textureCache { CVMetalTextureCacheFlush(cache, 0) }
            self?.lock.lock()
            self?.isReady = false
            self?.sessionKey = nil
            self?.sourcePool = nil
            self?.destinationPool = nil
            self?.lock.unlock()
        }
    }

    /// Renders the color-processed image into a source buffer, upscales it with the ML processor
    /// inside the given command buffer, and returns the result as a CIImage for the remaining passes.
    func upscale(_ image: CIImage, context: CIContext, command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? {
        lock.lock()
        let ready = isReady, sourcePool = self.sourcePool, destinationPool = self.destinationPool
        lock.unlock()
        guard ready, let sourcePool, let destinationPool else { return nil }
        var sourceBuffer: CVPixelBuffer?
        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, sourcePool, &sourceBuffer) == kCVReturnSuccess, let sourceBuffer,
              CVPixelBufferPoolCreatePixelBuffer(nil, destinationPool, &destinationBuffer) == kCVReturnSuccess, let destinationBuffer else { return nil }
        let extent = image.extent
        // Render through a Metal texture view of the pixel buffer so the work stays in the
        // caller's command buffer alongside the ML pass.
        var cvTexture: CVMetalTexture?
        guard let textureCache,
              CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, sourceBuffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(sourceBuffer), CVPixelBufferGetHeight(sourceBuffer), 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let sourceTexture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        context.render(image, to: sourceTexture, commandBuffer: command, bounds: extent, colorSpace: colorSpace)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: .zero) else { return nil }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        processor.process(with: command, parameters: parameters)
        lock.lock()
        inFlight.append(parameters)
        inFlight.append(sourceBuffer)
        inFlight.append(destinationBuffer)
        lock.unlock()
        command.addCompletedHandler { [weak self] _ in
            self?.lock.lock()
            if let self { self.inFlight.removeAll { $0 === parameters || $0 === sourceBuffer || $0 === destinationBuffer } }
            self?.lock.unlock()
        }
        return CIImage(cvPixelBuffer: destinationBuffer)
    }

    private func resolve(_ base: [String: Any], extra: [String: Any]) -> [String: Any] {
        var resolved: CFDictionary?
        CVPixelBufferCreateResolvedAttributesDictionary(nil, [base as CFDictionary, extra as CFDictionary] as CFArray, &resolved)
        return (resolved as? [String: Any]) ?? extra
    }
}
