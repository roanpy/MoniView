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
    private var previousSkipDuplicates = false
    private var cooldownUntil = 0.0
    private var cooldownReason: String?
    private var nativeCosts: [Double] = []
    /// The first command encodes every generated phase for a pair, so its cost is a batch.
    private var generationBatchCosts: [Double] = []
    /// Later generated phases are cached images; their draw commands have presentation cost only.
    private var generatedPresentationCosts: [Double] = []
    /// GPU-only span of generation batches, published with total processing cost.
    private var generationBatchGPUCosts: [Double] = []
    private var calibrationWarmupsRemaining = 2
    private var adaptiveLongEdge: Int?
    private var interpolationDimensions: FrameInterpolationPolicy.Dimensions?
    /// Recent exact adjacent-pair outcomes estimate content cadence; per-pair PTS intervals
    /// independently set midpoint budget and presentation timing.
    private var lastStrictCheck: (sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64, result: Bool)?
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
    /// Failure injection for the clearing draw alone, so a test can lose its presentation callback
    /// while the frame path stays healthy. Absent from production builds.
    var suppressBlankPresentedCallbacks = false
    var injectInterpolationOverBudget = false
    private(set) var injectedOverBudgetCount = 0
    #endif
    #if MONIVIEW_PREVIEW_TESTING
    private func trace(_ value: String) { if ProcessInfo.processInfo.environment["MONIVIEW_TEST_TRACE"] == "1" { print(value) } }
    #endif
    private var scheduledSourceUntil = 0.0
    private var awaitingSourcePresentation: (sequence: UInt64, deadline: Double)?
    private var presentedMidpoint: (sequence: UInt64, time: Double, deadline: Double)?
    /// A blank draw that was submitted and is waiting for its presentation callback. A callback
    /// that never arrives re-arms the request, and a second loss retires the layer through the
    /// same path as a lost frame presentation.
    private var blankPresentationInFlight: (epoch: UInt64, deadline: Double)?
    private var blankPresentationAttempts = 0
    private var blankRetryScheduled = false
    /// How long a submitted blank may wait for its presentation callback before it is retried.
    private static let blankPresentationDeadline: Double = 0.25
    /// Clearing attempts allowed before the layer is retired through the presentation-recovery
    /// path. Bounds both a repeated GPU failure and a repeatedly lost presentation callback.
    private static let maximumBlankPresentationAttempts = 2
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
        /// Actual generated phase positions, including a partial result if a later phase failed.
        let phases: [Double]
        /// Interval from the previous pair presentation to this frame's scheduled phase.
        let presentationSlot: Double
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

    deinit {
        interpolationLink?.invalidate()
        frames.setActiveMultiplier(nil)
        NotificationCenter.default.removeObserver(self)
    }

    /// The refresh rate this view follows. window.screen can be nil for a moment while the
    /// window moves or is re-created; both the display link and the interpolation
    /// configuration must resolve the same way, or they disagree on every tick. That
    /// disagreement reset the interpolation session at the display rate: generated pair
    /// history, warm-up and the presentation epoch were cleared while frames kept presenting,
    /// so the caption could stay on a preparation label through steady output.
    private var reportedDisplayCap: Float {
        let reported = window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return Float(reported > 0 ? reported : 60)
    }

    /// A weak target avoids the CADisplayLink -> view retain cycle. NSView's link follows
    /// the actual display across window moves and stops callbacks while hidden.
    func configureInterpolation() {
        let mode = settings.frameInterpolation
        let enabled = settings.enhancementEnabled && mode != .off && FrameInterpolatorSupport.isSupported(mode)
        // Keep the latest adjacent-source reference available; content-rate monitoring
        // is owned by LatestVideoFrame and does not gate renderer admission.
        frames.setInterpolationHistoryEnabled(enabled)
        let forceChanged = settings.forceFrameInterpolation != previousInterpolationForce
        let skipDuplicatesChanged = settings.skipsExactDuplicateInterpolation != previousSkipDuplicates
        let modeChanged = mode != previousMode || enabled != previousInterpolationEnabled
        if modeChanged || forceChanged || skipDuplicatesChanged {
            let failureCooldown = FrameInterpolationPolicy.preserveFailureCooldown(
                // A Follow/dedup-only reset retains an active GPU failure guard just like
                // a force-only reset; engine/mode changes keep the existing session reset.
                forceChanged: forceChanged || skipDuplicatesChanged,
                modeChanged: modeChanged,
                failureActive: cooldownReason != nil, until: cooldownUntil, now: CACurrentMediaTime())
            let failureReason = failureCooldown > 0 ? cooldownReason : nil
            frames.setInterpolationCost(seconds: 0, budget: 0)
            frames.setInterpolationWorkingSize(nil)
            // The published step described the old engine. An engine that declares a narrower
            // set (flow 2x/3x to a VideoToolbox 2x tier) must not keep showing the wider step
            // until the next pair happens to run, which may never happen under cooldown.
            frames.setActiveMultiplier(nil)
            // The old engine's generated presentations say nothing about the new one: nothing
            // generated has reached the display for this configuration yet.
            frames.clearGeneratedPresentationEvidence()
            adaptiveLongEdge = nil; interpolationDimensions = nil
            presentationEpoch &+= 1; presentedMidpoint = nil
            lastUniqueSource = nil; lastGeneratedPresentationTime = 0
            queuedFrames.removeAll(); generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll(); generationBatchGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
            cooldownUntil = failureCooldown; cooldownReason = failureReason; lastSourceSequence = nil
            scheduledSourceUntil = 0; awaitingSourcePresentation = nil
            comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
            previousMode = mode; previousInterpolationEnabled = enabled
            previousInterpolationForce = settings.forceFrameInterpolation
            previousSkipDuplicates = settings.skipsExactDuplicateInterpolation
            if skipDuplicatesChanged {
                // A Follow/dedup transition must not pair against a reference collected
                // under the previous duplicate policy.
                frames.setInterpolationHistoryEnabled(false)
                frames.setInterpolationHistoryEnabled(enabled)
            }
            lastStrictCheck = nil
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
            let cap = reportedDisplayCap
            if cap != configuredDisplayCap {
                interpolationLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, cap), maximum: cap, preferred: cap)
                configuredDisplayCap = cap
            }
        } else {
            queuedFrames.removeAll(); interpolationLink?.invalidate(); interpolationLink = nil; linkProxy = nil
            frames.setActiveMultiplier(nil)
            lastUniqueSource = nil; presentedMidpoint = nil
            scheduledSourceUntil = 0; awaitingSourcePresentation = nil
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
        let currentCap = reportedDisplayCap
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

    private func estimatedCost(_ values: [Double]) -> Double? {
        admissionCost(values) ?? p95(values)
    }

    private func estimatedPairCost(phases: [Double]) -> Double? {
        guard !phases.isEmpty,
              let generation = estimatedCost(generationBatchCosts),
              let source = estimatedCost(nativeCosts) else { return nil }
        let subsequent = phases.count > 1 ? estimatedCost(generatedPresentationCosts) : nil
        return FrameInterpolationPolicy.pairCost(generationBatch: generation,
            subsequentPresentation: subsequent, sourceEndpoint: source,
            generatedPhaseCount: phases.count)
    }

    /// Publishes the caption the current evidence supports. Evidence is a generated frame that
    /// reached the display inside the activity window for this stream epoch, so the engine is
    /// running and the caption must say so; only when no such frame exists does the caller's
    /// preparation reason describe the state. The frame store also refuses a running claim older
    /// than a stated reason, so a late success cannot erase a GPU error or a fallback reason.
    private func publishCaption(preparing: String) {
        guard let evidence = frames.recentGeneratedPresentationEvidence() else {
            frames.setInterpolationState(preparing)
            return
        }
        frames.publishInterpolationRunning(forced: settings.forceFrameInterpolation, evidence: evidence)
    }

    /// Adopts an input stream this view has not seen before. Everything the previous stream
    /// scheduled is invalid: its queued frames, its pair and its readout, because the new stream
    /// has not presented anything yet.
    private func adoptSourceStreamEpoch(_ streamEpoch: UInt64) {
        sourceStreamEpoch = streamEpoch; presentationEpoch &+= 1
        adaptiveLongEdge = nil; interpolationDimensions = nil
        // A blank registration belongs to the input that was replaced: its next confirm, failure or
        // timeout must not rebuild the layer the new stream is drawing into.
        clearBlankTracking()
        queuedFrames.removeAll(); presentedMidpoint = nil; lastSourceSequence = nil
        lastUniqueSource = nil; lastGeneratedPresentationTime = 0
        frames.setActiveMultiplier(nil)
        // Evidence belongs to the stream it was recorded under. The new stream has presented
        // nothing yet, so a late callback from the old one cannot claim it is running.
        frames.clearGeneratedPresentationEvidence()
        generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll(); generationBatchGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll(); cooldownUntil = 0; cooldownReason = nil
        scheduledSourceUntil = 0; awaitingSourcePresentation = nil
        comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
        lastStrictCheck = nil
    }

    private func recordComfortablePresentedPair(slot: Double) {
        guard slot.isFinite, slot > 0, adaptiveLongEdge != nil,
              let midpointCost = p95(generationBatchCosts), midpointCost <= slot * 0.55 else {
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
                generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll(); generationBatchGPUCosts.removeAll(); calibrationWarmupsRemaining = 2
            }
        }
    }
    private func resetInterpolationForDisplay() {
        adaptiveLongEdge = nil; interpolationDimensions = nil
        presentationEpoch &+= 1; presentedMidpoint = nil
        // The step belongs to the pair that published it. A display change resets the cadence
        // window and the cost history, so leaving the last step in place would let the panel
        // name a multiplier from a display this preview no longer draws into.
        frames.setActiveMultiplier(nil)
        frames.clearGeneratedPresentationEvidence()
        lastUniqueSource = nil; lastGeneratedPresentationTime = 0
        scheduledSourceUntil = 0; awaitingSourcePresentation = nil
        queuedFrames.removeAll(); generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll(); generationBatchGPUCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
        comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
        lastStrictCheck = nil
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
        frames.setActiveMultiplier(nil)
        // The new output size is a new render configuration: the previous one's presentations
        // cannot vouch for it.
        frames.clearGeneratedPresentationEvidence()
        presentedMidpoint = nil
        // Drawables encoded for the old size belong to an invalidated schedule: their
        // late callbacks must not clear the queue or the pair a new size publishes.
        presentationEpoch &+= 1
        // Output-size changes alter midpoint cost; a rung blocked at one size may fit at another.
        blockedRaiseTarget = nil; comfortableMidpoints = 0
        forceDraw = true
        requestRender()
    }

    /// Called on the main thread after a draw finishes: only ask for another draw when the
    /// newest frame or the current settings actually differ from what was submitted.
    private func requestRenderIfStateChanged() {
        // A source switch still owes a blank draw; nothing else would ask for one while the
        // new source has no frame.
        if frames.isBlankRequestPending { requestRender(); return }
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

    /// Strict evidence controls skipping; tolerant input estimates never drop a picture.
    private func duplicateResult(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64) -> Bool {
        if let last = lastStrictCheck, last.sequence == sequence,
           last.previousSequence == previousSequence, last.streamEpoch == streamEpoch {
            return last.result
        }
        let result = VideoFrameDuplicateDetector.areIdentical(previous, current)
        lastStrictCheck = (sequence, previousSequence, streamEpoch, result)
        return result
    }

    /// Convenience for the dedup fast path, which only has the newest sequence number and
    /// compares against the frame the capture stream delivered immediately before it.
    private func isDuplicatePair(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, streamEpoch: UInt64) -> Bool {
        guard settings.skipsExactDuplicateInterpolation else { return false }
        return duplicateResult(previous: previous, current: current, sequence: sequence,
                               previousSequence: sequence &- 1, streamEpoch: streamEpoch)
    }

    private func isDuplicatePair(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 sequence: UInt64, previousSequence: UInt64, streamEpoch: UInt64) -> Bool {
        guard settings.skipsExactDuplicateInterpolation else { return false }
        return duplicateResult(previous: previous, current: current, sequence: sequence,
                               previousSequence: previousSequence, streamEpoch: streamEpoch)
    }

    private func interpolationPair(current: CVPixelBuffer, currentPTS: CMTime,
                                   sequence: UInt64, streamEpoch: UInt64, signalFPS: Double,
                                   currentIsDuplicate: Bool,
                                   prefersAdjacentInputPair: Bool = false) -> InterpolationPair? {
        let previousBuffer: CVPixelBuffer
        let previousSequence: UInt64
        let previousPTS: CMTime
        if settings.skipsExactDuplicateInterpolation {
            if prefersAdjacentInputPair {
                guard !currentIsDuplicate,
                      let adjacent = frames.interpolationPair(sequence: sequence) else { return nil }
                // The raw adjacent comparison is the strict skip decision for this branch;
                // the previous rendered image may be several captures behind.
                previousBuffer = adjacent.0
                previousSequence = adjacent.1
                previousPTS = adjacent.2
            } else {
                guard !currentIsDuplicate, let previous = lastUniqueSource,
                      previous.streamEpoch == streamEpoch, previous.sequence < sequence else { return nil }
                previousBuffer = previous.buffer
                previousSequence = previous.sequence
                previousPTS = previous.pts
            }
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
            frames.setActiveMultiplier(nil)
            frames.setInterpolationState("呈现中断，重建预览")
            onPresentationRecovery?()
            return
        }
        // A blank that was submitted but never reported as presented may still be showing the
        // previous picture. Re-arm it before anything else so this draw or the next one retries.
        if retryLostBlankIfNeeded() { return }
        // A source switch clears the mailbox so the previous source's picture cannot be
        // mistaken for the new one. Blanking the drawable is what actually removes it: an
        // early return left the stale frame visible while the waiting mask said otherwise.
        if frames.isBlankRequestPending {
            // The switch also starts a new input stream. Adopt it here, before the return below,
            // or the previous source's queued pair, readout and cooldown would stay in front of
            // the new source's first frame.
            let blankEpoch = frames.streamGeneration()
            if blankEpoch != sourceStreamEpoch { adoptSourceStreamEpoch(blankEpoch) }
            guard let drawable = currentDrawable, let command = commands.makeCommandBuffer() else {
                // No drawable right now: keep the request and retry on the next render.
                forceDraw = true
                scheduleBlankRetry()
                return
            }
            // The encoder is what can fail here. The request is taken only once the command can
            // really carry the clear, so a failed encoder does not consume it as if the drawable
            // had been cleared.
            guard let encoder = command.makeRenderCommandEncoder(
                descriptor: Self.blankRenderPass(for: drawable, clearColor: clearColor)) else {
                forceDraw = true
                scheduleBlankRetry()
                return
            }
            if let requestedEpoch = frames.consumeBlankRequest() {
                presentBlankFrame(drawable, command: command, encoder: encoder, epoch: requestedEpoch)
                return
            }
            // A frame for the current stream arrived first and supersedes the blank. The empty
            // command is dropped and that frame is drawn by the path below.
            encoder.endEncoding()
        }
        guard let initial = frames.latestSnapshot() else { frames.setPreviewState("no-input"); return }
        var (buffer, sequence, receivedAt) = (initial.buffer, initial.sequence, initial.receivedAt)
        var sourcePTS = initial.pts
        var sourceIsUniqueContent = true
        var prefersAdjacentInputPair = false
        // Cleared when this frame's first-copy timing is unknown; it may still
        // present natively, but must not become the next pair's timing reference.
        var uniqueReferenceEligible = true
        let streamEpoch = initial.streamEpoch
        if streamEpoch != sourceStreamEpoch { adoptSourceStreamEpoch(streamEpoch) }
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
        var activePairPhases: [Double] = []
        var activePresentationSlot = 0.0
        var queuedImage: CIImage?
        var consumedQueueHead = false
        if let queued = queuedFrames.first {
            if !Self.timingCompatible(queued.settings, settings) || queued.size != size || queued.aspect != aspectMode {
                queuedFrames.removeAll() // A resize or engine change invalidates every queued frame.
                // The queued pair and its drawables belong to the previous configuration;
                // advance the generation so their late callbacks cannot clear the new one.
                presentationEpoch &+= 1
                comfortableMidpoints = 0
                // Preserve a live GPU-error guard; otherwise this is only a
                // settings/resize cooldown, not a newly failed GPU command.
                if cooldownReason == nil {
                    cooldownUntil = now + FrameInterpolationPolicy.overloadCooldownSeconds
                    frames.setActiveMultiplier(nil)
                }
                frames.clearGeneratedPresentationEvidence()
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
                endpointPresentation = max(queued.presentationTime, lastPresentationTime + queued.presentationSlot, now + 0.001)
                (buffer, sequence, receivedAt) = (queued.buffer, queued.sequence, queued.receivedAt)
                sourcePTS = queued.sourcePTS
                sourceIsUniqueContent = queued.isUniqueContent
                activePairPeriod = queued.sourcePeriod
                activePairPhases = queued.phases
                activePresentationSlot = queued.presentationSlot
                consumedQueueHead = true
                // An already generated frame is presented as-is; it must not be regenerated.
                if queued.isGenerated { queuedImage = queued.image; skipInterpolation = true }
            }
        }
        // Ordinary source fallbacks leave recent successful activity intact. The
        // frame store expires it after the statistics window; lifecycle resets clear it.
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
                frames.setActiveMultiplier(nil)
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
            queuedFrames.removeAll(); frames.setActiveMultiplier(nil)
            forceDraw = true; inFlight.signal(); requestRender(); return
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
        var generatedBatch = false
        var presentationTime = endpointPresentation
        var sourceImage = queuedImage ?? CIImage(cvPixelBuffer: buffer)
        let mediaFPS = frames.sourceFrameRate()
        let sourceFPS = FrameInterpolationPolicy.nominalInputFPS(mediaFPS ?? 0) ?? 0
        let interpolationRequested = settings.enhancementEnabled && settings.frameInterpolation != .off
        let displayFPS = min(observedDisplayFPS, Double(window.screen?.maximumFramesPerSecond ?? 60))
        let inputCadenceSnapshot = frames.inputContentCadenceSnapshot()
        let inputCadenceReady = inputCadenceSnapshot?.fps != nil
        let inputCadenceEvidenceMatchesFrame: Bool = {
            guard let inputCadenceSnapshot,
                  inputCadenceSnapshot.streamEpoch == streamEpoch,
                  let measuredSequence = inputCadenceSnapshot.sequence,
                  measuredSequence <= sequence,
                  inputCadenceSnapshot.fps != nil else { return false }
            return true
        }()
        // Recover exact source identities even while a multi-phase pair drains.
        // A queued endpoint already carries the pair's first-copy PTS and uniqueness.
        // Reclassifying it against a newer mailbox loses that reference when inference
        // takes longer than a capture tick, and the next pair uses an older picture.
        if queuedImage == nil && endpointPresentation == nil {
            let cadencePair = frames.interpolationPair(sequence: sequence)
            let isExactDuplicate = cadencePair.flatMap {
                isDuplicatePair(previous: $0.0, current: buffer, sequence: sequence,
                                previousSequence: $0.1, streamEpoch: streamEpoch) ? true : false
            }
            prefersAdjacentInputPair = settings.skipsExactDuplicateInterpolation &&
                FrameInterpolationPolicy.prefersAdjacentInputPair(
                    inputFPS: inputCadenceSnapshot?.fps,
                    signalFPS: sourceFPS,
                    evidenceFreshForCurrentEpoch: inputCadenceEvidenceMatchesFrame,
                    adjacentFramesAreDifferent: isExactDuplicate == false)
            if prefersAdjacentInputPair {
                // In this branch, strict equality of the raw adjacent captures decides
                // whether the current source is a repeat. Historical rendered pixels can
                // match again after motion and must not replace the adjacent PTS pair.
                sourceIsUniqueContent = isExactDuplicate == false
            } else {
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
        }
        // The input-side monitor is only a warm-up hint. Pair period and display cadence
        // decide the actual step and deadline for this frame; a rolling estimate cannot veto it.
        // An exact-copy source (30 Hz content in a 60 Hz signal) needs no new presentation:
        // the display already holds the identical previous drawable. Skipping the whole
        // spatial pipeline here saves GPU for midpoint quality on the unique frames.
        if interpolationRequested, !sourceIsUniqueContent, !forced, !skipInterpolation, endpointPresentation == nil,
           queuedFrames.isEmpty, CACurrentMediaTime() >= cooldownUntil,
           let previous = lastUniqueSource, previous.streamEpoch == streamEpoch,
           isDuplicatePair(previous: previous.buffer, current: buffer, sequence: sequence,
                           previousSequence: previous.sequence, streamEpoch: streamEpoch) {
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
        let candidatePair = interpolationRequested && endpointPresentation == nil && !skipInterpolation
            ? interpolationPair(current: buffer, currentPTS: sourcePTS, sequence: sequence,
                streamEpoch: streamEpoch, signalFPS: sourceFPS, currentIsDuplicate: !sourceIsUniqueContent,
                prefersAdjacentInputPair: prefersAdjacentInputPair)
            : nil
        if interpolationRequested {
            if !FrameInterpolatorSupport.isSupported(settings.frameInterpolation) { frames.setInterpolationState("插帧不可用") }
            else if CACurrentMediaTime() < cooldownUntil { frames.setInterpolationState(cooldownReason ?? (settings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率")) }
            else if displayFPS <= 0 { frames.setInterpolationState("等待显示器刷新率") }
            else if let pair = candidatePair,
                    FrameInterpolationPolicy.multiplierFittingPair(2, pairPeriod: pair.period, displayFPS: displayFPS) < 2 {
                frames.setInterpolationState("显示器刷新率不足，使用原始帧率")
            }
            else if let pair = candidatePair,
                    // The measured period decides whether a midpoint fits at all, not the cadence
                    // estimate that picked the step: a duplicate-heavy 60 Hz signal can look like
                    // 45 FPS content while its pairs are genuinely 33 ms apart and do hold two
                    // presentations. A period with room for fewer than two has none, so the source
                    // is presented natively rather than queued past its deadline. This is also what
                    // keeps 60 FPS content on a 60 Hz panel from stalling the preview.
                    FrameInterpolationPolicy.multiplierFittingPair(2, pairPeriod: pair.period, displayFPS: displayFPS) >= 2,
                    let dimensions = FrameInterpolationPolicy.targetDimensions(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), mode: settings.frameInterpolation, inputFPS: settings.skipsExactDuplicateInterpolation ? 1 / pair.period : sourceFPS, maximumLongEdge: adaptiveLongEdge),
                    !isDuplicatePair(previous: pair.previousBuffer, current: buffer, sequence: sequence,
                        previousSequence: pair.previousSequence, streamEpoch: streamEpoch),
                    let interpolator = interpolationEngine {
                #if MONIVIEW_PREVIEW_TESTING
                trace("PAIR seq=\(sequence) previous=\(pair.previousSequence) ticks=\(pair.period * sourceFPS) pairFPS=\(1 / pair.period)")
                #endif
                if interpolationDimensions != dimensions {
                    interpolationDimensions = dimensions
                    generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll(); generationBatchGPUCosts.removeAll(); calibrationWarmupsRemaining = 2
                }
                interpolator.prepare(width: dimensions.width, height: dimensions.height)
                if !interpolator.isReady {
                    publishCaption(preparing: "插帧准备中")
                }
                if interpolator.isReady {
                    // Exact-dedup mode has a real unique-endpoint PTS interval for this pair.
                    // Use it to select 2x/3x directly; render-sampled repeat windows can miss
                    // duplicates while the phase queue drains and bias a 20 FPS source to 30.
                    // When dedup is disabled, preserve the capture signal's measured cadence.
                    let stepContentFPS = settings.skipsExactDuplicateInterpolation
                        ? 1 / pair.period : sourceFPS
                    let requested = FrameInterpolationPolicy.multiplier(
                        contentFPS: stepContentFPS, targetFPS: 60, displayFPS: displayFPS)
                    // Never ask an engine for a phase it cannot supply: the VideoToolbox
                    // processor only produces the midpoint, so it stays on 2x and the flow
                    // engine is the tier that can fill slower content up to the panel rate.
                    let engineMultipliers = interpolator.supportedMultipliers
                    // Prefer the requested step, otherwise the lowest the engine declares.
                    // Taking the first element assumed the arrays are ordered, so declaring a
                    // wider set for an engine would silently change what a fallback means.
                    let stated = engineMultipliers.contains(requested)
                        ? requested
                        : (engineMultipliers.min() ?? 2)
                    // The guard above proved this pair's period holds at least two presentations.
                    // Cap the step to what it actually holds: a 60 Hz pair read as 20 FPS content
                    // asks for three where only two have a slot, and the extra one would push the
                    // endpoint past its deadline.
                    let multiplier = FrameInterpolationPolicy.multiplierFittingPair(
                        stated, pairPeriod: pair.period, displayFPS: displayFPS)
                    let phases = FrameInterpolationPolicy.midpointPhases(multiplier: multiplier)
                    let phaseFractions = phases.map { Double($0) }
                    activePairPhases = phaseFractions
                    let slot = pair.period / Double(phases.count + 1)
                    activePairPeriod = pair.period
                    activePresentationSlot = pair.period * (phaseFractions.first ?? 0)
                    // Admission uses the sample-gated estimate. The first generation sample
                    // covers the whole flow batch; a second history holds cached-phase draws.
                    let generationCost = admissionCost(generationBatchCosts)
                    let subsequentCost = phaseFractions.count > 1 ? admissionCost(generatedPresentationCosts) : nil
                    let sourceCost = admissionCost(nativeCosts)
                    let hasCompleteCosts = generationCost != nil && sourceCost != nil
                        && (phaseFractions.count == 1 || subsequentCost != nil)
                    let pairFits = hasCompleteCosts && FrameInterpolationPolicy.costsFit(
                        generationBatch: generationCost ?? 0,
                        subsequentPresentation: subsequentCost,
                        sourceEndpoint: sourceCost ?? 0,
                        phases: phaseFractions, pairPeriod: pair.period)
                    let displaySlot = displayFPS > 0 ? 1 / displayFPS : slot
                    // VT inference has completion jitter outside the GPU timestamps. Give
                    // its expensive tier one refresh of lead; keep the cheap flow path tight.
                    let lead = settings.frameInterpolation == .quality && pair.period >= 0.025
                        ? displaySlot : slot * 0.1
                    let earliest = CACurrentMediaTime() + (generationCost ?? 0.002) + lead
                    let nextPairSlot = scheduledSourceUntil + slot
                    let target = nextPairSlot >= earliest ? nextPairSlot :
                        displayTargetTime + max(0, ceil((earliest - displayTargetTime) / displaySlot)) * displaySlot
                    let deadlineFits = displayTargetTime > 0 && target <= CACurrentMediaTime() + 1.5 * pair.period
                    // First collect a stable generation-batch sample. Once it exists, allow a
                    // deadline-safe pair to seed whichever endpoint/presentation histories are
                    // still missing. This avoids estimating those queue stages from the batch.
                    let calibrating = generationCost == nil
                    let mayGenerate: Bool
                    if hasCompleteCosts {
                        mayGenerate = FrameInterpolationPolicy.allowsMeasuredPair(
                            generationBatch: generationCost ?? 0,
                            subsequentPresentation: subsequentCost,
                            sourceEndpoint: sourceCost ?? 0,
                            phases: phaseFractions, pairPeriod: pair.period,
                            force: settings.forceFrameInterpolation, deadlineFits: deadlineFits)
                    } else {
                        mayGenerate = !calibrating && deadlineFits
                    }
                    #if MONIVIEW_PREVIEW_TESTING
                    trace("PAIR-STEP seq=\(sequence) skipDuplicates=\(settings.skipsExactDuplicateInterpolation) stepFPS=\(stepContentFPS) requested=\(requested) fitted=\(multiplier) period=\(pair.period) phases=\(phaseFractions)")
                    #endif
                    // Calibration still needs a real deadline-safe pair; warm-up is not
                    // permission to encode a phase that has already missed its display slot.
                    if deadlineFits && (calibrating || mayGenerate) {
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
                            generatedBatch = true
                            #if MONIVIEW_PREVIEW_TESTING
                            trace("PAIR-PHASES seq=\(sequence) produced=\(producedImages.count)/\(phases.count) requested=\(requested) phases=\(Array(phaseFractions.prefix(producedImages.count)))")
                            #endif
                            if calibrating {
                                calibratedMidpoint = true
                            } else {
                                let producedCount = producedImages.count
                                let producedPhases = Array(phaseFractions.prefix(producedCount))
                                activePairPhases = producedPhases
                                let firstPhase = producedPhases[0]
                                activePresentationSlot = pair.period * firstPhase
                                generatedMidpoint = true; sourceImage = first
                                presentationTime = target
                                if producedImages.count > 1 {
                                    for offset in 1..<producedImages.count {
                                        let phaseInterval = producedPhases[offset] - producedPhases[offset - 1]
                                        queuedFrames.append(QueuedFrame(image: producedImages[offset], buffer: buffer,
                                            receivedAt: receivedAt, sequence: sequence, settings: settings,
                                            size: size, aspect: aspectMode,
                                            presentationTime: target + pair.period * (producedPhases[offset] - firstPhase),
                                            sourcePeriod: pair.period, sourcePTS: sourcePTS,
                                            isUniqueContent: sourceIsUniqueContent, isGenerated: true,
                                            phases: producedPhases,
                                            presentationSlot: pair.period * phaseInterval))
                                    }
                                }
                                let endpointOffset = pair.period * (1 - firstPhase)
                                let endpointSlot = pair.period * (1 - producedPhases[producedPhases.count - 1])
                                queuedFrames.append(QueuedFrame(image: CIImage(cvPixelBuffer: buffer), buffer: buffer,
                                    receivedAt: receivedAt, sequence: sequence, settings: settings,
                                    size: size, aspect: aspectMode,
                                    presentationTime: target + endpointOffset,
                                    sourcePeriod: pair.period, sourcePTS: sourcePTS,
                                    isUniqueContent: sourceIsUniqueContent, isGenerated: false,
                                    phases: producedPhases, presentationSlot: endpointSlot))
                                // Publish only after generation returned at least one phase and
                                // the complete bounded phase/endpoint queue was constructed.
                                frames.setActiveMultiplier(Double(producedCount + 1), inputFPS: stepContentFPS, streamEpoch: streamEpoch)
                            }
                        }
                    } else if !settings.forceFrameInterpolation && hasCompleteCosts && !pairFits {
                        cooldownReason = nil
                        cooldownUntil = CACurrentMediaTime() + FrameInterpolationPolicy.overloadCooldownSeconds
                        // Recent success expires naturally while overload blocks new pairs.
                        // Clear both histories: a stale native P95 otherwise keeps the next
                        // pair's target late, which rejects pairs and never refreshes it.
                        generationBatchCosts.removeAll(); generatedPresentationCosts.removeAll()
                        generationBatchGPUCosts.removeAll(); nativeCosts.removeAll(); calibrationWarmupsRemaining = 2
                        frames.setInterpolationState(settings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率")
                    } else if !deadlineFits {
                        // Force cannot make a late pair present on time. Do not leave
                        // a previous successful pair's running label on native fallback.
                        frames.setInterpolationState("呈现节奏调整")
                    }
                }
            } else if !inputCadenceReady {
                publishCaption(preparing: "插帧准备中")
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
        let targetLongEdge = settings.upscaleTarget.processingLongEdge(screenLongEdge: screenPixels,
            sourceLongEdge: sourceLongEdge, visibleLongEdge: visibleLongEdge, lowLatency: settings.lowLatency)
        // Interpolation overload must not silently reduce source-frame spatial detail.
        // Keep the selected target (and the existing low-latency viewport bound) stable.
        // Generated frames use their inference size plus a final resize. Source frames
        // retain the selected spatial engine and target even when a pair exceeds budget.
        let smoothMidpoint = generatedMidpoint
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
        let period = activePresentationSlot > 0 ? activePresentationSlot : (sourceFPS > 0 ? 0.5 / sourceFPS : 0)
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
                // A late callback belongs to the generation that encoded it. An older
                // stream or presentation epoch must not clear the queue, the schedule or
                // the published pair after a newer generation has already set them.
                let generationIsCurrent = self.presentationEpoch == epoch && self.sourceStreamEpoch == streamEpoch
                guard time > 0 else {
                    if generationIsCurrent, wasGenerated || wasEndpoint {
                        self.comfortableMidpoints = 0
                        self.queuedFrames.removeAll(); self.presentedMidpoint = nil
                        self.scheduledSourceUntil = 0; self.awaitingSourcePresentation = nil
                        self.frames.setActiveMultiplier(nil)
                    }
                    self.forceDraw = true; self.requestRenderIfStateChanged(); return
                }
                // Presentation counts exclude failed/retired-stream drawables and
                // settings/resize redraws of the same captured frame.
                if wasGenerated {
                    // The caption is only evidence when this presentation was accepted for the
                    // current stream and this render generation. A callback from a superseded
                    // source or engine must not label the new one as running, and live settings
                    // still veto it so turning interpolation off keeps its own caption.
                    let accepted = presentedFrameStore.markGenerated(streamEpoch: streamEpoch, presentedTime: time)
                    if accepted, generationIsCurrent {
                        presentedFrameStore.recordGeneratedPresentationEvidence(streamEpoch: streamEpoch, at: time)
                        if self.settings.enhancementEnabled, self.settings.frameInterpolation != .off {
                            // This frame is the generated one, so its own presentation is the
                            // evidence.
                            presentedFrameStore.publishInterpolationRunning(
                                forced: self.settings.forceFrameInterpolation, evidence: time)
                        }
                    }
                }
                else { presentedFrameStore.markPresentedSource(sequence: presentedSequence, streamEpoch: streamEpoch, presentedTime: time) }
                #if MONIVIEW_PREVIEW_TESTING
                self.onPresentation?(presentedSequence, wasGenerated, time)
                if wasGenerated || wasEndpoint { self.trace("PRESENT seq=\(presentedSequence) mid=\(wasGenerated) deadlineError=\((time - (presentationTime ?? time))*1000)ms") }
                #endif
                if generationIsCurrent, self.awaitingSourcePresentation?.sequence == presentedSequence, !wasGenerated { self.awaitingSourcePresentation = nil }
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
                        //
                        // The evidence is the midpoint's presentation, not this endpoint's: the
                        // endpoint is the source frame, and a pair that a fallback reason sent
                        // native while its already-scheduled endpoint presents later must keep
                        // that reason instead of announcing running again.
                        if self.settings.enhancementEnabled, self.settings.frameInterpolation != .off {
                            presentedFrameStore.publishRunningForPresentedPair(
                                forced: self.settings.forceFrameInterpolation, midpointPresentedAt: midpoint.time)
                        }
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
        let wasGenerationBatch = generatedBatch
        let wasCalibration = calibratedMidpoint
        let phasesForCost = activePairPhases
        let costPairPeriod = activePairPeriod
        // Native fallbacks must not overwrite the content-pair budget with the faster
        // capture slot (30-in-60 otherwise oscillates between 30 and 15 ms budgets).
        let measuredSlot = activePresentationSlot > 0 ? activePresentationSlot : (sourceFPS > 0 ? 0.5 / sourceFPS : 0)
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
                // A failed GPU command invalidates the pair it carried. Colour and other
                // picture edits change settings without restarting interpolation, so this
                // cleanup cannot sit behind the full settings comparison that guards the cost
                // bookkeeping below; otherwise a failure after an edit keeps the stale step
                // (and a queued 3x image) until the readout expires.
                if !succeeded, self.presentationEpoch == epoch, self.sourceStreamEpoch == streamEpoch,
                   !(interpolationRequested && self.settings == expectedSettings) {
                    if self.settings.enhancementEnabled, self.settings.frameInterpolation != .off {
                        self.cooldownReason = "GPU错误，保留原始画面"
                        self.cooldownUntil = CACurrentMediaTime() + FrameInterpolationPolicy.overloadCooldownSeconds
                    }
                    self.queuedFrames.removeAll()
                    self.scheduledSourceUntil = 0; self.awaitingSourcePresentation = nil
                    self.presentedMidpoint = nil
                    self.frames.setActiveMultiplier(nil)
                    self.forceDraw = true
                }
                if self.presentationEpoch == epoch && self.settings == expectedSettings && interpolationRequested {
                    // Model cold-start commands are measured and shown, but two hidden
                    // native-only warmups are separate from the steady-state P95 budget.
                    let warming = wasCalibration && self.calibrationWarmupsRemaining > 0
                    if succeeded {
                        if wasGenerationBatch || wasCalibration, let dimensions = measuredDimensions {
                            frameStore.setInterpolationWorkingSize("\(dimensions.width)×\(dimensions.height)")
                        }
                        if warming {
                            self.calibrationWarmupsRemaining -= 1
                            self.publishCaption(preparing: "插帧准备中")
                        } else if wasGenerationBatch {
                            self.generationBatchCosts.append(cost); self.generationBatchCosts = Array(self.generationBatchCosts.suffix(32))
                            self.generationBatchGPUCosts.append(gpuMS); self.generationBatchGPUCosts = Array(self.generationBatchGPUCosts.suffix(32))
                            if let gpuP95 = self.p95(self.generationBatchGPUCosts) { frameStore.setInterpolationGPUCost(milliseconds: gpuP95) }
                        } else if wasMidpoint {
                            self.generatedPresentationCosts.append(cost); self.generatedPresentationCosts = Array(self.generatedPresentationCosts.suffix(32))
                        } else {
                            if wasEndpoint || shouldMeasure {
                                self.nativeCosts.append(cost); self.nativeCosts = Array(self.nativeCosts.suffix(32))
                            }
                        }
                        if let pairCost = self.estimatedPairCost(phases: phasesForCost), costPairPeriod > 0 {
                            frameStore.setInterpolationCost(seconds: pairCost,
                                budget: costPairPeriod * FrameInterpolationPolicy.pairBudgetFraction)
                        }
                    }
                    // Wait for enough steady-state samples before judging cost: the commands
                    // right after a switch carry warm-up and must not trigger cooldown.
                    let measuredCost = wasGenerationBatch
                        ? self.admissionCost(self.generationBatchCosts)
                        : (wasMidpoint ? self.admissionCost(self.generatedPresentationCosts) : self.admissionCost(self.nativeCosts))
                    let generationForBudget = self.admissionCost(self.generationBatchCosts)
                    let presentationForBudget = phasesForCost.count > 1
                        ? self.admissionCost(self.generatedPresentationCosts) : nil
                    let sourceForBudget = self.admissionCost(self.nativeCosts)
                    let hasCompleteBudget = !phasesForCost.isEmpty && generationForBudget != nil && sourceForBudget != nil
                        && (phasesForCost.count <= 1 || presentationForBudget != nil)
                    var pairOverBudget = hasCompleteBudget && !FrameInterpolationPolicy.costsFit(
                        generationBatch: generationForBudget ?? 0,
                        subsequentPresentation: presentationForBudget,
                        sourceEndpoint: sourceForBudget ?? 0,
                        phases: phasesForCost, pairPeriod: costPairPeriod)
                    #if MONIVIEW_PREVIEW_TESTING
                    if self.injectInterpolationOverBudget && !warming && (wasGenerationBatch || wasMidpoint || wasEndpoint) {
                        pairOverBudget = true
                        self.injectedOverBudgetCount += 1
                    }
                    #endif
                    let individualLimit = measuredSlot * (wasGenerationBatch
                        ? FrameInterpolationPolicy.midpointBudgetFraction : FrameInterpolationPolicy.budgetFraction)
                    // Force keeps trying but must still adapt successful, over-budget
                    // work. It cannot remove a GPU error or an actual display deadline.
                    if !succeeded || (!warming && (wasGenerationBatch || wasMidpoint || wasEndpoint) && measuredSlot > 0 && ((measuredCost ?? 0) > individualLimit || pairOverBudget)) {
                        // A successful midpoint already owns a fixed endpoint. Complete
                        // that pair even when its measured cost disables the NEXT pair.
                        // GPU errors invalidate the pair; age/epoch guards still apply.
                        self.cooldownReason = succeeded ? nil : "GPU错误，保留原始画面"
                        if !succeeded {
                            self.queuedFrames.removeAll()
                            self.scheduledSourceUntil = 0; self.awaitingSourcePresentation = nil
                            self.frames.setActiveMultiplier(nil)
                        }
                        // A successful but over-budget endpoint does not erase recent
                        // activity. Without another successful pair its TTL expires.
                        // High/Medium keep their advertised inference resolution and source
                        // enhancement target. Only Low may lower inference resolution.
                        let lower = expectedSettings.frameInterpolation == .efficient
                            ? measuredDimensions.flatMap { FrameInterpolationPolicy.reducedLongEdge(after: max($0.width, $0.height)) }
                            : nil
                        let forcedContinuation = succeeded && expectedSettings.forceFrameInterpolation
                            && lower == nil
                        if succeeded, let lower {
                            self.adaptiveLongEdge = lower
                            self.cooldownUntil = CACurrentMediaTime() + 0.1
                        } else if forcedContinuation {
                            // Force keeps trying once all quality-preserving levers are spent.
                            // Retain measurements for deadline planning instead of repeatedly
                            // pausing two seconds and recalibrating successful commands.
                            self.cooldownUntil = 0
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
                        if !forcedContinuation {
                            self.generationBatchCosts.removeAll(); self.generatedPresentationCosts.removeAll(); self.nativeCosts.removeAll()
                            self.generationBatchGPUCosts.removeAll()
                            self.calibrationWarmupsRemaining = 2
                        }
                        self.comfortableMidpoints = 0
                        #if MONIVIEW_PREVIEW_TESTING
                        self.trace("COST fail seq=\(frameSequence) mid=\(wasMidpoint) calib=\(wasCalibration) endpoint=\(wasEndpoint) CPU=\(encodedCPUSeconds*1000) GPU=\(gpuMS)")
                        #endif
                        let overloadState = expectedSettings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率"
                        if forcedContinuation {
                            self.publishCaption(preparing: overloadState)
                        } else {
                            frameStore.setInterpolationState(self.cooldownReason ?? overloadState)
                        }
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

    /// The clearing pass for a blank draw. Building it beside the encoder creation keeps a
    /// failure there from consuming a request whose drawable was never cleared.
    private static func blankRenderPass(for drawable: CAMetalDrawable, clearColor: MTLClearColor) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        return pass
    }

    /// Clears the drawable, using the encoder the caller already created for it. Used while a
    /// source has not delivered its first frame, so the previous source's picture cannot stay on
    /// screen behind the waiting mask.
    private func presentBlankFrame(_ drawable: CAMetalDrawable, command: MTLCommandBuffer,
                                   encoder: MTLRenderCommandEncoder, epoch: UInt64) {
        encoder.endEncoding()
        // A failed command leaves whatever was on screen untouched, so the clear still has to
        // happen: re-arm the request and draw again.
        command.addCompletedHandler { [weak self] completed in
            guard completed.status != .completed else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.failBlankPresentation(epoch: epoch)
            }
        }
        command.present(drawable)
        // A lost presentation callback is a failure like any other: it is retried, and after a
        // second loss the layer is retired so SwiftUI builds a fresh one. An older generation's
        // callback cannot confirm or clear the new blank because the epoch must match.
        drawable.addPresentedHandler { [weak self] presented in
            #if MONIVIEW_PREVIEW_TESTING
            guard !(self?.suppressBlankPresentedCallbacks ?? false) else { return }
            #endif
            guard presented.presentedTime > 0 else { return }
            DispatchQueue.main.async { self?.confirmBlankPresentation(epoch: epoch) }
        }
        blankPresentationAttempts += 1
        let deadline = CACurrentMediaTime() + Self.blankPresentationDeadline
        blankPresentationInFlight = (epoch, deadline)
        scheduleBlankDeadline(epoch: epoch, deadline: deadline)
        command.commit()
        forceDraw = false
        frames.setPreviewState("no-input")
    }

    /// Wakes the renderer for the blank's own deadline. The display link only runs while
    /// interpolation is on, so a lost presentation callback must be able to trigger its retry
    /// without any input frame arriving.
    private func scheduleBlankDeadline(epoch: UInt64, deadline: Double) {
        let delay = max(0, deadline - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let inFlight = self.blankPresentationInFlight,
                  inFlight.epoch == epoch, CACurrentMediaTime() >= inFlight.deadline else { return }
            if self.retryLostBlankIfNeeded() { return }
            self.forceDraw = true
            self.requestRender()
        }
    }

    /// Clears the blank record once its own presentation callback arrives. Only the epoch that
    /// was submitted may do that, so a late callback from a superseded source cannot report a
    /// blank it did not present.
    private func confirmBlankPresentation(epoch: UInt64) {
        guard let inFlight = blankPresentationInFlight, inFlight.epoch == epoch else { return }
        clearBlankTracking()
    }

    /// Forgets the blank registration and its attempt count. Called when the registration belongs
    /// to an input that a newer stream replaced, so a stale confirm, failure or timeout cannot
    /// retire the layer the new stream is presenting into.
    private func clearBlankTracking() {
        blankPresentationInFlight = nil
        blankPresentationAttempts = 0
    }

    /// A clearing command that did not complete leaves the previous picture on screen. Only the
    /// generation that submitted it may reclaim the request, so an older switch's failure cannot
    /// touch the blank a newer one installed.
    private func failBlankPresentation(epoch: UInt64) {
        // A repeated GPU failure takes the same bounded path as a lost callback: retry, and after
        // the attempt limit retire the layer instead of resubmitting the same failing command.
        abandonBlankPresentation(epoch: epoch)
    }

    /// Ends the registration of a blank that could not be presented and schedules its retry.
    /// Returns true when the layer was retired instead, so the caller stops drawing into it.
    @discardableResult
    private func abandonBlankPresentation(epoch: UInt64) -> Bool {
        guard let inFlight = blankPresentationInFlight, inFlight.epoch == epoch else { return false }
        blankPresentationInFlight = nil
        // Only a blank that is still the current one may be retried: a newer stream, or a picture
        // that took the mailbox over, makes this registration obsolete and retrying it would
        // disturb a preview that already recovered.
        guard frames.isBlankStillNeeded(forEpoch: epoch) else {
            blankPresentationAttempts = 0
            return false
        }
        frames.rearmBlankRequest(epoch: epoch)
        forceDraw = true
        requestRender()
        guard blankPresentationAttempts >= Self.maximumBlankPresentationAttempts else { return false }
        blankPresentationAttempts = 0
        retiringForPresentationFailure = true
        comfortableMidpoints = 0
        interpolationLink?.invalidate(); queuedFrames.removeAll()
        frames.setActiveMultiplier(nil)
        frames.setInterpolationState("呈现中断，重建预览")
        onPresentationRecovery?()
        return true
    }

    /// Schedules one delayed retry for a blank that could not be submitted at all. Delaying it
    /// keeps a layer without a drawable from spinning on the main queue, while still retrying
    /// without waiting for a frame: a source that never delivers one is exactly the case this
    /// clearing exists for.
    private func scheduleBlankRetry() {
        guard !blankRetryScheduled else { return }
        blankRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.blankRetryScheduled = false
            self.forceDraw = true
            self.requestRender()
        }
    }

    /// Retries a blank whose presentation callback never arrived. The request is re-armed so the
    /// next draw clears again; when that keeps failing the layer is retired through the existing
    /// presentation-recovery path rather than left showing the previous picture. Returns true
    /// when the layer was retired, so the caller stops drawing into it.
    private func retryLostBlankIfNeeded() -> Bool {
        guard let blank = blankPresentationInFlight, CACurrentMediaTime() > blank.deadline else { return false }
        return abandonBlankPresentation(epoch: blank.epoch)
    }
}

/// CADisplayLink retains its target; this adapter keeps the preview's lifetime independent.
private final class InterpolationDisplayLinkProxy: NSObject {
    weak var view: CapturePreviewNSView?
    init(view: CapturePreviewNSView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.interpolationTick(link) }
}
