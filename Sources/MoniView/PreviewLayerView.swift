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

struct PreviewLayerView: NSViewRepresentable {
    @ObservedObject var capture: CaptureManager
    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView(frames: capture.frames)
        view.onPresentationRecovery = { [weak capture] in capture?.rebuildPreview() }
        return view
    }
    func updateNSView(_ view: CapturePreviewNSView, context: Context) {
        view.settings = capture.picture
        view.aspectMode = capture.aspectMode
        view.configureInterpolation()
        (view.layer as? CAMetalLayer)?.displaySyncEnabled = (capture.picture.enhancementEnabled && capture.picture.frameInterpolation != .off && FrameInterpolatorSupport.isSupported) || !capture.picture.lowLatency
        if capture.picture.upscaleMethod != .ai || !capture.picture.enhancementEnabled || capture.picture.upscaleTarget == .native { view.stopAIUpscaler() }
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
    private var calibrationWarmupsRemaining = 2
    private var adaptiveLongEdge: Int?
    private var interpolationDimensions: FrameInterpolationPolicy.Dimensions?
    /// Rolling unique/duplicate pair outcomes. A duplicated cadence (30 Hz content in a
    /// 60 Hz signal) needs half the midpoints, so the per-midpoint budget doubles.
    private var duplicatePairWindow: [Bool] = []
    private var lastDuplicateCheck: (sequence: UInt64, skipEnabled: Bool, result: Bool)?
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
    private var presentedMidpoint: (sequence: UInt64, time: Double)?
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
    }
    private var pendingSource: PendingSource?
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
        let enabled = settings.enhancementEnabled && mode != .off && FrameInterpolatorSupport.isSupported
        frames.setInterpolationHistoryEnabled(true) // content-rate detection also runs without interpolation
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
            pendingSource = nil; midpointCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
            cooldownUntil = failureCooldown; cooldownReason = failureReason; lastSourceSequence = nil; awaitingSourcePresentation = nil
            comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
            previousMode = mode; previousInterpolationEnabled = enabled
            previousInterpolationForce = settings.forceFrameInterpolation
            duplicatePairWindow.removeAll(); lastDuplicateCheck = nil
            if #available(macOS 26.0, *) { interpolator?.stop() }
        }
        if enabled {
            stopAIUpscaler() // Avoid two temporal/ML pipelines competing for the slot budget.
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
            pendingSource = nil; interpolationLink?.invalidate(); interpolationLink = nil; linkProxy = nil
            observedDisplayFPS = 0; displayTargetTime = 0; configuredDisplayCap = 0
            if #available(macOS 26.0, *) { interpolator?.stop() }
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
        if pendingSource != nil || !outstandingPresentations.isEmpty { requestRender() }
        else { requestRenderIfStateChanged() }
    }
    private func p95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
    private func resetInterpolationForDisplay() {
        adaptiveLongEdge = nil; interpolationDimensions = nil
        presentationEpoch &+= 1; presentedMidpoint = nil
        pendingSource = nil; midpointCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll()
        comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
        duplicatePairWindow.removeAll(); lastDuplicateCheck = nil
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
        pendingSource = nil
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
        if pendingSource != nil || forceDraw || key != lastSubmitted { requestRender() }
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

    /// Exact-duplicate pair check with one result per sequence. The full-pixel compare
    /// runs once even when both the presentation skip and the pair admission ask.
    private func isDuplicatePair(previous: CVPixelBuffer, current: CVPixelBuffer, sequence: UInt64, streamEpoch: UInt64) -> Bool {
        let skipEnabled = settings.skipsExactDuplicateInterpolation
        if let last = lastDuplicateCheck, last.sequence == sequence, last.skipEnabled == skipEnabled { return last.result }
        let result = skipEnabled && VideoFrameDuplicateDetector.areIdentical(previous, current)
        lastDuplicateCheck = (sequence, skipEnabled, result)
        duplicatePairWindow.append(result)
        duplicatePairWindow = Array(duplicatePairWindow.suffix(16))
        return result
    }

    /// Content duplicated into a faster signal (30 or 40 FPS in 60 Hz, or a card that
    /// occasionally repeats a frame) needs midpoints only for unique pairs. Scale the
    /// per-midpoint budget by the measured unique-pair rate; presentation timing still
    /// follows the real source cadence. Ratios above 0.75 are ordinary jitter, and the
    /// credit is capped so a pathological stream cannot claim an unbounded budget.
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
            interpolationLink?.invalidate(); pendingSource = nil
            frames.setInterpolationState("呈现中断，重建预览")
            onPresentationRecovery?()
            return
        }
        guard let initial = frames.latestSnapshot() else { frames.setPreviewState("no-input"); return }
        var (buffer, sequence, receivedAt) = (initial.buffer, initial.sequence, initial.receivedAt)
        let streamEpoch = initial.streamEpoch
        if streamEpoch != sourceStreamEpoch {
            sourceStreamEpoch = streamEpoch; presentationEpoch &+= 1
            adaptiveLongEdge = nil; interpolationDimensions = nil
            pendingSource = nil; presentedMidpoint = nil; lastSourceSequence = nil
            midpointCosts.removeAll(); calibrationWarmupsRemaining = 2; nativeCosts.removeAll(); cooldownUntil = 0; cooldownReason = nil
            comfortableMidpoints = 0; lastRaisedToLongEdge = nil; blockedRaiseTarget = nil
            duplicatePairWindow.removeAll(); lastDuplicateCheck = nil
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
                frames.setInterpolationState("呈现节奏调整")
            }
        }
        var skipInterpolation = false
        var endpointPresentation: Double?
        if let pending = pendingSource {
            if pending.settings != settings || pending.size != size || pending.aspect != aspectMode ||
                CVPixelBufferGetWidth(pending.buffer) != CVPixelBufferGetWidth(buffer) ||
                CVPixelBufferGetHeight(pending.buffer) != CVPixelBufferGetHeight(buffer) {
                pendingSource = nil // Latest source/settings always replace, never queue behind an obsolete pair.
                // Preserve a live GPU-error guard; otherwise this is only a
                // settings/resize cooldown, not a newly failed GPU command.
                if cooldownReason == nil { cooldownUntil = now + FrameInterpolationPolicy.overloadCooldownSeconds }
            } else if !endpointIsFresh(pending) {
                pendingSource = nil; presentedMidpoint = nil; skipInterpolation = true
                frames.setInterpolationState("呈现节奏调整")
            } else {
                // A compositor miss is not an inference overload. Keep the ONE fixed
                // endpoint ordered and rebase it, rather than cool down for two seconds.
                endpointPresentation = max(pending.presentationTime, lastPresentationTime + pending.sourcePeriod / 2, now + (p95(nativeCosts) ?? 0.002) + 0.001)
                (buffer, sequence, receivedAt) = (pending.buffer, pending.sequence, pending.receivedAt)
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
                interpolationLink?.invalidate(); pendingSource = nil
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
            pendingSource = nil; forceDraw = true; inFlight.signal(); requestRender(); return
        }
        // A drawable may have waited for presentation. Always take the newest frame afterwards.
        if endpointPresentation == nil { (buffer, sequence, receivedAt) = (fresh.buffer, fresh.sequence, fresh.receivedAt) }
        // Revalidate after drawable acquisition. Never draw a stale endpoint after it
        // was discarded: restore the atomic latest snapshot for immediate fallback.
        if let endpoint = endpointPresentation {
            let revised = max(endpoint, CACurrentMediaTime() + (p95(nativeCosts) ?? 0.002) + 0.001)
            if let pending = pendingSource, pending.sequence == sequence, endpointIsFresh(pending, target: revised) {
                endpointPresentation = revised
            } else {
                pendingSource = nil; endpointPresentation = nil; presentedMidpoint = nil; skipInterpolation = true
                (buffer, sequence, receivedAt) = (fresh.buffer, fresh.sequence, fresh.receivedAt)
                frames.setInterpolationState("呈现节奏调整")
            }
        }
        var generatedMidpoint = false
        var calibratedMidpoint = false
        var presentationTime = endpointPresentation
        var sourceImage = CIImage(cvPixelBuffer: buffer)
        let mediaFPS = frames.sourceFrameRate()
        let sourceFPS = FrameInterpolationPolicy.nominalInputFPS(mediaFPS ?? 0) ?? 0
        let interpolationRequested = settings.enhancementEnabled && settings.frameInterpolation != .off
        let displayFPS = min(observedDisplayFPS, Double(window.screen?.maximumFramesPerSecond ?? 60))
        // Measure true content cadence even before admission: 30 FPS games duplicated
        // into a 60 Hz signal should still admit 2x on 60 Hz displays.
        if endpointPresentation == nil,
           let cadencePair = frames.interpolationPair(sequence: sequence), lastSourceSequence == cadencePair.1 {
            _ = isDuplicatePair(previous: cadencePair.0, current: buffer, sequence: sequence, streamEpoch: streamEpoch)
        }
        let contentFPS = sourceFPS / pairBudgetMultiplier()
        frames.setMeasuredContentFPS(pairBudgetMultiplier() > 1.05 && contentFPS >= 1 ? contentFPS : nil)
        let admitted = FrameInterpolationPolicy.eligibility(runtimeSupported: FrameInterpolatorSupport.isSupported, inputFPS: contentFPS, displayFPS: displayFPS, inputValid: true)
        // An exact-copy source (30 Hz content in a 60 Hz signal) needs no new presentation:
        // the display already holds the identical previous drawable. Skipping the whole
        // spatial pipeline here saves GPU for midpoint quality on the unique frames.
        if interpolationRequested, admitted, !forced, !skipInterpolation, endpointPresentation == nil,
           pendingSource == nil, CACurrentMediaTime() >= cooldownUntil,
           let duplicatePair = frames.interpolationPair(sequence: sequence), lastSourceSequence == duplicatePair.1,
           isDuplicatePair(previous: duplicatePair.0, current: buffer, sequence: sequence, streamEpoch: streamEpoch) {
            frames.markDuplicateSkipped(sequence: sequence, streamEpoch: streamEpoch)
            lastSourceSequence = sequence
            lastSubmitted = RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode)
            inFlight.signal()
            return
        }
        if interpolationRequested {
            if !FrameInterpolatorSupport.isSupported { frames.setInterpolationState("插帧不可用") }
            else if !admitted {
                frames.setInterpolationState(mediaFPS == nil ? "等待稳定输入帧率" :
                    (sourceFPS == 0 ? "当前输入帧率不支持2×，使用原始帧率" : "显示器刷新率不足，使用原始帧率"))
            }
            else if CACurrentMediaTime() < cooldownUntil { frames.setInterpolationState(cooldownReason ?? (settings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率")) }
            else if endpointPresentation == nil, !skipInterpolation,
                    let pair = frames.interpolationPair(sequence: sequence), lastSourceSequence == pair.1,
                    let dimensions = FrameInterpolationPolicy.targetDimensions(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer), mode: settings.frameInterpolation, inputFPS: sourceFPS / pairBudgetMultiplier(), maximumLongEdge: adaptiveLongEdge),
                    pair.2.isNumeric, pair.3.isNumeric,
                    abs(CMTimeGetSeconds(CMTimeSubtract(pair.3, pair.2)) - 1 / sourceFPS) <= 0.1 / sourceFPS,
                    CVPixelBufferGetWidth(pair.0) == CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(pair.0) == CVPixelBufferGetHeight(buffer),
                    !isDuplicatePair(previous: pair.0, current: buffer, sequence: sequence, streamEpoch: streamEpoch),
                    #available(macOS 26.0, *), let interpolator {
                if interpolationDimensions != dimensions {
                    interpolationDimensions = dimensions
                    midpointCosts.removeAll(); calibrationWarmupsRemaining = 2
                }
                interpolator.prepare(width: dimensions.width, height: dimensions.height)
                if !interpolator.isReady { frames.setInterpolationState("插帧准备中") }
                if interpolator.isReady {
                    let midCost = p95(midpointCosts), sourceCost = p95(nativeCosts)
                    let slot = 0.5 / sourceFPS
                    let budgetSlot = slot * pairBudgetMultiplier()
                    let budgetFits = midCost.map { $0 <= budgetSlot * FrameInterpolationPolicy.midpointBudgetFraction } ?? false
                    let sourceFits = sourceCost.map { $0 <= budgetSlot * FrameInterpolationPolicy.budgetFraction } ?? false
                    let pairFits = midCost.flatMap { mid in sourceCost.map { FrameInterpolationPolicy.costsFit(midpoint: mid, source: $0, slot: budgetSlot) } } ?? false
                    let earliest = CACurrentMediaTime() + (midCost ?? 0.002) + slot * 0.1
                    let displaySlot = displayFPS > 0 ? 1 / displayFPS : slot
                    let nextPairSlot = scheduledSourceUntil + slot
                    let target = nextPairSlot >= earliest ? nextPairSlot :
                        displayTargetTime + max(0, ceil((earliest - displayTargetTime) / displaySlot)) * displaySlot
                    let deadlineFits = displayTargetTime > 0 && target <= CACurrentMediaTime() + 1.5 * pairBudgetMultiplier() / sourceFPS
                    // A hidden calibration pass shares the native frame's command buffer. It
                    // never increments generated counts or advertises interpolation as active.
                    let mayGenerate = midCost.flatMap { mid in sourceCost.map {
                        FrameInterpolationPolicy.allowsMeasuredPair(midpoint: mid, source: $0, slot: budgetSlot,
                            force: settings.forceFrameInterpolation, deadlineFits: deadlineFits)
                    } } ?? false
                    if midCost == nil || mayGenerate {
                        if let midpoint = interpolator.interpolate(previous: CIImage(cvPixelBuffer: pair.0), current: sourceImage,
                            previousTime: pair.2, currentTime: pair.3, context: ciContext, command: command,
                            previousBuffer: pair.0, currentBuffer: buffer,
                            fastInputResampling: settings.frameInterpolation == .efficient) {
                            if midCost == nil { calibratedMidpoint = true }
                            else {
                                generatedMidpoint = true; sourceImage = midpoint
                                presentationTime = target
                                pendingSource = PendingSource(buffer: buffer, receivedAt: receivedAt, sequence: sequence,
                                    settings: settings, size: size, aspect: aspectMode,
                                    presentationTime: target + slot, sourcePeriod: 1 / sourceFPS)
                            }
                        }
                    } else if !settings.forceFrameInterpolation && (!budgetFits || !sourceFits || !pairFits) {
                        cooldownReason = nil
                        cooldownUntil = CACurrentMediaTime() + FrameInterpolationPolicy.overloadCooldownSeconds
                        midpointCosts.removeAll(); calibrationWarmupsRemaining = 2
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
        let smoothMidpoint = generatedMidpoint && settings.frameInterpolation == .efficient
        let workingScale = settings.enhancementEnabled && !smoothMidpoint ? max(1, targetLongEdge / sourceLongEdge) : 1
        let workingWidth = Int((source.width * workingScale).rounded())
        let workingHeight = Int((source.height * workingScale).rounded())
        var usedMetalFX = false
        var usedAI = false
        if settings.enhancementEnabled, workingScale > 1.01, settings.upscaleMethod == .ai, !interpolationRequested {
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
            } else { stopAIUpscaler() }
        } else { stopAIUpscaler() }
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
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
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
        let period = sourceFPS > 0 ? 0.5 / sourceFPS : 0
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
                guard time > 0 else { self.forceDraw = true; self.requestRenderIfStateChanged(); return }
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
                if wasGenerated { self.presentedMidpoint = (presentedSequence, time) }
                else {
                    if wasEndpoint, let midpoint = self.presentedMidpoint,
                       midpoint.sequence == presentedSequence, period > 0,
                       abs(time - midpoint.time - period) <= period * 0.35 {
                        presentedFrameStore.setInterpolationState(self.settings.forceFrameInterpolation ? "强制插帧运行中" : "插帧运行中")
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
            scheduledSourceUntil = time; awaitingSourcePresentation = (sequence, time); pendingSource = nil
        }
        let semaphore = inFlight
        let frameStore = frames
        let frameSequence = sequence
        let frameReceivedAt = receivedAt
        let shouldMeasure = !generatedMidpoint && frameSequence != lastMeasuredSequence
        let wasMidpoint = generatedMidpoint
        let wasCalibration = calibratedMidpoint
        let measuredSlot = sourceFPS > 0 ? 0.5 / sourceFPS : 0
        let measuredBudgetSlot = measuredSlot * pairBudgetMultiplier()
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
                            frameStore.setInterpolationCost(seconds: cost + (self.p95(self.nativeCosts) ?? 0), budget: 2 * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                            frameStore.setInterpolationState("插帧准备中")
                        } else if wasMidpoint || wasCalibration {
                            self.midpointCosts.append(cost); self.midpointCosts = Array(self.midpointCosts.suffix(32))
                            frameStore.setInterpolationCost(seconds: (self.p95(self.midpointCosts) ?? cost) + (self.p95(self.nativeCosts) ?? 0), budget: 2 * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                        } else {
                            self.nativeCosts.append(cost); self.nativeCosts = Array(self.nativeCosts.suffix(32))
                            if let mid = self.p95(self.midpointCosts) {
                                frameStore.setInterpolationCost(seconds: mid + (self.p95(self.nativeCosts) ?? cost), budget: 2 * measuredBudgetSlot * FrameInterpolationPolicy.pairBudgetFraction)
                            }
                        }
                    }
                    let measuredCost = (wasMidpoint || wasCalibration) ? self.p95(self.midpointCosts) : self.p95(self.nativeCosts)
                    let pairOverBudget = self.p95(self.midpointCosts).flatMap { mid in self.p95(self.nativeCosts).map { !FrameInterpolationPolicy.costsFit(midpoint: mid, source: $0, slot: measuredBudgetSlot) } } ?? false
                    let individualLimit = measuredBudgetSlot * ((wasMidpoint || wasCalibration) ? FrameInterpolationPolicy.midpointBudgetFraction : FrameInterpolationPolicy.budgetFraction)
                    if !succeeded || (!expectedSettings.forceFrameInterpolation && !warming && (wasMidpoint || wasCalibration || wasEndpoint) && measuredSlot > 0 && ((measuredCost ?? 0) > individualLimit || pairOverBudget)) {
                        // A successful midpoint already owns a fixed endpoint. Complete
                        // that pair even when its measured cost disables the NEXT pair.
                        // GPU errors invalidate the pair; age/epoch guards still apply.
                        self.cooldownReason = succeeded ? nil : "GPU错误，保留原始画面"
                        if !succeeded { self.pendingSource = nil }
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
                        self.midpointCosts.removeAll(); self.calibrationWarmupsRemaining = 2
                        self.comfortableMidpoints = 0
                        #if MONIVIEW_PREVIEW_TESTING
                        self.trace("COST fail seq=\(frameSequence) mid=\(wasMidpoint) calib=\(wasCalibration) endpoint=\(wasEndpoint) CPU=\(encodedCPUSeconds*1000) GPU=\(gpuMS)")
                        #endif
                        frameStore.setInterpolationState(self.cooldownReason ?? (expectedSettings.frameInterpolation == .quality ? "清晰档超预算，保留原始画面" : "处理超预算，暂用原始帧率"))
                    } else if succeeded, wasMidpoint, measuredSlot > 0, let mid = self.p95(self.midpointCosts) {
                        // Sustained headroom after a step-down: climb one rung back and
                        // re-measure. ~90 presented midpoints is about 1.5 s at 60 FPS.
                        if self.adaptiveLongEdge != nil, mid <= measuredBudgetSlot * 0.55 {
                            self.comfortableMidpoints += 1
                        } else {
                            self.comfortableMidpoints = 0
                        }
                        if self.comfortableMidpoints >= 90 {
                            self.comfortableMidpoints = 0
                            self.lastRaisedToLongEdge = nil // Current size has proven itself.
                            let nowT = CACurrentMediaTime()
                            if let current = self.adaptiveLongEdge, nowT - self.lastRaiseAt > 10 {
                                let ceiling = FrameInterpolationPolicy.ceilingLongEdge(mode: expectedSettings.frameInterpolation, inputFPS: 0.5 / measuredBudgetSlot)
                                var target = FrameInterpolationPolicy.raisedLongEdge(after: current)
                                if let ceiling, (target ?? ceiling) >= ceiling { target = nil }
                                let targetEdge = target ?? ceiling
                                if targetEdge != nil, targetEdge != self.blockedRaiseTarget {
                                    self.adaptiveLongEdge = target
                                    self.lastRaiseAt = nowT
                                    self.lastRaisedToLongEdge = targetEdge
                                    self.midpointCosts.removeAll(); self.calibrationWarmupsRemaining = 2
                                }
                            }
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
        lastSubmitted = RenderKey(sequence: sequence, settings: settings, size: size, aspect: aspectMode, midpoint: generatedMidpoint)
    }
}

/// CADisplayLink retains its target; this adapter keeps the preview's lifetime independent.
private final class InterpolationDisplayLinkProxy: NSObject {
    weak var view: CapturePreviewNSView?
    init(view: CapturePreviewNSView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.interpolationTick(link) }
}
