import AppKit
import CoreImage
import CoreMedia
import MetalKit
import SwiftUI
import QuartzCore

/// Everything that determines what a single draw must produce.
/// Draws are deduplicated against the last *submitted* key rather than the last attempt,
/// so a state change that arrives while the GPU is busy is never dropped.
private struct RenderKey: Equatable {
    var sequence: UInt64
    var settings: PictureSettings
    var size: CGSize
    var aspect: AspectMode
    var midpoint = false
}

/// One midpoint engine shared by the VT processor tiers and the Metal flow-blend beta.
/// State and encoding stay main-thread confined; work encodes on the caller's command buffer.
private protocol MidpointInterpolating: AnyObject {
    var isReady: Bool { get }
    /// Temporal multipliers this engine can generate. The VideoToolbox processor supplies
    /// the midpoint only; the flow-blend engine blends at any phase in 0...1.
    var supportedMultipliers: [Double] { get }
    var onStateChange: (() -> Void)? { get set }
    func prepare(width: Int, height: Int)
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer?, currentBuffer: CVPixelBuffer?,
                     fastInputResampling: Bool, blendFactor: Float) -> CIImage?
    func stop()
}

@available(macOS 26.0, *)
/// The VideoToolbox processor interpolates at the temporal midpoint only, so a phase
/// outside 0.5 has no representation there and is reported as unavailable. The renderer
/// only asks for more than one phase when the selected engine can supply it.
extension FrameInterpolator: MidpointInterpolating {
    var supportedMultipliers: [Double] { [2] }
    func interpolate(previous: CIImage, current: CIImage, previousTime: CMTime, currentTime: CMTime,
                     context: CIContext, command: MTLCommandBuffer,
                     previousBuffer: CVPixelBuffer?, currentBuffer: CVPixelBuffer?,
                     fastInputResampling: Bool, blendFactor: Float) -> CIImage? {
        guard abs(blendFactor - 0.5) < 0.001 else { return nil }
        return interpolate(previous: previous, current: current, previousTime: previousTime, currentTime: currentTime,
                           context: context, command: command,
                           previousBuffer: previousBuffer, currentBuffer: currentBuffer,
                           fastInputResampling: fastInputResampling)
    }
}
extension FlowBlendInterpolator: MidpointInterpolating {}

struct PreviewLayerView: NSViewRepresentable {
    @ObservedObject var capture: CaptureManager
    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView(frames: capture.frames)
        view.onPresentationRecovery = { [weak capture] in capture?.rebuildPreview() }
        return view
    }
    func updateNSView(_ view: CapturePreviewNSView, context: Context) {
        // A colour or sharpness change does not need a redraw of its own: the next
        // presented frame already carries it. Forcing a draw here added a frame outside
        // the interpolation schedule, which showed up as a flash on every preset change.
        view.settings = capture.picture
        view.aspectMode = capture.effectiveAspectMode
        view.contentCadenceMeasurementEnabled = capture.followsRealContentRate
        view.configureInterpolation()
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = (capture.picture.enhancementEnabled && capture.picture.frameInterpolation != .off && FrameInterpolatorSupport.isSupported(capture.picture.frameInterpolation)) || !capture.picture.lowLatency
        if capture.picture.upscaleMethod != .ai || !capture.picture.enhancementEnabled || capture.picture.upscaleTarget == .native { view.stopAIUpscaler() }
        // A redraw is always safe now: the frame pair that was already scheduled keeps its
        // own timing settings, so it is no longer cancelled by a colour change. Without
        // this, a static or paused source would not pick up a colour edit until new frames
        // arrived, because the layer only draws on demand.
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
    private var _interpolator: AnyObject?
    @available(macOS 26.0, *) private var interpolator: FrameInterpolator? { _interpolator as? FrameInterpolator }
    /// Beta Metal flow-blend engine; pure Metal, so it needs no macOS 26 gate of its own.
    private var flowInterpolator: FlowBlendInterpolator?
    private var interpolationEngine: (any MidpointInterpolating)? {
        if settings.frameInterpolation == .flowBlend { return flowInterpolator }
        if #available(macOS 26.0, *) { return interpolator }
        return nil
    }
    private var interpolationLink: CADisplayLink?
    private var linkProxy: InterpolationDisplayLinkProxy?
    private var displayTargetTime = 0.0
    private var observedDisplayFPS = 0.0
    private var configuredDisplayCap: Float = 0
    private var previousMode: FrameInterpolationMode = .off
    private var previousInterpolationEnabled = false
    private var previousInterpolationForce = false
    private var cooldownUntil = 0.0
    private var cooldownReason: String?
    private var nativeCosts: [Double] = []
    private var midpointCosts: [Double] = []
    /// GPU-only span of midpoint commands, published with the total so a CPU-bound
    /// budget can be told apart from a GPU-bound one.
    private var midpointGPUCosts: [Double] = []
    private var calibrationWarmupsRemaining = 2
    private var adaptiveLongEdge: Int?
    private var interpolationDimensions: FrameInterpolationPolicy.Dimensions?
    /// Recent exact adjacent-pair outcomes estimate content cadence; per-pair PTS intervals
    /// independently set midpoint budget and presentation timing.
    private var duplicatePairWindow: [Bool] = []
    private var lastDuplicateCheck: (sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64,
                                     result: Bool, recordedCadenceSample: Bool)?
    /// Strict comparisons keep their own slot: a tolerant "duplicate" must never suppress a
    /// frame the exact judge would call new.
    private var lastStrictCheck: (sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64, result: Bool)?
    var contentCadenceMeasurementEnabled = false
    private var lastSourceSequence: UInt64? // last GPU-completed source with an ordered presentation
    private var presentationEpoch: UInt64 = 0
    private var sourceStreamEpoch: UInt64?
    private var nextPresentationToken: UInt64 = 0
    private struct Presentation {
        let deadline: Double
        var gpuCompleted = false
    }
    private var outstandingPresentations: [UInt64: Presentation] = [:]
    private var retiringForPresentationFailure = false
    var onPresentationRecovery: (() -> Void)?
    private var lastPresentationTime = 0.0 // includes generated and native frames, across epochs
    private var lastGeneratedPresentationTime = 0.0
    #if MONIVIEW_PREVIEW_TESTING
    var onPresentation: ((UInt64, Bool, Double) -> Void)?
    private(set) var peakOutstandingPresentations = 0
    private(set) var drawableWaitMS: [Double] = []
    private(set) var displayTickTimes: [Double] = []
    var suppressPresentedCallbacks = false // failure injection, absent from production builds
    #endif
    #if MONIVIEW_PREVIEW_TESTING
    private func trace(_ value: String) { if ProcessInfo.processInfo.environment["MONIVIEW_TEST_TRACE"] == "1" { print(value) } }
    #endif
    private var scheduledSourceUntil = 0.0
    private var awaitingSourcePresentation: (sequence: UInt64, deadline: Double)?
    private var presentedMidpoint: (sequence: UInt64, time: Double, deadline: Double)?
    /// Compares the fields that decide whether an already-scheduled frame pair is still
    /// valid. Colour and sharpness are deliberately excluded: they change what the
    /// endpoint looks like, not when it presents, so switching a preset must not cancel a
    /// pair that is already in flight and drop interpolation into a cooldown.
    private static func timingCompatible(_ lhs: PictureSettings, _ rhs: PictureSettings) -> Bool {
        lhs.enhancementEnabled == rhs.enhancementEnabled
            && lhs.enhancementStrength == rhs.enhancementStrength
            && lhs.lowLatency == rhs.lowLatency
            && lhs.upscaleTarget == rhs.upscaleTarget
            && lhs.upscaleMethod == rhs.upscaleMethod
            && lhs.frameInterpolation == rhs.frameInterpolation
            && lhs.forceFrameInterpolation == rhs.forceFrameInterpolation
            && lhs.skipsExactDuplicateInterpolation == rhs.skipsExactDuplicateInterpolation
    }

    private struct PendingSource {
        // One bounded endpoint is necessary after its midpoint has been submitted.
        // The next incoming source still overwrites the ordinary latest-frame mailbox.
        let buffer: CVPixelBuffer
        let receivedAt: UInt64
        let sequence: UInt64
        let settings: PictureSettings
        let size: CGSize
        let aspect: AspectMode
        let presentationTime: Double
        let sourcePeriod: Double
        let sourcePTS: CMTime
        let isUniqueContent: Bool
    }
    private struct UniqueSource {
        let buffer: CVPixelBuffer
        let sequence: UInt64
        let streamEpoch: UInt64
        let pts: CMTime
    }
    private struct InterpolationPair {
        let previousBuffer: CVPixelBuffer
        let previousSequence: UInt64
        let previousPTS: CMTime
        let currentPTS: CMTime
        let period: Double
    }
    /// Frames already computed and waiting for their presentation slot, in order. A 2x
    /// pair queues one midpoint then its endpoint; a 3x pair queues two midpoints then the
    /// endpoint. The bound is the largest phase count plus one, so the queue can never grow
    /// with the capture stream.
    private struct QueuedFrame {
        let image: CIImage
        let buffer: CVPixelBuffer
        let receivedAt: UInt64
        let sequence: UInt64
        let settings: PictureSettings
        let size: CGSize
        let aspect: AspectMode
        let presentationTime: Double
        let sourcePeriod: Double
        let sourcePTS: CMTime
        let isUniqueContent: Bool
        let isGenerated: Bool
        /// Midpoints the pair that produced this frame generated, so slot and budget math
        /// stay consistent while the queue drains instead of reverting to a 2x shape.
        let midpointCount: Int
    }
    private var queuedFrames: [QueuedFrame] = []
    private static let maximumQueuedFrames = 3
    private var lastUniqueSource: UniqueSource?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let inFlight = DispatchSemaphore(value: 1)
    private let drawLock = NSLock()
    private var drawScheduled = false
    // Render bookkeeping below is main-thread only.
    private var lastSubmitted: RenderKey?
    private var lastMeasuredSequence: UInt64?
    private var forceDraw = false
    private var failedDrawRetries = 0
    private var drawableFailures = 0
    private var firstDrawableFailureAt = 0.0
    private var comfortableMidpoints = 0
    private var lastRaiseAt = 0.0
    private var lastRaisedToLongEdge: Int?
    private var blockedRaiseTarget: Int?

    init(frames: LatestVideoFrame) {
        self.frames = frames
        let gpu = MTLCreateSystemDefaultDevice()
        commands = gpu?.makeCommandQueue()
        upscaler = gpu.flatMap { MetalUpscaler(device: $0) }
        if FrameInterpolatorSupport.isSupported, #available(macOS 26.0, *), let gpu { _interpolator = FrameInterpolator(device: gpu) }
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
        if #available(macOS 26.0, *) {
            interpolator?.onStateChange = { [weak self] in self?.forceDraw = true; self?.requestRender() }
            aiUpscaler?.onStateChange = { [weak self] in
                self?.forceDraw = true
                self?.requestRender()
            }
        }
        frames.setFrameHandler { [weak self] in self?.requestRender() }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    deinit { interpolationLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    /// A weak target avoids the CADisplayLink -> view retain cycle. NSView's link follows
    /// the actual display across window moves and stops callbacks while hidden.
    func configureInterpolation() {
        let mode = settings.frameInterpolation
        let enabled = settings.enhancementEnabled && mode != .off && FrameInterpolatorSupport.isSupported(mode)
        // Cadence measurement runs whenever the preview is live, independent of the
        // interpolation switches and of Follow: it only reads pixels and publishes an
        // estimate, and the panel needs it to aim interpolation at the content rate.
        frames.setInterpolationHistoryEnabled(true)
        if mode != previousMode || enabled != previousInterpolationEnabled || settings.forceFrameInterpolation != previousInterpolationForce {
            let failureCooldown = FrameInterpolationPolicy.preserveFailureCooldown(
                forceChanged: settings.forceFrameInterpolation != previousInterpolationForce,
                modeChanged: mode != previousMode || enabled != previousInterpolationEnabled,
                failureActive: cooldownReason != nil, until: cooldownUntil, now: CACurrentMediaTime())
            let failureReason = failureCooldown > 0 ? cooldownReason : nil
            frames.setInterpolationCost(seconds: 0, budget: 0)
            frames.setInterpolationWorkingSize(nil)
            adaptiveLongEdge = nil; interpolationDimensions = nil
            presentationEpoch &+= 1; presentedMidpoint = nil
            lastUniqueSource = nil; lastGeneratedPresentationTime = 0
            queuedFrames.removeAll(); midpointCosts.removeAll(); midpointGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
            cooldownUntil = failureCooldown; cooldownReason = failureReason; lastSourceSequence = nil; awaitingSourcePresentation = nil
            comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
            previousMode = mode; previousInterpolationEnabled = enabled
            previousInterpolationForce = settings.forceFrameInterpolation
            duplicatePairWindow.removeAll(); lastDuplicateCheck = nil; lastStrictCheck = nil
            if #available(macOS 26.0, *) { interpolator?.stop() }
            if mode != .flowBlend { flowInterpolator = nil }
        }
        if enabled {
            stopAIUpscaler() // Avoid two temporal/ML pipelines competing for the slot budget.
            if mode == .flowBlend, flowInterpolator == nil {
                flowInterpolator = device.flatMap { FlowBlendInterpolator(device: $0) }
            }
            if interpolationLink == nil {
                let proxy = InterpolationDisplayLinkProxy(view: self)
                linkProxy = proxy
                let link = displayLink(target: proxy, selector: #selector(InterpolationDisplayLinkProxy.tick(_:)))
                link.add(to: .main, forMode: .common)
                interpolationLink = link
            }
            let reported = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
            let cap = Float(reported > 0 ? reported : 60)
            if cap != configuredDisplayCap {
                interpolationLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
                configuredDisplayCap = cap
            }
        } else {
            queuedFrames.removeAll(); interpolationLink?.invalidate(); interpolationLink = nil; linkProxy = nil
            observedDisplayFPS = 0; displayTargetTime = 0; configuredDisplayCap = 0
            if #available(macOS 26.0, *) { interpolator?.stop() }
            flowInterpolator = nil
            frames.setInterpolationState(mode == .off || !settings.enhancementEnabled ? "关闭" : "插帧不可用")
        }
    }
    fileprivate func interpolationTick(_ link: CADisplayLink) {
        #if MONIVIEW_PREVIEW_TESTING
        displayTickTimes.append(CACurrentMediaTime())
        if displayTickTimes.count > 6000 { displayTickTimes.removeFirst(displayTickTimes.count - 6000) }
        #endif
        let currentCap = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        if currentCap > 0 && currentCap != configuredDisplayCap { resetInterpolationForDisplay() }
        displayTargetTime = link.targetTimestamp
        let interval = link.targetTimestamp - link.timestamp
        // Apple's reported display-link period, not a count of delivered callbacks
        // or proof of on-screen FPS. Only presentedTime callbacks count generated FPS.
        if interval > 0, interval.isFinite {
            let hz = min(Double(window?.screen?.maximumFramesPerSecond ?? 60), 1 / interval)
            observedDisplayFPS = observedDisplayFPS == 0 ? hz : observedDisplayFPS * 0.8 + hz * 0.2
        }
        frames.setDisplayRates(maximum: Double(window?.screen?.maximumFramesPerSecond ?? 60), observed: observedDisplayFPS)
        if !queuedFrames.isEmpty || !outstandingPresentations.isEmpty { requestRender() }
        else { requestRenderIfStateChanged() }
    }
    private func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    /// Cost samples worth acting on. The first commands after a switch carry session
    /// warm-up; acting on one of them put the pipeline straight into a cooldown.
    private static let minimumCostSamples = 6
    /// Past this many samples the estimate is considered steady and P95 takes over.
    private static let steadyStateSamples = 16

    /// Median while the sample set is still small, so one warm-up outlier cannot decide
    /// admission and stall interpolation for the whole cooldown window.
    private func admissionCost(_ values: [Double]) -> Double? {
        guard values.count >= Self.minimumCostSamples else { return nil }
        let sorted = values.sorted()
        // Median only while the set is small, where one warm-up outlier would otherwise
        // decide. Once enough samples exist the tail is real information, so switch to
        // P95 exactly like the displayed figure.
        guard values.count >= Self.steadyStateSamples else { return sorted[sorted.count / 2] }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    private func recordComfortablePresentedPair(slot: Double) {
        guard slot.isFinite, slot > 0, adaptiveLongEdge != nil,
              let midpointCost = p95(midpointCosts), midpointCost <= slot * 0.55 else {
            comfortableMidpoints = 0
            return
        }
        comfortableMidpoints += 1
        guard comfortableMidpoints >= 90 else { return }
        comfortableMidpoints = 0
        lastRaisedToLongEdge = nil
        let now = CACurrentMediaTime()
        if let current = adaptiveLongEdge, now - lastRaiseAt > 10 {
            let ceiling = FrameInterpolationPolicy.ceilingLongEdge(
                mode: settings.frameInterpolation, inputFPS: 0.5 / slot)
            var target = FrameInterpolationPolicy.raisedLongEdge(after: current)
            if let ceiling, (target ?? ceiling) >= ceiling { target = nil }
            let targetEdge = target ?? ceiling
            if targetEdge != nil, targetEdge != blockedRaiseTarget {
                adaptiveLongEdge = target
                lastRaiseAt = now
                lastRaisedToLongEdge = targetEdge
                midpointCosts.removeAll(); midpointGPUCosts.removeAll(); calibrationWarmupsRemaining = 2
            }
        }
    }
    private func resetInterpolationForDisplay() {
        adaptiveLongEdge = nil; interpolationDimensions = nil
        presentationEpoch &+= 1; presentedMidpoint = nil
        lastUniqueSource = nil; lastGeneratedPresentationTime = 0
        queuedFrames.removeAll(); midpointCosts.removeAll(); midpointGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
        comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
        duplicatePairWindow.removeAll(); lastDuplicateCheck = nil; lastStrictCheck = nil
        observedDisplayFPS = 0; displayTargetTime = 0; lastSourceSequence = nil
        configureInterpolation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A screen/backing change can alter Match Display even when drawable size is unchanged.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeBackingPropertiesNotification, object: nil)
        resetInterpolationForDisplay()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didDeminiaturizeNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible), name: NSWindow.didChangeBackingPropertiesNotification, object: window)
    }

    /// Redraw when the window becomes visible again, even if no new frame has arrived.
    @objc private func windowBecameVisible() {
        resetInterpolationForDisplay()
        forceDraw = true
        requestRender()
    }

    func stopAIUpscaler() {
        if #available(macOS 26.0, *) { aiUpscaler?.stop() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        queuedFrames.removeAll()
        // Output-size changes alter midpoint cost; a rung blocked at one size may fit at another.
        blockedRaiseTarget = nil; comfortableMidpoints = 0
        forceDraw = true
        requestRender()
    }

    /// Called on the main thread after a draw finishes: only ask for another draw when the
    /// newest frame or the current settings actually differ from what was submitted.
    private func requestRenderIfStateChanged() {
        guard let (_, sequence, _) = frames.latest() else { return }
        let key = RenderKey(sequence: sequence, settings: settings, size: drawableSize, aspect: aspectMode)
        // A forced draw that was deferred behind an in-flight GPU command still has to happen.
        if !queuedFrames.isEmpty || forceDraw || key != lastSubmitted { requestRender() }
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

    /// Exact comparison is shared by cadence measurement and the optional inference skip.
    /// Measurement is enabled by Follow or the skip option; the early-return helper below
    /// remains gated solely by `skipsExactDuplicateInterpolation`.
    private func duplicateResult(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64,
                                 recordCadenceSample: Bool) -> Bool {
        if recordCadenceSample {
            if let last = lastDuplicateCheck,
               last.sequence == sequence, last.previousSequence == previousSequence,
               last.streamEpoch == streamEpoch {
                // A cadence sample is appended when the entry is stored, so a hit here has
                // already contributed and must not be counted twice.
                return last.result
            }
        } else if let last = lastStrictCheck,
                  last.sequence == sequence, last.previousSequence == previousSequence,
                  last.streamEpoch == streamEpoch {
            return last.result
        }
        // Cadence sampling tolerates the capture device's own encoding noise; the skip and
        // source-unique decisions stay exact. The two keep separate cache entries because a
        // tolerant "duplicate" must never suppress a frame the strict judge calls new.
        let result = recordCadenceSample
            ? VideoFrameDuplicateDetector.areEquivalentForCadence(previous, current)
            : VideoFrameDuplicateDetector.areIdentical(previous, current)
        if recordCadenceSample {
            duplicatePairWindow.append(result)
            duplicatePairWindow = Array(duplicatePairWindow.suffix(16))
            lastDuplicateCheck = (sequence, previousSequence, streamEpoch, result, true)
        } else {
            lastStrictCheck = (sequence, previousSequence, streamEpoch, result)
        }
        return result
    }

    /// Cadence measurement always runs while a preview is live. It only reads pixels and
    /// publishes an estimate, so gating it on the interpolation switches meant a 30 FPS
    /// game inside a 60 Hz signal was treated as 60 FPS content whenever those switches
    /// were off, and the panel then aimed the interpolation at the wrong rate.
    private func observeDuplicateCadence(previous: CVPixelBuffer, current: CVPixelBuffer,
                                         sequence: UInt64, previousSequence: UInt64,
                                         streamEpoch: UInt64) -> Bool? {
        return duplicateResult(previous: previous, current: current, sequence: sequence,
                               previousSequence: previousSequence, streamEpoch: streamEpoch,
                               recordCadenceSample: true)
    }

    /// Convenience for the dedup fast path, which only has the newest sequence number and
    /// compares against the frame the capture stream delivered immediately before it.
    private func isDuplicatePair(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, streamEpoch: UInt64) -> Bool {
        guard settings.skipsExactDuplicateInterpolation else { return false }
        return duplicateResult(previous: previous, current: current, sequence: sequence,
                               previousSequence: sequence &- 1, streamEpoch: streamEpoch,
                               recordCadenceSample: false)
    }

    private func isDuplicatePair(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64) -> Bool {
        guard settings.skipsExactDuplicateInterpolation else { return false }
        return duplicateResult(previous: previous, current: current, sequence: sequence,
                               previousSequence: previousSequence, streamEpoch: streamEpoch,
                               recordCadenceSample: false)
    }

    private func interpolationPair(current: CVPixelBuffer, currentPTS: CMTime,
                                   sequence: UInt64, streamEpoch: UInt64, signalFPS: Double,
                                   currentIsDuplicate: Bool) -> InterpolationPair? {
        let previousBuffer: CVPixelBuffer
        let previousSequence: UInt64
        let previousPTS: CMTime
        if settings.skipsExactDuplicateInterpolation {
            guard !currentIsDuplicate, let previous = lastUniqueSource,
                  previous.streamEpoch == streamEpoch, previous.sequence < sequence else { return nil }
            previousBuffer = previous.buffer
            previousSequence = previous.sequence
            previousPTS = previous.pts
        } else {
            guard let adjacent = frames.interpolationPair(sequence: sequence) else { return nil }
            guard lastSourceSequence == adjacent.1 else { return nil }
            previousBuffer = adjacent.0
            previousSequence = adjacent.1
            previousPTS = adjacent.2
        }
        guard CVPixelBufferGetWidth(previousBuffer) == CVPixelBufferGetWidth(current),
              CVPixelBufferGetHeight(previousBuffer) == CVPixelBufferGetHeight(current),
              previousPTS.isNumeric, currentPTS.isNumeric,
              let period = ContentCadencePolicy.uniquePairPeriod(
                previousPTS: CMTimeGetSeconds(previousPTS), currentPTS: CMTimeGetSeconds(currentPTS), signalFPS: signalFPS) else { return nil }
        return InterpolationPair(previousBuffer: previousBuffer, previousSequence: previousSequence,
                                 previousPTS: previousPTS, currentPTS: currentPTS, period: period)
    }

    /// Approximate content cadence from recent exact comparisons. Actual unique-endpoint
    /// PTS intervals, not this estimate, set the VT and presentation slot for each pair.
    private func pairBudgetMultiplier() -> Double {
        guard duplicatePairWindow.count >= 8 else { return 1 }
        // Content that switched back to full rate must lose the scaled budget at once;
        // only the duplicate-heavy direction earns the slower windowed confirmation.
        if duplicatePairWindow.suffix(4).allSatisfy({ !$0 }) { return 1 }
        let uniques = duplicatePairWindow.reduce(0) { $0 + ($1 ? 0 : 1) }
        let uniqueRatio = Double(uniques) / Double(duplicatePairWindow.count)
        guard uniqueRatio > 0, uniqueRatio <= 0.75 else { return 1 }
        return min(1 / uniqueRatio, 3.0) // 20 FPS content in a 60 Hz signal needs 3x
    }

    private func endpointIsFresh(_ pending: PendingSource, target: Double? = nil) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= pending.receivedAt, pending.sourcePeriod > 0 else { return false }
        let age = Double(now - pending.receivedAt) / 1_000_000_000
        let submissionLead = max(0, (target ?? CACurrentMediaTime()) - CACurrentMediaTime())
        return age + submissionLead <= 3 * pending.sourcePeriod
    }

    func draw(in view: MTKView) {
        guard let ciContext, let commands else { return }
        guard !retiringForPresentationFailure else { frames.setPreviewState("retired"); return }
        // Occluded/minimized windows may defer presentation callbacks. Evaluate
        // lost-presentation deadlines only when this window can actually display.
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { frames.setPreviewState("hidden"); return }
        // A completed GPU command can lose its presentation callback during a display
        // failure. Retire the entire old layer rather than recycling tokens whose old
        // drawables might still present later. SwiftUI constructs a fresh preview layer.
        if !outstandingPresentations.isEmpty, outstandingPresentations.values.allSatisfy({ $0.gpuCompleted }),
           outstandingPresentations.values.contains(where: { CACurrentMediaTime() > $0.deadline + 0.25 }) {
            retiringForPresentationFailure = true
            comfortableMidpoints = 0
            interpolationLink?.invalidate(); queuedFrames.removeAll()
            frames.setInterpolationState("呈现中断，重建预览")
            onPresentationRecovery?()
            return
        }
        guard let initial = frames.latestSnapshot() else { frames.setPreviewState("no-input"); return }
        var (buffer, sequence, receivedAt) = (initial.buffer, initial.sequence, initial.receivedAt)
        var sourcePTS = initial.pts
        var sourceIsUniqueContent = true
        // Cleared when this frame's first-copy timing is unknown; it may still
        // present natively, but must not become the next pair's timing reference.
        var uniqueReferenceEligible = true
        let streamEpoch = initial.streamEpoch
        if streamEpoch != sourceStreamEpoch {
            sourceStreamEpoch = streamEpoch; presentationEpoch &+= 1
            adaptiveLongEdge = nil; interpolationDimensions = nil
            queuedFrames.removeAll(); presentedMidpoint = nil; lastSourceSequence = nil
            lastUniqueSource = nil; lastGeneratedPresentationTime = 0
            midpointCosts.removeAll(); midpointGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll(); cooldownUntil = 0; cooldownReason = nil
            comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
            duplicatePairWindow.removeAll(); lastDuplicateCheck = nil; lastStrictCheck = nil
        }
        let size = drawableSize
        guard size.width > 0, size.height > 0 else { return }
        // GPU completion does not mean a future drawable has reached the display.
        // Limit that second lifetime separately, across mode/resize changes too.
        // The compositor can retain a prior source while M and its fixed endpoint are
        // scheduled. Three matches the existing layer pool; GPU concurrency stays ONE.
        guard outstandingPresentations.count < 3 else { frames.setPreviewState("presentation-bound"); return }
        let now = CACurrentMediaTime()
        // A reason belongs to its deadline; expired GPU failures must not label
        // a later settings/resize cooldown as another GPU failure.
        if now >= cooldownUntil { cooldownReason = nil }
        // Encode the next pair ahead of refresh, but never queue more than one source
        // period into the future. Presentation times below preserve endpoint order.
        if let waiting = awaitingSourcePresentation {
            if now > waiting.deadline + 0.05 {
                awaitingSourcePresentation = nil
                comfortableMidpoints = 0
                frames.setInterpolationState("呈现节奏调整")
            }
        }
        var skipInterpolation = false
        var endpointPresentation: Double?
        var activePairPeriod = 0.0
        /// Midpoints the active pair generates. Admission and the published budget both
        /// scale with this, so the panel cannot show a 2x budget while 3x is running.
        var activeMidpointCount = 1
        var queuedImage: CIImage?
        var consumedQueueHead = false
        if let queued = queuedFrames.first {
            if !Self.timingCompatible(queued.settings, settings) || queued.size != size || queued.aspect != aspectMode {
                queuedFrames.removeAll() // A resize or engine change invalidates every queued frame.
                comfortableMidpoints = 0
                // Preserve a live GPU-error guard; otherwise this is only a
                // settings/resize cooldown, not a newly failed GPU command.
                if cooldownReason == nil { cooldownUntil = now + FrameInterpolationPolicy.overloadCooldownSeconds }
            } else if (now - Double(queued.receivedAt) / 1_000_000_000) > 3 * queued.sourcePeriod {
                // A queued frame older than three source periods is stale: its moment has passed.
                // Rebasing it would push a picture the source has already moved past into the
                // future, so drop the queue and fall back to live capture for this draw.
                queuedFrames.removeAll()
                comfortableMidpoints = 0
                frames.setInterpolationState("呈现节奏调整")
            } else {
                // Peek only. The entry is removed after this draw is accepted for submission:
                // removing it here lost the frame whenever the GPU was busy or no drawable
                // was available, because those paths return without drawing.
                endpointPresentation = max(queued.presentationTime, lastPresentationTime + queued.sourcePeriod / Double(queued.midpointCount + 1), now + 0.001)
                (buffer, sequence, receivedAt) = (queued.buffer, queued.sequence, queued.receivedAt)
                sourcePTS = queued.sourcePTS
                sourceIsUniqueContent = queued.isUniqueContent
                activePairPeriod = queued.sourcePeriod
                activeMidpointCount = queued.midpointCount
                consumedQueueHead = true
                // An already generated frame is presented as-is; it must not be regenerated.
                if queued.isGenerated { queuedImage = queued.image; skipInterpolation = true }
            }
        }
        let forced = forceDraw || endpointPresentation != nil
        guard forced || RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode) != lastSubmitted else { return }
        // The GPU is still busy. Its completion handler re-checks the current state on the main
        // thread and schedules another draw, so this request is not lost.
        guard inFlight.wait(timeout: .now()) == .success else { frames.setPreviewState("gpu-busy"); return }
        #if MONIVIEW_PREVIEW_TESTING
        let drawableStarted = CACurrentMediaTime()
        #endif
        guard let drawable = currentDrawable, let command = commands.makeCommandBuffer() else {
            inFlight.signal()
            forceDraw = true
            // A CAMetalLayer can stop vending drawables after a display-mode change while
            // no tracked presentation is left to time out. Retire the layer like a
            // presentation failure so SwiftUI rebuilds it, instead of retrying forever.
            if drawableFailures == 0 { firstDrawableFailureAt = now }
            drawableFailures += 1
            if drawableFailures >= 3, now - firstDrawableFailureAt > 0.5 {
                retiringForPresentationFailure = true
                interpolationLink?.invalidate(); queuedFrames.removeAll()
                frames.setInterpolationState("呈现中断，重建预览")
                onPresentationRecovery?()
            }
            return
        }
        drawableFailures = 0
        #if MONIVIEW_PREVIEW_TESTING
        let waited = (CACurrentMediaTime() - drawableStarted) * 1000
        drawableWaitMS.append(waited)
        if waited > 2 { trace("DRAWABLE wait=\(waited)ms") }
        #endif
        forceDraw = false

        let encodingStarted = CACurrentMediaTime()
        guard let fresh = frames.latestSnapshot(), fresh.streamEpoch == streamEpoch else {
            queuedFrames.removeAll(); forceDraw = true; inFlight.signal(); requestRender(); return
        }
        // A drawable may have waited for presentation. Always take the newest frame afterwards.
        if endpointPresentation == nil {
            (buffer, sequence, receivedAt) = (fresh.buffer, fresh.sequence, fresh.receivedAt)
            sourcePTS = fresh.pts
        }
        // Revalidate after drawable acquisition. Never draw a stale endpoint after it
        // was discarded: restore the atomic latest snapshot for immediate fallback.
        if endpointPresentation != nil, skipInterpolation, queuedImage == nil {
            // A queued endpoint that could not be kept: fall back to the newest source so
            // the preview never shows a stale picture.
            endpointPresentation = nil; presentedMidpoint = nil
            comfortableMidpoints = 0
            (buffer, sequence, receivedAt) = (fresh.buffer, fresh.sequence, fresh.receivedAt)
            sourcePTS = fresh.pts
            frames.setInterpolationState("呈现节奏调整")
        }
        var generatedMidpoint = queuedImage != nil
        var calibratedMidpoint = false
        var presentationTime = endpointPresentation
        var sourceImage = queuedImage ?? CIImage(cvPixelBuffer: buffer)
        let mediaFPS = frames.sourceFrameRate()
        let sourceFPS = FrameInterpolationPolicy.nominalInputFPS(mediaFPS ?? 0) ?? 0
        let interpolationRequested = settings.enhancementEnabled && settings.frameInterpolation != .off
        let displayFPS = min(observedDisplayFPS, Double(window.screen?.maximumFramesPerSecond ?? 60))
        // Measure true content cadence from the capture stream itself. This must not depend
        // on the presentation queue being empty: while a multi-phase pair is draining, that
        // queue is almost always non-empty, and gating here made the estimate see sparse,
        // out-of-order samples that drifted between 20 and 34 FPS for the same 30 FPS game.
        if queuedImage == nil {
            let cadencePair = frames.interpolationPair(sequence: sequence)
            // Two distinct questions, two distinct judges. The tolerant one drives the cadence
            // estimate; the exact one decides whether this frame carries new content, because
            // treating a near-duplicate as a repeat here skips the whole spatial pipeline for a
            // frame that really is new.
            let isDuplicate = cadencePair.flatMap {
                observeDuplicateCadence(previous: $0.0, current: buffer,
                    sequence: sequence, previousSequence: $0.1, streamEpoch: streamEpoch)
            }
            let isExactDuplicate = cadencePair.flatMap {
                isDuplicatePair(previous: $0.0, current: buffer, sequence: sequence,
                                previousSequence: $0.1, streamEpoch: streamEpoch) ? true : false
            }
            // A duplicate of the newest capture is not necessarily a duplicate of the
            // last displayed content: GPU work may have missed that content's first copy.
            sourceIsUniqueContent = !(isExactDuplicate ?? false)
            if settings.skipsExactDuplicateInterpolation, let previous = lastUniqueSource,
               previous.streamEpoch == streamEpoch {
                sourceIsUniqueContent = !isDuplicatePair(previous: previous.buffer, current: buffer,
                    sequence: sequence, previousSequence: previous.sequence, streamEpoch: streamEpoch)
                // Recovering the first copy's timestamp changes the pair's timing, so it needs
                // exact repeat evidence. Two genuinely different pictures can differ by only a
                // few bytes, and the tolerant judge calls those repeats; adopting the older PTS
                // on that basis would pair the frame with the wrong period and phase.
                if isExactDuplicate == true && sourceIsUniqueContent, let cadencePair,
                   cadencePair.2.isNumeric, CMTimeCompare(cadencePair.2, previous.pts) > 0,
                   CMTimeCompare(cadencePair.2, sourcePTS) < 0 {
                    sourcePTS = cadencePair.2 // Recover the first copy's original timestamp.
                } else if cadencePair == nil && sourceIsUniqueContent {
                    // The capture advanced after our snapshot. Present native content;
                    // its first-copy PTS is unknown, so do not synthesize this pair.
                    skipInterpolation = true
                    uniqueReferenceEligible = false
                }
            }
        }
        // Snap the estimate onto a standard rate here too, so the multiplier the renderer
        // picks and the one the panel reports come from the same number. Without this the
        // panel used the snapped value while scheduling used the raw one, and a value
        // sitting between two standard rates could show one target and run another.
        let rawContentFPS = sourceFPS / pairBudgetMultiplier()
        let contentFPS = ContentCadencePolicy.quantizedRate(pairBudgetMultiplier() > 1.05 ? rawContentFPS : nil)
            ?? (pairBudgetMultiplier() > 1.05 ? rawContentFPS : sourceFPS)
        frames.setMeasuredContentFPS(pairBudgetMultiplier() > 1.05 && contentFPS >= 1 ? contentFPS : nil)
        let admitted = FrameInterpolationPolicy.eligibility(runtimeSupported: FrameInterpolatorSupport.isSupported(settings.frameInterpolation), inputFPS: contentFPS, displayFPS: displayFPS, inputValid: true)
        // An exact-copy source (30 Hz content in a 60 Hz signal) needs no new presentation:
        // the display already holds the identical previous drawable. Skipping the whole
        // spatial pipeline here saves GPU for midpoint quality on the unique frames.
        if interpolationRequested, admitted, !sourceIsUniqueContent, !forced, !skipInterpolation, endpointPresentation == nil,
           queuedFrames.isEmpty, CACurrentMediaTime() >= cooldownUntil,
           let duplicatePair = frames.interpolationPair(sequence: sequence), lastSourceSequence == duplicatePair.1,
           isDuplicatePair(previous: duplicatePair.0, current: buffer, sequence: sequence, streamEpoch: streamEpoch) {
            frames.markDuplicateSkipped(sequence: sequence, streamEpoch: streamEpoch)
            lastSourceSequence = sequence
            lastSubmitted = RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode)
            frames.setPreviewState("dedup")
            if CACurrentMediaTime() - lastGeneratedPresentationTime > 0.25 {
                frames.setInterpolationState("重复画面 · 跳过插帧")
            }
            inFlight.signal()
            return
        }
        if interpolationRequested {
            if !FrameInterpolatorSupport.isSupported(settings.frameInterpolation) { frames.setInterpolationState("插帧不可用") }
            else if !admitted {
                frames.setInterpolationState(mediaFPS == nil ? "等待稳定输入帧率" :
                    (sourceFPS == 0 ? "当前输入帧率不支持2×，使用原始帧率" : "显示器刷新率不足，使用原始帧率"))
            }
            else if CACurrentMediaTime() < cooldownUntil { frames.setInterpolationState(cooldownReason ?? (settings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率")) }
            else if endpointPresentation == nil, !skipInterpolation,
                    let pair = interpolationPair(current: buffer, currentPTS: sourcePTS, sequence: sequence,
                        streamEpoch: streamEpoch, signalFPS: sourceFPS, currentIsDuplicate: !sourceIsUniqueContent),
                    let dimensions = FrameInterpolationPolicy.targetDimensions(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), mode: settings.frameInterpolation, inputFPS: contentFPS, maximumLongEdge: adaptiveLongEdge),
                    !isDuplicatePair(previous: pair.previousBuffer, current: buffer, sequence: sequence,
                        previousSequence: pair.previousSequence, streamEpoch: streamEpoch),
                    let interpolator = interpolationEngine {
                #if MONIVIEW_PREVIEW_TESTING
                trace("PAIR seq=\(sequence) previous=\(pair.previousSequence) ticks=\(pair.period * sourceFPS) contentFPS=\(contentFPS)")
                #endif
                if interpolationDimensions != dimensions {
                    interpolationDimensions = dimensions
                    midpointCosts.removeAll(); midpointGPUCosts.removeAll(); calibrationWarmupsRemaining = 2
                }
                interpolator.prepare(width: dimensions.width, height: dimensions.height)
                if !interpolator.isReady { frames.setInterpolationState("插帧准备中") }
                if interpolator.isReady {
                    // Admission uses the sample-gated estimate, not P95: right after a preset
                    // or size change the history is empty and a single warm-up sample would
                    // otherwise be enough to reject the pair and start a cooldown, which then
                    // keeps clearing the history it needs. P95 still drives the display so a
                    // long tail stays visible to the user.
                    let midCost = admissionCost(midpointCosts), sourceCost = admissionCost(nativeCosts)
                    // Ask for the smallest multiplier that lifts this content to the panel's
                    // rate. 30 FPS content keeps its existing single-midpoint path; slower
                    // content fills the same period with two midpoints instead of one.
                    // Never ask an engine for a phase it cannot supply: the VideoToolbox
                    // processor only produces the midpoint, so it stays on 2x and the flow
                    // engine is the tier that can fill slower content up to the panel rate.
                    let engineMultipliers = interpolator.supportedMultipliers
                    // Aim at the conventional smoothness target, not at the panel rate:
                    // doubling 20 FPS content on a 120 Hz panel should reach 60, and only
                    // content that cannot get there by doubling earns the third phase.
                    let requested = FrameInterpolationPolicy.multiplier(
                        contentFPS: contentFPS, targetFPS: 60, displayFPS: displayFPS)
                    // Prefer the requested step, otherwise the lowest the engine declares.
                    // Taking the first element assumed the arrays are ordered, so declaring a
                    // wider set for an engine would silently change what a fallback means.
                    let stated = engineMultipliers.contains(requested)
                        ? requested
                        : (engineMultipliers.min() ?? 2)
                    // The step came from a tolerant cadence estimate; the period comes from
                    // measured PTS. Capture noise can read a 60 Hz pair as 20 FPS content and
                    // ask for three presentations where the display only has room for two, which
                    // pushes the endpoint past its deadline. Hold the step to what this pair fits.
                    let multiplier = FrameInterpolationPolicy.multiplierFittingPair(
                        stated, pairPeriod: pair.period, displayFPS: displayFPS)
                    let phases = FrameInterpolationPolicy.midpointPhases(multiplier: multiplier)
                    guard !phases.isEmpty else {
                        // The GPU semaphore is already held here, so leaving without releasing it
                        // would stall the renderer permanently rather than skipping one pair.
                        inFlight.signal()
                        return
                    }
                    activeMidpointCount = phases.count
                    let steps = Double(phases.count)
                    // The published step follows the phases actually produced; it is updated again
                    // below when one of them fails to encode, so the panel never advertises 3x
                    // for a pair that ran as 2x.
                    frames.setActiveMultiplier(steps + 1)
                    let slot = pair.period / (steps + 1)
                    activePairPeriod = pair.period
                    let budgetSlot = slot
                    let budgetFits = midCost.map { $0 <= budgetSlot * FrameInterpolationPolicy.midpointBudgetFraction } ?? false
                    let sourceFits = sourceCost.map { $0 <= budgetSlot * FrameInterpolationPolicy.budgetFraction } ?? false
                    let pairFits = midCost.flatMap { mid in sourceCost.map {
                        FrameInterpolationPolicy.costsFit(midpoints: Array(repeating: mid, count: phases.count), source: $0, slot: budgetSlot)
                    } } ?? false
                    let earliest = CACurrentMediaTime() + (midCost ?? 0.002) + slot * 0.1
                    let displaySlot = displayFPS > 0 ? 1 / displayFPS : slot
                    let nextPairSlot = scheduledSourceUntil + slot
                    let target = nextPairSlot >= earliest ? nextPairSlot :
                        displayTargetTime + max(0, ceil((earliest - displayTargetTime) / displaySlot)) * displaySlot
                    let deadlineFits = displayTargetTime > 0 && target <= CACurrentMediaTime() + 1.5 * pair.period
                    // A hidden calibration pass shares the native frame's command buffer. It
                    // never increments generated counts or advertises interpolation as active.
                    // Admission must judge the work the pair will actually do. A multi-phase
                    // pair spends several midpoint commands inside the same period, so testing
                    // one midpoint against the individual cap would admit a pair that overruns.
                    let mayGenerate = midCost.flatMap { mid in sourceCost.map {
                        FrameInterpolationPolicy.allowsMeasuredPair(midpoints: Array(repeating: mid, count: phases.count),
                            source: $0, slot: budgetSlot,
                            force: settings.forceFrameInterpolation, deadlineFits: deadlineFits)
                    } } ?? false
                    if midCost == nil || mayGenerate {
                        // One midpoint per phase, kept in presentation order. The first is
                        // presented by this command; the remaining ones and the endpoint wait
                        // in the bounded queue so a 3x pair fills its period in sequence.
                        var producedImages: [CIImage] = []
                        for phase in phases {
                            guard queuedFrames.count + producedImages.count + 1 < Self.maximumQueuedFrames else { break }
                            guard let midpoint = interpolator.interpolate(previous: CIImage(cvPixelBuffer: pair.previousBuffer), current: sourceImage,
                                previousTime: pair.previousPTS, currentTime: pair.currentPTS, context: ciContext, command: command,
                                previousBuffer: pair.previousBuffer, currentBuffer: buffer,
                                fastInputResampling: settings.frameInterpolation == .efficient,
                                blendFactor: phase) else { break }
                            producedImages.append(midpoint)
                        }
                        if let first = producedImages.first {
                            if midCost == nil {
                                calibratedMidpoint = true
                            } else {
                                // Schedule and budget by what was actually produced. A phase that
                                // failed to encode must not leave the pair claiming a slot it does
                                // not fill, which would push later presentations out of position.
                                let producedCount = producedImages.count
                                activeMidpointCount = producedCount
                                let producedSlot = pair.period / Double(producedCount + 1)
                                frames.setActiveMultiplier(Double(producedCount + 1))
                                generatedMidpoint = true; sourceImage = first
                                presentationTime = target
                                if producedImages.count > 1 {
                                    for offset in 1..<producedImages.count {
                                        queuedFrames.append(QueuedFrame(image: producedImages[offset], buffer: buffer,
                                            receivedAt: receivedAt, sequence: sequence, settings: settings,
                                            size: size, aspect: aspectMode,
                                            presentationTime: target + producedSlot * Double(offset),
                                            sourcePeriod: pair.period, sourcePTS: sourcePTS,
                                            isUniqueContent: sourceIsUniqueContent, isGenerated: true,
                                            midpointCount: producedCount))
                                    }
                                }
                                queuedFrames.append(QueuedFrame(image: CIImage(cvPixelBuffer: buffer), buffer: buffer,
                                    receivedAt: receivedAt, sequence: sequence, settings: settings,
                                    size: size, aspect: aspectMode,
                                    presentationTime: target + producedSlot * Double(producedImages.count),
                                    sourcePeriod: pair.period, sourcePTS: sourcePTS,
                                    isUniqueContent: sourceIsUniqueContent, isGenerated: false,
                                    midpointCount: producedCount))
                            }
                        }
                    } else if !settings.forceFrameInterpolation && (!budgetFits || !sourceFits || !pairFits) {
                        cooldownReason = nil
                        cooldownUntil = CACurrentMediaTime() + FrameInterpolationPolicy.overloadCooldownSeconds
                        // Clear both histories: a stale native P95 otherwise keeps the next
                        // pair's target late, which rejects pairs and never refreshes it.
                        midpointCosts.removeAll(); nativeCosts.removeAll(); calibrationWarmupsRemaining = 2
                        frames.setInterpolationState(settings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率")
                    } else if !deadlineFits {
                        // Force cannot make a late pair present on time. Do not leave
                        // a previous successful pair's running label on native fallback.
                        frames.setInterpolationState("呈现节奏调整")
                    }
                }
            }
        } else { frames.setInterpolationState("关闭") }
        // A native fallback must also follow any already scheduled endpoint.
        if endpointPresentation == nil && CACurrentMediaTime() < lastPresentationTime {
            presentationTime = max(presentationTime ?? 0, lastPresentationTime + (displayFPS > 0 ? 1 / displayFPS : 0.016667))
        }
        // Core Image honors CVPixelBuffer's YUV matrix and full/video-range attachments.
        var image = sourceImage
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
        // Smooth midpoints use their measured working size and one final resize.
        // Otherwise a reduced midpoint can fall through the >3x spatial wrapper
        // guard into expensive Lanczos, undoing the purpose of the lighter tier.
        // A generated midpoint is a blended frame: it carries less real detail than a
        // source frame by construction. Running it through the full spatial enlargement
        // therefore spends the biggest part of the pair budget on pixels the blend cannot
        // justify. Both cheap tiers keep the lightweight final resize instead, which is
        // what lets 30->60 hold its slot; only the explicitly sharp tier scales a midpoint.
        let smoothMidpoint = generatedMidpoint
            && (settings.frameInterpolation == .efficient || settings.frameInterpolation == .flowBlend)
        let workingScale = settings.enhancementEnabled && !smoothMidpoint ? max(1, targetLongEdge / sourceLongEdge) : 1
        let workingWidth = Int((source.width * workingScale).rounded())
        let workingHeight = Int((source.height * workingScale).rounded())
        var usedMetalFX = false
        var usedAI = false
        var aiStatus = ""
        if settings.upscaleMethod == .ai {
            if interpolationRequested { aiStatus = "AI 超分暂停，关闭插帧后恢复" }
            else if !settings.enhancementEnabled { aiStatus = "画质增强已关闭" }
            else if workingScale <= 1.01 { aiStatus = "当前目标无需放大" }
            else if #available(macOS 26.0, *),
                    !AIUpscaler.hasSupportedScaleFactor(sourceWidth: Int(source.width.rounded()), sourceHeight: Int(source.height.rounded())) {
                aiStatus = "系统 AI 超分不支持此输入尺寸，使用空间放大"
            }
            else { aiStatus = "当前尺寸无可用 AI 倍率；提高目标或关闭低延迟模式" }
        }
        if settings.enhancementEnabled, workingScale > 1.01, settings.upscaleMethod == .ai, !interpolationRequested {
            let sourceWidth = Int(source.width.rounded())
            let sourceHeight = Int(source.height.rounded())
            if #available(macOS 26.0, *), let ai = aiUpscaler,
               let factor = AIUpscaler.scaleFactor(for: sourceWidth, sourceHeight: sourceHeight, requested: workingScale) {
                // Session warmup happens off the draw path; frames fall back until the model is ready.
                ai.prepare(sourceWidth: sourceWidth, sourceHeight: sourceHeight, factor: factor, colorSpace: colorSpace)
                aiStatus = ai.preparationFailed ? "AI 超分加载失败，使用空间放大并重试" : "AI 超分准备中，暂用空间放大"
                if ai.isReady, let scaled = ai.upscale(image, context: ciContext, command: command, colorSpace: colorSpace) {
                    image = scaled
                    usedAI = true
                    aiStatus = "AI 超分运行中"
                }
            } else { stopAIUpscaler() }
        } else { stopAIUpscaler() }
        frames.setAIUpscaleStatus(aiStatus)
        if settings.enhancementEnabled, workingScale > 1.01, !usedAI {
            if settings.upscaleMethod != .lanczos, let scaled = upscaler?.upscale(image, width: workingWidth, height: workingHeight, context: ciContext, command: command, colorSpace: colorSpace) {
                image = scaled; usedMetalFX = true
            } else {
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: workingScale, kCIInputAspectRatioKey: 1.0])
            }
        }
        let enhancedSize = workingScale > 1.01 ? "\(Int(image.extent.width.rounded()))×\(Int(image.extent.height.rounded()))" : nil
        // Native-size, MetalFX and AI previews match the recording; Lanczos scaling compensates more.
        let enhancementSharpening = usedMetalFX || usedAI || workingScale <= 1.01 ? VideoImageProcessor.enhancementSharpening : VideoImageProcessor.scaledPreviewSharpening
        let sharpness = settings.sharpness + (settings.enhancementEnabled ? settings.enhancementStrength * enhancementSharpening : 0)
        let engine = smoothMidpoint ? "流畅插帧" : (usedAI ? "AI 超分" : (usedMetalFX ? "MetalFX" : (workingScale > 1.01 ? "Lanczos" : (sharpness > 0.001 ? "原始＋锐化" : "原始"))))
        if sharpness > 0.001 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness]) }
        let output = image.extent
        let scale = aspectMode == .fit ? min(size.width / output.width, size.height / output.height) : max(size.width / output.width, size.height / output.height)
        if aspectMode == .stretch {
            let resize = CGAffineTransform(scaleX: size.width / output.width, y: size.height / output.height)
            image = smoothMidpoint ? image.transformed(by: resize, highQualityDownsample: false) : image.transformed(by: resize)
        } else if usedMetalFX || image.extent.width > originalExtent.width ||
                    (generatedMidpoint && settings.frameInterpolation == .efficient) {
            let resize = CGAffineTransform(scaleX: scale, y: scale)
            image = smoothMidpoint ? image.transformed(by: resize, highQualityDownsample: false) : image.transformed(by: resize)
        } else if abs(scale - 1) > 0.001 {
            if scale > 1.001 {
                // Enlarging to fit the window: Lanczos buys no detail here, and this
                // step runs for the midpoint and its endpoint on every pair, so it
                // lands on the interpolation budget twice.
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                // Shrinking needs the antialiasing that only the resampling filters give.
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
            }
        }
        let scaled = image.extent
        let transform = CGAffineTransform(translationX: (size.width - scaled.width) / 2 - scaled.minX, y: (size.height - scaled.height) / 2 - scaled.minY)
        let bounds = CGRect(origin: .zero, size: size)
        image = image.transformed(by: transform).composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
        ciContext.render(image, to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: colorSpace)
        let presentedFrameStore = frames
        let presentedSequence = sequence
        nextPresentationToken &+= 1
        let token = nextPresentationToken
        outstandingPresentations[token] = Presentation(deadline: presentationTime ?? CACurrentMediaTime())
        #if MONIVIEW_PREVIEW_TESTING
        peakOutstandingPresentations = max(peakOutstandingPresentations, outstandingPresentations.count)
        #endif
        let epoch = presentationEpoch
        let wasGenerated = generatedMidpoint
        let wasEndpoint = endpointPresentation != nil
        let period = activePairPeriod > 0 ? activePairPeriod / Double(activeMidpointCount + 1) : (sourceFPS > 0 ? 0.5 / sourceFPS : 0)
        let sourceBufferForPresentation = buffer
        let sourcePTSForPresentation = sourcePTS
        let sourceWasUniqueForPresentation = sourceIsUniqueContent && uniqueReferenceEligible
        #if MONIVIEW_PREVIEW_TESTING
        let suppressPresentation = suppressPresentedCallbacks
        #endif
        drawable.addPresentedHandler { [weak self] presented in
            #if MONIVIEW_PREVIEW_TESTING
            guard !suppressPresentation else { return }
            #endif
            let time = presented.presentedTime
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.outstandingPresentations.removeValue(forKey: token) != nil else { return }
                guard time > 0 else {
                    if wasEndpoint { self.comfortableMidpoints = 0 }
                    self.forceDraw = true; self.requestRenderIfStateChanged(); return
                }
                // Presentation counts exclude failed/retired-stream drawables and
                // settings/resize redraws of the same captured frame.
                if wasGenerated { presentedFrameStore.markGenerated(streamEpoch: streamEpoch, presentedTime: time) }
                else { presentedFrameStore.markPresentedSource(sequence: presentedSequence, streamEpoch: streamEpoch, presentedTime: time) }
                #if MONIVIEW_PREVIEW_TESTING
                self.onPresentation?(presentedSequence, wasGenerated, time)
                if wasGenerated || wasEndpoint { self.trace("PRESENT seq=\(presentedSequence) mid=\(wasGenerated) deadlineError=\((time - (presentationTime ?? time))*1000)ms") }
                #endif
                if self.awaitingSourcePresentation?.sequence == presentedSequence && !wasGenerated { self.awaitingSourcePresentation = nil }
                guard self.presentationEpoch == epoch else { self.requestRenderIfStateChanged(); return }
                if wasGenerated {
                    self.lastGeneratedPresentationTime = time
                    self.presentedMidpoint = (presentedSequence, time, presentationTime ?? time)
                }
                else {
                    if wasEndpoint, let midpoint = self.presentedMidpoint,
                       midpoint.sequence == presentedSequence {
                        // Steadily presented pairs prove interpolation is running; the label
                        // must not depend on sub-vsync phase. The stricter deadline check
                        // remains the quality gate for adaptive step-ups.
                        presentedFrameStore.setInterpolationState(self.settings.forceFrameInterpolation ? "强制插帧运行中" : "插帧运行中")
                        if ContentCadencePolicy.presentedPairIsTimely(
                            midpointTime: midpoint.time, midpointDeadline: midpoint.deadline,
                            endpointTime: time,
                            endpointDeadline: presentationTime ?? time, slot: period,
                            presentationIntervalP95: presentedFrameStore.presentationP95() / 1000) {
                            self.recordComfortablePresentedPair(slot: period)
                        } else {
                            self.comfortableMidpoints = 0
                        }
                    } else if wasEndpoint {
                        self.comfortableMidpoints = 0
                    }
                    self.presentedMidpoint = nil
                }
                self.requestRenderIfStateChanged()
            }
        }
        if let time = presentationTime { command.present(drawable, atTime: time) }
        else { command.present(drawable) }
        lastPresentationTime = presentationTime ?? CACurrentMediaTime()
        do {
            let delay = max(0.26, (presentationTime ?? CACurrentMediaTime()) - CACurrentMediaTime() + 0.26)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.outstandingPresentations[token] != nil else { return }
                self.requestRender()
            }
        }
        if !generatedMidpoint, let time = presentationTime {
            scheduledSourceUntil = time; awaitingSourcePresentation = (sequence, time)
        }
        let semaphore = inFlight
        let frameStore = frames
        let frameSequence = sequence
        let frameReceivedAt = receivedAt
        let shouldMeasure = !generatedMidpoint && frameSequence != lastMeasuredSequence
        let wasMidpoint = generatedMidpoint
        let wasCalibration = calibratedMidpoint
        // Native fallbacks must not overwrite the content-pair budget with the faster
        // capture slot (30-in-60 otherwise oscillates between 30 and 15 ms budgets).
        let measuredSlot = activePairPeriod > 0 ? activePairPeriod / Double(activeMidpointCount + 1) : (contentFPS > 0 ? 0.5 / contentFPS : 0)
        let measuredBudgetSlot = measuredSlot
        let expectedSettings = settings
        let measuredDimensions = interpolationDimensions
        let encodedCPUSeconds = CACurrentMediaTime() - encodingStarted
        command.addCompletedHandler { [weak self] completed in
            let callbackAt = CACurrentMediaTime()
            let gpuMS = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1000
            let succeeded = completed.status == .completed
            // Measure at the GPU completion callback, before waiting for the main thread.
            // LatestVideoFrame is lock-protected; parameter/resize redraws are not new video frames.
            if succeeded {
                // Report the source-frame spatial pipeline consistently; temporal
                // work has its own size/status. M/B alternation must not flicker HUD.
                if !wasMidpoint {
                    frameStore.setEngine(engine)
                    frameStore.setEnhancedSize(enhancedSize)
                }
                if shouldMeasure { frameStore.markRendered(receivedAt: frameReceivedAt, gpuMS: gpuMS) }
            }
            let cost = FrameInterpolationPolicy.processingCost(cpu: encodedCPUSeconds,
                gpu: gpuMS / 1000, encodeToCompletion: max(0, callbackAt - encodingStarted))
            #if MONIVIEW_PREVIEW_TESTING
            if (wasMidpoint || wasCalibration || wasEndpoint), frameSequence % 60 == 0, ProcessInfo.processInfo.environment["MONIVIEW_TEST_TRACE"] == "1" {
                print("TIMING seq=\(frameSequence) mid=\(wasMidpoint) calib=\(wasCalibration) CPU=\(encodedCPUSeconds*1000) GPU=\(gpuMS)")
            }
            #endif
            // Semaphore release and render bookkeeping remain serialized with draw(in:).
            DispatchQueue.main.async {
                guard let self else { semaphore.signal(); return }
                #if MONIVIEW_PREVIEW_TESTING
                if ProcessInfo.processInfo.environment["MONIVIEW_TEST_TRACE"] == "1", frameSequence % 60 == 0 {
                    self.trace("COMPLETE seq=\(frameSequence) mid=\(wasMidpoint) CPU=\(encodedCPUSeconds*1000) GPU=\(gpuMS) encodeToGPUStartMS=\((completed.gpuStartTime-encodingStarted)*1000) GPUEndToCallbackMS=\((callbackAt-completed.gpuEndTime)*1000) encodeToCallbackMS=\((callbackAt-encodingStarted)*1000) mainHandoffMS=\((CACurrentMediaTime()-callbackAt)*1000)")
                }
                #endif
                if succeeded { self.outstandingPresentations[token]?.gpuCompleted = true }
                if succeeded && shouldMeasure { self.lastMeasuredSequence = frameSequence }
                if succeeded && !wasMidpoint && self.presentationEpoch == epoch { self.lastSourceSequence = frameSequence }
                if succeeded && !wasMidpoint && self.presentationEpoch == epoch,
                   self.sourceStreamEpoch == streamEpoch,
                   sourceWasUniqueForPresentation, sourcePTSForPresentation.isNumeric,
                   self.lastUniqueSource.map({ $0.sequence < frameSequence }) ?? true {
                    // The ordered endpoint is submitted before another pair can encode.
                    // A delayed presentation callback must not force the next pair to
                    // use an older reference and discard every second unique frame.
                    self.lastUniqueSource = UniqueSource(buffer: sourceBufferForPresentation,
                        sequence: frameSequence, streamEpoch: streamEpoch, pts: sourcePTSForPresentation)
                }
                if self.presentationEpoch == epoch && self.settings == expectedSettings && interpolationRequested {
                    // Model cold-start commands are measured and shown, but two hidden
                    // native-only warmups are separate from the steady-state P95 budget.
                    let warming = wasCalibration && self.calibrationWarmupsRemaining > 0
                    if succeeded {
                        if wasMidpoint || wasCalibration, let dimensions = measuredDimensions {
                            frameStore.setInterpolationWorkingSize("\(dimensions.width)×\(dimensions.height)")
                        }
                        if warming {
                            self.calibrationWarmupsRemaining -= 1
                            frameStore.setInterpolationCost(seconds: cost + (self.admissionCost(self.nativeCosts) ?? self.p95(self.nativeCosts) ?? 0), budget: Double(activeMidpointCount + 1) * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                            frameStore.setInterpolationState("插帧准备中")
                        } else if wasMidpoint || wasCalibration {
                            self.midpointCosts.append(cost); self.midpointCosts = Array(self.midpointCosts.suffix(32))
                            self.midpointGPUCosts.append(gpuMS); self.midpointGPUCosts = Array(self.midpointGPUCosts.suffix(32))
                            if let gpuP95 = self.p95(self.midpointGPUCosts) { frameStore.setInterpolationGPUCost(milliseconds: gpuP95) }
                            frameStore.setInterpolationCost(seconds: (self.admissionCost(self.midpointCosts) ?? self.p95(self.midpointCosts) ?? cost) + (self.admissionCost(self.nativeCosts) ?? self.p95(self.nativeCosts) ?? 0), budget: Double(activeMidpointCount + 1) * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                        } else {
                            self.nativeCosts.append(cost); self.nativeCosts = Array(self.nativeCosts.suffix(32))
                            if let mid = self.p95(self.midpointCosts) {
                                frameStore.setInterpolationCost(seconds: mid + (self.admissionCost(self.nativeCosts) ?? self.p95(self.nativeCosts) ?? cost), budget: Double(activeMidpointCount + 1) * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                            }
                        }
                    }
                    // Wait for enough steady-state samples before judging cost: the commands
                    // right after a switch carry warm-up and must not trigger cooldown.
                    let measuredCost = (wasMidpoint || wasCalibration) ? self.admissionCost(self.midpointCosts) : self.admissionCost(self.nativeCosts)
                    // The pair's cost is judged on the frames it generates, matching how the
                    // work was admitted. Comparing one midpoint against the individual cap here
                    // let a multi-phase pair pass admission and then be judged by a laxer rule.
                    let pairOverBudget = self.admissionCost(self.midpointCosts).flatMap { mid in
                        self.admissionCost(self.nativeCosts).map {
                            !FrameInterpolationPolicy.costsFit(midpoints: Array(repeating: mid, count: activeMidpointCount),
                                                              source: $0, slot: measuredBudgetSlot)
                        }
                    } ?? false
                    let individualLimit = measuredBudgetSlot * ((wasMidpoint || wasCalibration) ? FrameInterpolationPolicy.midpointBudgetFraction : FrameInterpolationPolicy.budgetFraction)
                    if !succeeded || (!expectedSettings.forceFrameInterpolation && !warming && (wasMidpoint || wasCalibration || wasEndpoint) && measuredSlot > 0 && ((measuredCost ?? 0) > individualLimit || pairOverBudget)) {
                        // A successful midpoint already owns a fixed endpoint. Complete
                        // that pair even when its measured cost disables the NEXT pair.
                        // GPU errors invalidate the pair; age/epoch guards still apply.
                        self.cooldownReason = succeeded ? nil : "GPU错误，保留原始画面"
                        if !succeeded { self.queuedFrames.removeAll() }
                        let lower = measuredDimensions.flatMap { FrameInterpolationPolicy.reducedLongEdge(after: max($0.width, $0.height)) }
                        // Only Smooth changes inference resolution. Quality retains its
                        // advertised 1080p cap and retries after a bounded cooldown.
                        if succeeded, expectedSettings.frameInterpolation == .efficient, let lower {
                            self.adaptiveLongEdge = lower
                            self.cooldownUntil = CACurrentMediaTime() + 0.1
                        } else {
                            self.cooldownUntil = CACurrentMediaTime() + FrameInterpolationPolicy.overloadCooldownSeconds
                        }
                        // A size that fails right after a raise is genuinely too expensive;
                        // do not climb back into it for the rest of this session.
                        if succeeded, let failed = measuredDimensions.map({ max($0.width, $0.height) }),
                           failed == self.lastRaisedToLongEdge {
                            self.blockedRaiseTarget = failed
                            self.lastRaisedToLongEdge = nil
                        }
                        // Both histories feed the cost reading and the next pair's target.
                        // Clearing only the midpoint side left stale native samples driving
                        // the schedule, which kept rejecting pairs and so never produced a
                        // fresh sample to replace them.
                        self.midpointCosts.removeAll(); self.nativeCosts.removeAll()
                        self.calibrationWarmupsRemaining = 2
                        self.comfortableMidpoints = 0
                        #if MONIVIEW_PREVIEW_TESTING
                        self.trace("COST fail seq=\(frameSequence) mid=\(wasMidpoint) calib=\(wasCalibration) endpoint=\(wasEndpoint) CPU=\(encodedCPUSeconds*1000) GPU=\(gpuMS)")
                        #endif
                        frameStore.setInterpolationState(self.cooldownReason ?? (expectedSettings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率"))
                    }
                }
                if !succeeded && self.awaitingSourcePresentation?.sequence == frameSequence {
                    self.awaitingSourcePresentation = nil; self.scheduledSourceUntil = 0
                }
                if !succeeded { self.outstandingPresentations.removeValue(forKey: token) }
                semaphore.signal()
                if succeeded {
                    self.failedDrawRetries = 0
                } else if self.failedDrawRetries < 3 {
                    // Retry a failed command buffer a few times, then wait for the next change.
                    self.failedDrawRetries += 1
                    self.forceDraw = true
                }
                if self.outstandingPresentations.values.contains(where: { CACurrentMediaTime() > $0.deadline + 0.25 }) {
                    self.requestRender()
                } else { self.requestRenderIfStateChanged() }
            }
        }
        frames.setPreviewState("submitted")
        command.commit()
        // The frame is now on the GPU, so it is safe to drop the queue entry that produced it.
        // Doing this earlier lost the frame on any path that returns before submission.
        if consumedQueueHead, !queuedFrames.isEmpty { queuedFrames.removeFirst() }
        lastSubmitted = RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode, midpoint: generatedMidpoint)
    }
}

/// CADisplayLink retains its target; this adapter keeps the preview's lifetime independent.
private final class InterpolationDisplayLinkProxy: NSObject {
    weak var view: CapturePreviewNSView?
    init(view: CapturePreviewNSView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.interpolationTick(link) }
}
