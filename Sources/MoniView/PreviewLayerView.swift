import AppKit
import CoreImage
import MetalKit
import SwiftUI

struct PreviewLayerView: NSViewRepresentable {
    @ObservedObject var capture: CaptureManager
    func makeNSView(context: Context) -> CapturePreviewNSView {
        CapturePreviewNSView(frames: capture.frames)
    }
    func updateNSView(_ view: CapturePreviewNSView, context: Context) {
        view.settings = capture.picture
        view.aspectMode = capture.aspectMode
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = !capture.picture.lowLatency
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
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 1)
    private let drawLock = NSLock()
    private var drawScheduled = false
    private var lastSequence: UInt64 = 0
    private var lastSettings: PictureSettings?
    private var lastSize = CGSize.zero
    private var lastAspect: AspectMode?

    init(frames: LatestVideoFrame) {
        self.frames = frames
        let gpu = MTLCreateSystemDefaultDevice()
        commands = gpu?.makeCommandQueue()
        upscaler = gpu.flatMap { MetalUpscaler(device: $0) }
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
        }
        delegate = self
        frames.setFrameHandler { [weak self] in self?.requestRender() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastSize = .zero; requestRender() }

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
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible), let ciContext, let commands,
              let initial = frames.latest() else { return }
        var (buffer, sequence, receivedAt) = initial
        let size = drawableSize
        guard size.width > 0, size.height > 0 else { return }
        guard sequence != lastSequence || settings != lastSettings || size != lastSize || aspectMode != lastAspect else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = currentDrawable, let command = commands.makeCommandBuffer() else { inFlight.signal(); return }

        // A drawable may have waited for presentation. Always take the newest frame afterwards.
        if let fresh = frames.latest() { (buffer, sequence, receivedAt) = fresh }
        // Core Image honors CVPixelBuffer's YUV matrix and full/video-range attachments.
        var image = CIImage(cvPixelBuffer: buffer)
        let originalExtent = image.extent
        image = VideoImageProcessor.color(image, settings: settings)
        let source = image.extent
        let screenScale = aspectMode == .fit ? min(size.width / source.width, size.height / source.height) : max(size.width / source.width, size.height / source.height)
        let visibleWidth = source.width * max(1, screenScale)
        let requestedWidth = settings.upscaleTarget.longEdge ?? visibleWidth
        let targetWidth = settings.lowLatency ? min(requestedWidth, visibleWidth) : requestedWidth
        let workingScale = settings.enhancementEnabled ? max(1, targetWidth / source.width) : 1
        let workingWidth = Int((source.width * workingScale).rounded())
        let workingHeight = Int((source.height * workingScale).rounded())
        var usedMetalFX = false
        if settings.enhancementEnabled, workingScale > 1.01 {
            if settings.upscaleMethod == .metalFX, let scaled = upscaler?.upscale(image, width: workingWidth, height: workingHeight, context: ciContext, command: command, colorSpace: colorSpace) {
                image = scaled; usedMetalFX = true
            } else {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: workingScale, kCIInputAspectRatioKey: 1.0])
            }
        }
        frames.setEngine(usedMetalFX ? "MetalFX" : (workingScale > 1.01 ? "Lanczos" : "原始＋锐化"))
        let sharpness = settings.sharpness + (settings.enhancementEnabled ? settings.enhancementStrength * (usedMetalFX ? 0.22 : 0.4) : 0)
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
        command.addCompletedHandler { [weak self] completed in
            if completed.status == .completed { frameStore.markRendered(receivedAt: receivedAt, gpuMS: max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000) }
            semaphore.signal()
            if frameStore.latest()?.1 != sequence { self?.requestRender() }
        }
        command.commit()
        lastSequence = sequence; lastSettings = settings; lastSize = size; lastAspect = aspectMode
    }
}
