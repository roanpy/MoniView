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
        private let cleanupQueue: DispatchQueue

        init(key: Key, device: MTLDevice, cleanupQueue: DispatchQueue) throws {
            let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: key.width, frameHeight: key.height, scaleFactor: key.factor)
            let extra: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let source = try Self.makePool(config.sourcePixelBufferAttributes, extra: extra)
            let destination = try Self.makePool(config.destinationPixelBufferAttributes, extra: extra)
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw SetupFailure.unavailable }
            let processor = VTFrameProcessor()
            do { try processor.startSession(configuration: config) }
            catch { processor.endSession(); throw error }
            self.key = key
            self.processor = processor
            sourcePool = source
            destinationPool = destination
            textureCache = cache
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
    private let device: MTLDevice
    private let prepareQueue = DispatchQueue(label: "dev.moniview.ai-upscale", qos: .userInitiated)
    // Everything below is main-thread only, including publication of prepared sessions.
    private var requestedKey: Key?
    private var session: Session?
    private var preparing = false
    private var generation: UInt64 = 0
    private var failedKey: Key?
    private var retryAfter = 0.0
    var isReady: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return session != nil && session?.key == requestedKey
    }

    init(device: MTLDevice) { self.device = device }

    /// Never exceed the caller's processing-size cap just to reach a supported AI factor.
    /// MetalFX/Lanczos remain available when no supported factor fits the requested budget.
    static func scaleFactor(for sourceWidth: Int, sourceHeight: Int, requested: Double) -> Float? {
        guard AIUpscalerSupport.isSupported, sourceWidth > 0, sourceHeight > 0, requested.isFinite else { return nil }
        return VTLowLatencySuperResolutionScalerConfiguration.__supportedScaleFactors(forFrameWidth: sourceWidth, frameHeight: sourceHeight)
            .map { $0.floatValue }
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
        guard session == nil, !preparing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard failedKey != key || now >= retryAfter else { return }
        preparing = true
        let expectedGeneration = generation
        let device = device
        let queue = prepareQueue
        queue.async { [weak self] in
            let prepared = try? Session(key: key, device: device, cleanupQueue: queue)
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard self.generation == expectedGeneration, self.requestedKey == key else { return }
                self.session = prepared
                if prepared == nil {
                    self.failedKey = key
                    // Only an actual failed attempt advances the deadline, not each arriving frame.
                    self.retryAfter = ProcessInfo.processInfo.systemUptime + 1.5
                }
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard requestedKey != nil || session != nil else { return }
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
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, sourceBuffer, nil, .bgra8Unorm, CVPixelBufferGetWidth(sourceBuffer), CVPixelBufferGetHeight(sourceBuffer), 0, &cvTexture) == kCVReturnSuccess,
              let cvTexture, let sourceTexture = CVMetalTextureGetTexture(cvTexture),
              let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: .zero),
              let destinationFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: .zero) else { return nil }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        // Retain the CVMetalTexture wrapper as well as its pixel buffers and processor.
        // Install this before encoding, so all submitted work has a complete lifetime owner.
        command.addCompletedHandler { _ in
            withExtendedLifetime((session, parameters, sourceBuffer, destinationBuffer, cvTexture)) {}
        }
        context.render(image, to: sourceTexture, commandBuffer: command, bounds: image.extent, colorSpace: colorSpace)
        session.processor.process(with: command, parameters: parameters)
        return CIImage(cvPixelBuffer: destinationBuffer, options: [.colorSpace: colorSpace])
    }
}
#else
/// Older Apple SDK/toolchain builds keep the existing renderer interface and use spatial fallback.
@available(macOS 26.0, *)
final class AIUpscaler {
    init(device: MTLDevice) {}
    var isReady: Bool { false }
    static func scaleFactor(for sourceWidth: Int, sourceHeight: Int, requested: Double) -> Float? { nil }
    func prepare(sourceWidth: Int, sourceHeight: Int, factor: Float, colorSpace: CGColorSpace) {}
    func stop() {}
    func upscale(_ image: CIImage, context: CIContext, command: MTLCommandBuffer, colorSpace: CGColorSpace) -> CIImage? { nil }
}
#endif
