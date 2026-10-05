import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// Everything that determines what a single draw must produce.
/// Draws are deduplicated against the last *submitted* key rather than the last attempt,
/// so a state change that arrives while the GPU is busy is never dropped.
private struct RenderKey: Equatable {
    var sequence: UInt64
    var settings: PictureSettings
    var size: CGSize
    var aspect: AspectMode
}

struct PreviewLayerView: NSViewRepresentable {
    @ObservedObject var capture: CaptureManager
    func makeNSView(context: Context) -> CapturePreviewNSView {
        CapturePreviewNSView(frames: capture.frames)
    }
    func updateNSView(_ view: CapturePreviewNSView, context: Context) {
        view.settings = capture.picture
        view.aspectMode = capture.aspectMode
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = !capture.picture.lowLatency
        if capture.picture.upscaleMethod != .ai { view.stopAIUpscaler() }
        view.requestRender()
    }
}

/// One GPU pipeline handles YUV range conversion, color, scaling and luminance sharpening.
final class CapturePreviewNSView: MTKView, MTKViewDelegate {
    var settings = PictureSettings()
    var aspectMode: AspectMode = .fit
    private let frames: LatestVideoFrame
    private let ciContext: CIContext?
    private let commands: MTLCommandQueue?
    private let upscaler: MetalUpscaler?
    /// Stored as AnyObject so the class itself can stay below the macOS 26 deployment gate.
    private var _aiUpscaler: AnyObject?
    @available(macOS 26.0, *) private var aiUpscaler: AIUpscaler? { _aiUpscaler as? AIUpscaler }
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 1)
    private let drawLock = NSLock()
    private var drawScheduled = false
    // Render bookkeeping below is main-thread only.
    private var lastSubmitted: RenderKey?
    private var lastMeasuredSequence: UInt64?
    private var forceDraw = false
    private var failedDrawRetries = 0

    init(frames: LatestVideoFrame) {
        self.frames = frames
        let gpu = MTLCreateSystemDefaultDevice()
        commands = gpu?.makeCommandQueue()
        upscaler = gpu.flatMap { MetalUpscaler(device: $0) }
        if AIUpscalerSupport.isSupported, #available(macOS 26.0, *), let gpu { _aiUpscaler = AIUpscaler(device: gpu) }
        ciContext = gpu.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) }
        super.init(frame: .zero, device: gpu)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        enableSetNeedsDisplay = false
        isPaused = true
        autoResizeDrawable = true
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 3
            metalLayer.presentsWithTransaction = false
            // Match the color space used for rendering so wide-gamut displays do not shift colors.
            metalLayer.colorspace = colorSpace
        }
        delegate = self
        frames.setFrameHandler { [weak self] in self?.requestRender() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A screen/backing change can alter Match Display even when drawable size is unchanged.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didDeminiaturizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    /// Redraw when the window becomes visible again, even if no new frame has arrived.
    @objc private func windowBecameVisible() {
        forceDraw = true
        requestRender()
    }

    func stopAIUpscaler() {
        if #available(macOS 26.0, *) { aiUpscaler?.stop() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        forceDraw = true
        requestRender()
    }

    /// Called on the main thread after a draw finishes: only ask for another draw when the
    /// newest frame or the current settings actually differ from what was submitted.
    private func requestRenderIfStateChanged() {
        guard let (_, sequence, _) = frames.latest() else { return }
        let key = RenderKey(sequence: sequence, settings: settings, size: drawableSize, aspect: aspectMode)
        // A forced draw that was deferred behind an in-flight GPU command still has to happen.
        if forceDraw || key != lastSubmitted { requestRender() }
    }

    func requestRender() {
        drawLock.lock()
        guard !drawScheduled else { drawLock.unlock(); return }
        drawScheduled = true
        drawLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawLock.lock(); self.drawScheduled = false; self.drawLock.unlock()
            self.draw()
        }
    }

    func draw(in view: MTKView) {
        guard let ciContext, let commands else { return }
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              let initial = frames.latest() else { return }
        var (buffer, sequence, receivedAt) = initial
        let size = drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let forced = forceDraw
        guard forced || RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode) != lastSubmitted else { return }
        // The GPU is still busy. Its completion handler re-checks the current state on the main
        // thread and schedules another draw, so this request is not lost.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = commands.makeCommandBuffer() else {
            inFlight.signal()
            forceDraw = true
            return
        }
        forceDraw = false

        // A drawable may have waited for presentation. Always take the newest frame afterwards.
        if let fresh = frames.latest() { (buffer, sequence, receivedAt) = fresh }
        // Core Image honors CVPixelBuffer's YUV matrix and full/video-range attachments.
        var image = CIImage(cvPixelBuffer: buffer)
        let originalExtent = image.extent
        image = VideoImageProcessor.color(image, settings: settings)
        let source = image.extent
        let screenScale = aspectMode == .fit ? min(size.width / source.width, size.height / source.height) : max(size.width / source.width, size.height / source.height)
        // Long-edge targets follow the source's own long edge, so portrait signals are not over-scaled.
        let displayScale = max(1, screenScale)
        let sourceLongEdge = max(source.width, source.height)
        let visibleLongEdge = sourceLongEdge * displayScale
        // This is backing-store size; scaled display modes can differ from native panel pixels.
        let screenPixels: Double? = (window.screen ?? NSScreen.main).map { Double(max($0.frame.width, $0.frame.height) * $0.backingScaleFactor) }
        let requestedLongEdge = settings.upscaleTarget.resolvedLongEdge(screenLongEdge: screenPixels, sourceLongEdge: sourceLongEdge)
        let targetLongEdge = settings.lowLatency ? min(requestedLongEdge, visibleLongEdge) : requestedLongEdge
        let workingScale = settings.enhancementEnabled ? max(1, targetLongEdge / sourceLongEdge) : 1
        let workingWidth = Int((source.width * workingScale).rounded())
        let workingHeight = Int((source.height * workingScale).rounded())
        var usedMetalFX = false
        var usedAI = false
        if settings.enhancementEnabled, workingScale > 1.01, settings.upscaleMethod == .ai {
            let sourceWidth = Int(source.width.rounded())
            let sourceHeight = Int(source.height.rounded())
            if #available(macOS 26.0, *), let ai = aiUpscaler,
               let factor = AIUpscaler.scaleFactor(for: sourceWidth, sourceHeight: sourceHeight, requested: workingScale) {
                // Session warmup happens off the draw path; frames fall back until the model is ready.
                ai.prepare(sourceWidth: sourceWidth, sourceHeight: sourceHeight, factor: factor, colorSpace: colorSpace)
                if ai.isReady, let scaled = ai.upscale(image, context: ciContext, command: command, colorSpace: colorSpace) {
                    image = scaled
                    usedAI = true
                }
            }
        }
        if settings.enhancementEnabled, workingScale > 1.01, !usedAI {
            if settings.upscaleMethod != .lanczos, let scaled = upscaler?.upscale(image, width: workingWidth, height: workingHeight, context: ciContext, command: command, colorSpace: colorSpace) {
                image = scaled; usedMetalFX = true
            } else {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: workingScale, kCIInputAspectRatioKey: 1.0])
            }
        }
        frames.setEnhancedSize(workingScale > 1.01 ? "\(Int(image.extent.width.rounded()))×\(Int(image.extent.height.rounded()))" : nil)
        // Native-size, MetalFX and AI previews match the recording; Lanczos scaling compensates more.
        let enhancementSharpening = usedMetalFX || usedAI || workingScale <= 1.01 ? VideoImageProcessor.enhancementSharpening : VideoImageProcessor.scaledPreviewSharpening
        let sharpness = settings.sharpness + (settings.enhancementEnabled ? settings.enhancementStrength * enhancementSharpening : 0)
        frames.setEngine(usedAI ? "AI 超分" : (usedMetalFX ? "MetalFX" : (workingScale > 1.01 ? "Lanczos" : (sharpness > 0.001 ? "原始＋锐化" : "原始"))))
        if sharpness > 0.001 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness]) }
        let output = image.extent
        let scale = aspectMode == .fit ? min(size.width / output.width, size.height / output.height) : max(size.width / output.width, size.height / output.height)
        if aspectMode == .stretch {
            image = image.transformed(by: CGAffineTransform(scaleX: size.width / output.width, y: size.height / output.height))
        } else if usedMetalFX || image.extent.width > originalExtent.width {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        let scaled = image.extent
        let transform = CGAffineTransform(translationX: (size.width - scaled.width) / 2 - scaled.minX, y: (size.height - scaled.height) / 2 - scaled.minY)
        let bounds = CGRect(origin: .zero, size: size)
        image = image.transformed(by: transform).composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        ciContext.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        command.present(drawable)
        let semaphore = inFlight
        let frameStore = frames
        let frameSequence = sequence
        let frameReceivedAt = receivedAt
        let shouldMeasure = frameSequence != lastMeasuredSequence
        command.addCompletedHandler { [weak self] completed in
            let gpuMS = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000
            let succeeded = completed.status == .completed
            // Measure at the GPU completion callback, before waiting for the main thread.
            // LatestVideoFrame is lock-protected; parameter/resize redraws are not new video frames.
            if succeeded && shouldMeasure { frameStore.markRendered(receivedAt: frameReceivedAt, gpuMS: gpuMS) }
            // Semaphore release and render bookkeeping remain serialized with draw(in:).
            DispatchQueue.main.async {
                guard let self else { semaphore.signal(); return }
                if succeeded && shouldMeasure { self.lastMeasuredSequence = frameSequence }
                semaphore.signal()
                if succeeded {
                    self.failedDrawRetries = 0
                } else if self.failedDrawRetries < 3 {
                    // Retry a failed command buffer a few times, then wait for the next change.
                    self.failedDrawRetries += 1
                    self.forceDraw = true
                }
                self.requestRenderIfStateChanged()
            }
        }
        command.commit()
        lastSubmitted = RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode)
    }
}
