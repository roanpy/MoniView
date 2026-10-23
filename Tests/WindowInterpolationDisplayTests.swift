import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import QuartzCore
@preconcurrency import ScreenCaptureKit

// A real 20 FPS AppKit window through ScreenCaptureKit and the production preview.
// This is cadence wiring coverage, not HDMI, capture-card, game-quality or long-run proof.
setbuf(stdout, nil)

// Only the two temporary fixture windows are affected, including on FAIL/SKIP exits.
private var cleanupWindows: (() -> Void)?

private let contentFPS = 20.0
private let targetOutputFPS = 60.0
private let outputSlot = 1 / targetOutputFPS
// Each one-second sample must independently stay within 10% of 20 source + 40 generated.
// The 1.6-slot P95 and 80% ordered-pair thresholds mirror the existing cadence checks;
// there is deliberately no environment override that can loosen them.
private let sourceRateRange = 18.0...22.0
private let generatedRateRange = 36.0...44.0
private let outputRateRange = 54.0...66.0
private let p95Limit = outputSlot * 1.6 + 0.001
private let completePairFraction = 0.8
private let presentationLimit = 3
private let warmupSeconds = 2.5
private let sampleSeconds = 1.0
private let maximumStartupRecoveries = 1
private var previewGeneration = 0
private var recoveryCount = 0
private var recoveryPending = false
private var steadySamplingStarted = false
private var retiredQueuePeak = 0
private var lifecycleStartedAt = CACurrentMediaTime()
private var lifecycleCounts: [Int: (source: Int, generated: Int)] = [:]

private func skipFixture(_ reason: String) -> Never {
    print("SKIP real-window interpolation fixture: \(reason) (exit 2; not a pass)")
    cleanupWindows?()
    exit(2)
}

private func requireFixture(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL real-window interpolation assertion: \(message)")
        cleanupWindows?()
        exit(1)
    }
}

@MainActor
private func pump(_ seconds: TimeInterval) async {
    // Suspend the fixture so app.run() owns event dispatch and renderer main-queue work.
    do {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    } catch {
        requireFixture(false, "fixture wait was cancelled: \(error)")
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        await pump(min(0.05, max(0, deadline - CACurrentMediaTime())))
    }
    return condition()
}

private final class MotionView: NSView {
    private(set) var frameIndex = 0

    override var isOpaque: Bool { true }

    func advance() {
        frameIndex += 1
        needsDisplay = true
        displayIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.025, green: 0.035, blue: 0.06, alpha: 1).setFill()
        bounds.fill()

        // Static texture makes optical flow observable on every content update.
        for row in 0..<6 {
            for column in 0..<10 {
                let light = (row + column) % 2 == 0
                NSColor(calibratedWhite: light ? 0.18 : 0.08, alpha: 1).setFill()
                NSRect(x: 18 + CGFloat(column) * 44,
                       y: 22 + CGFloat(row) * 38,
                       width: 40, height: 34).fill()
            }
        }

        let cycle = frameIndex % 120
        let travel = max(1, bounds.width - 150)
        let x = 18 + CGFloat(cycle) / 119 * travel
        let y = bounds.midY + CGFloat(sin(Double(frameIndex) * 0.19)) * 22 - 38
        let card = NSRect(x: x, y: y, width: 132, height: 76)
        NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9).fill()

        for row in 0..<4 {
            for column in 0..<6 {
                NSColor(calibratedWhite: (row + column + frameIndex) % 2 == 0 ? 0.95 : 0.18, alpha: 1).setFill()
                NSRect(x: card.minX + 7 + CGFloat(column) * 20,
                       y: card.minY + 7 + CGFloat(row) * 16,
                       width: 17, height: 13).fill()
            }
        }

        let label = String(format: "20 FPS source · frame %05d", frameIndex)
        (label as NSString).draw(
            at: NSPoint(x: 18, y: bounds.height - 30),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white
            ])
    }
}

private final class AnimationDriver {
    let view: MotionView
    private var link: CADisplayLink?
    private let proxy = AnimationDriverProxy()
    private var nextUpdate = 0.0
    private var started = false

    init(view: MotionView) {
        self.view = view
        proxy.driver = self
    }

    func start() {
        link?.invalidate()
        view.displayIfNeeded()
        nextUpdate = 0
        started = false
        // Drive content on the display clock. A free-running Timer lands on arbitrary window
        // server boundaries, so its captured unique PTS alternates by several refresh ticks;
        // that measures scheduler jitter rather than this fixture's intended 20 FPS content.
        let link = view.displayLink(target: proxy, selector: #selector(AnimationDriverProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        view.displayIfNeeded()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if !started {
            nextUpdate = now
            started = true
        }
        let period = 1 / contentFPS
        guard now + 0.000_001 >= nextUpdate else { return }
        view.advance()
        nextUpdate += period
        if nextUpdate < now - period {
            nextUpdate = now + period
        }
    }
}

private final class AnimationDriverProxy: NSObject {
    weak var driver: AnimationDriver?
    @objc func tick(_ link: CADisplayLink) { driver?.tick(link) }
}

private struct PresentationEvent {
    let sequence: UInt64
    let generated: Bool
    let time: TimeInterval
    let renderer: Int
}

private struct IngressEvent {
    let generation: UInt64
    let generationAccepted: Bool
    let token: UInt64?
    let pts: CMTime?
    let acceptedSequence: UInt64?
    let acceptedEpoch: UInt64?
    let arrival: TimeInterval
}

private final class ProbeRecorder {
    private let lock = NSLock()
    private var presentations: [PresentationEvent] = []
    private var ingresses: [IngressEvent] = []
    private var states: [MacWindowCapture.State] = []
    private var dropped = 0

    func recordPresentation(sequence: UInt64, generated: Bool, time: TimeInterval, renderer: Int) {
        lock.lock()
        presentations.append(PresentationEvent(sequence: sequence, generated: generated, time: time,
                                               renderer: renderer))
        lock.unlock()
    }

    func recordIngress(generation: UInt64, generationAccepted: Bool, token: UInt64?,
                       pts: CMTime?, acceptedSequence: UInt64?, acceptedEpoch: UInt64?) {
        lock.lock()
        ingresses.append(IngressEvent(
            generation: generation, generationAccepted: generationAccepted, token: token,
            pts: pts, acceptedSequence: acceptedSequence, acceptedEpoch: acceptedEpoch,
            arrival: CACurrentMediaTime()))
        lock.unlock()
    }

    func recordState(_ state: MacWindowCapture.State) {
        lock.lock(); states.append(state); lock.unlock()
    }

    func recordDrop() { lock.lock(); dropped += 1; lock.unlock() }

    var presentationEvents: [PresentationEvent] {
        lock.lock(); defer { lock.unlock() }; return presentations
    }

    var ingressEvents: [IngressEvent] {
        lock.lock(); defer { lock.unlock() }; return ingresses
    }

    var captureStates: [MacWindowCapture.State] {
        lock.lock(); defer { lock.unlock() }; return states
    }

    var dropCount: Int { lock.lock(); defer { lock.unlock() }; return dropped }
}

private struct WindowSample {
    let label: String
    let duration: TimeInterval
    let source: Int
    let generated: Int
    let sourceFPS: Double
    let generatedFPS: Double
    let outputFPS: Double
    let p95MS: Double
    let engine: String
    let multiplier: Double?
    let basisFPS: Double?
}

private struct IngressSummary {
    let count: Int
    let medianPTSIntervalMS: Double
    let contentFPS: Double?, uniqueUpdates: Int, measurementDuration: Double?
    let firstPTS: Double, lastPTS: Double
}

private struct PairSummary {
    let sources: Int
    let generated: Int
    let completePairs: Int
    let badOrderGroups: Int
}

private func p95(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return .infinity }
    return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
}

private func pairSummary(_ events: [PresentationEvent]) -> PairSummary {
    let ordered = events.sorted { $0.time < $1.time }
    var complete = 0
    var badOrder = 0
    var sources = 0

    for group in Dictionary(grouping: ordered, by: \.sequence).values {
        let byTime = group.sorted { $0.time < $1.time }
        let endpoints = byTime.filter { !$0.generated }
        guard !endpoints.isEmpty else { continue }
        sources += endpoints.count
        guard endpoints.count == 1, let endpoint = endpoints.first else {
            badOrder += 1
            continue
        }
        let midpoints = byTime.filter(\.generated)
        if midpoints.count != 2 {
            if midpoints.count > 2 { badOrder += 1 }
            continue
        }
        if midpoints[0].time < midpoints[1].time,
           midpoints[1].time < endpoint.time {
            complete += 1
        } else {
            badOrder += 1
        }
    }
    return PairSummary(sources: sources, generated: ordered.filter(\.generated).count,
                       completePairs: complete, badOrderGroups: badOrder)
}

private func inspectIngress(_ recorder: ProbeRecorder, from start: TimeInterval,
                            to end: TimeInterval, token: UInt64) -> IngressSummary {
    let accepted = recorder.ingressEvents.filter {
        $0.arrival >= start && $0.arrival <= end && $0.acceptedSequence != nil
    }
    requireFixture(accepted.count >= 10, "fewer than 10 real ScreenCaptureKit frames arrived in a sample")
    requireFixture(accepted.allSatisfy { $0.generationAccepted && $0.token == token },
                   "accepted frames did not all carry the current capture generation and ingest token")
    requireFixture(Set(accepted.map(\.generation)).count == 1,
                   "one sample mixed multiple ScreenCaptureKit generations")
    requireFixture(Set(accepted.compactMap(\.acceptedEpoch)).count == 1,
                   "one sample mixed multiple LatestVideoFrame epochs")

    let pts = accepted.compactMap { event -> Double? in
        guard let value = event.pts else { return nil }
        let seconds = CMTimeGetSeconds(value)
        return seconds.isFinite ? seconds : nil
    }
    requireFixture(pts.count == accepted.count && pts.count >= 10,
                   "ScreenCaptureKit delivered a missing or non-numeric PTS")
    requireFixture(zip(pts, pts.dropFirst()).allSatisfy { $0 < $1 },
                   "ScreenCaptureKit PTS did not increase strictly")
    let ptsIntervals = zip(pts, pts.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
    let medianPTS = ptsIntervals[ptsIntervals.count / 2]
    requireFixture(end - accepted.last!.arrival <= 0.25,
                   "the newest real capture frame was stale at the end of the sample")

    let currentEpoch = accepted.last!.acceptedEpoch
    guard let snapshot = framesGlobal.inputContentCadenceSnapshot(),
          snapshot.streamEpoch == currentEpoch,
          let measuredFPS = snapshot.fps else {
        requireFixture(false, "no fresh unique-content cadence was derived from the captured pixels")
        fatalError("unreachable")
    }
    requireFixture(sourceRateRange.contains(measuredFPS),
                   "measured AppKit content rate was \(measuredFPS) FPS, outside \(sourceRateRange)")
    return IngressSummary(count: accepted.count, medianPTSIntervalMS: medianPTS,
                          contentFPS: measuredFPS,
                          uniqueUpdates: snapshot.uniqueUpdateCount,
                          measurementDuration: snapshot.measurementDuration,
                          firstPTS: pts.first!, lastPTS: pts.last!)
}

@MainActor
private func samplePresentationWindow(_ label: String, duration: TimeInterval,
                                      token: UInt64) async -> WindowSample {
    _ = framesGlobal.presentationStatistics()
    let eventStart = recorderGlobal.presentationEvents.count
    let drawableWaitStart = preview.drawableWaitMS.count
    let start = CACurrentMediaTime()
    await pump(duration)
    let end = CACurrentMediaTime()
    let stats = framesGlobal.presentationStatistics()
    let events = Array(recorderGlobal.presentationEvents.dropFirst(eventStart))
        .sorted { $0.time < $1.time }
    let generatedEvents = events.filter(\.generated).count
    let sourceEvents = Set(events.filter { !$0.generated }.map(\.sequence)).count

    let elapsed = max(0.001, end - start)
    let sourceFPS = Double(stats.presentedSource) / elapsed
    let generatedFPS = Double(stats.generated) / elapsed
    let outputFPS = sourceFPS + generatedFPS
    let intervals = zip(events, events.dropFirst()).map { $1.time - $0.time }.filter { $0 > 0 }
    let intervalP95MS = p95(intervals) * 1000
    let activity = framesGlobal.currentInterpolationActivity()

    // Print raw observations before any assertion can terminate the sample. CAD ticks
    // are diagnostic only; the rate gates below still count actual presentations.
    let waits = Array(preview.drawableWaitMS.dropFirst(drawableWaitStart))
    let waitP95 = waits.isEmpty ? "n/a" : String(format: "%.2fms", p95(waits))
    let waitMax = waits.max().map { String(format: "%.2fms", $0) } ?? "n/a"
    let cadTicks = preview.displayTickTimes.filter { $0 >= start && $0 <= end }.count
    let cadence = framesGlobal.inputContentCadenceSnapshot()
    let ingressEvents = recorderGlobal.ingressEvents.filter {
        $0.arrival >= start && $0.arrival <= end && $0.acceptedSequence != nil
    }
    let newestAge = ingressEvents.last.map { String(format: "%.3fs", end - $0.arrival) } ?? "n/a"
    let pairs = pairSummary(events)
    print(String(format: "Sample diagnostics [%@]: %.3fs source=%d (%.2f FPS) generated=%d (%.2f FPS) output=%.2f FPS P95=%.2fms callbacks source=%d generated=%d",
                 label, elapsed, stats.presentedSource, sourceFPS, stats.generated,
                 generatedFPS, outputFPS, intervalP95MS, sourceEvents, generatedEvents))
    print("  previewState=\(framesGlobal.currentPreviewState()) interpolationState=\(framesGlobal.currentInterpolationState()) engine=\(framesGlobal.currentEngine()) activity=\(String(describing: activity)) renderers=\(Set(events.map(\.renderer)).sorted()) recoveries=\(recoveryCount)")
    print("  drawableSize=\(preview.drawableSize) drawableWaits=\(waits.count) waitP95=\(waitP95) waitMax=\(waitMax) queuePeak=\(preview.peakOutstandingPresentations) CADticks=\(cadTicks) displayRates=\(framesGlobal.currentDisplayRates())")
    print("  acceptedIngress=\(ingressEvents.count) newestAge=\(newestAge) contentFPS=\(String(describing: cadence?.fps)) uniqueUpdates=\(cadence?.uniqueUpdateCount ?? 0) strictFPS=\(String(describing: cadence?.strictUniqueFPS)) strictConfirmed=\(cadence?.strictRepeatedCadenceConfirmed ?? false) strictRepeats=\(cadence?.strictRepeatPairCount ?? 0) strictUpdates=\(cadence?.strictUniqueUpdateCount ?? 0) cadenceEpoch=\(String(describing: cadence?.streamEpoch)) currentEpoch=\(framesGlobal.streamGeneration()) pairs=\(pairs.completePairs)/\(pairs.sources) badOrderGroups=\(pairs.badOrderGroups)")
    printWindowDiagnostics(sourceWindow, previewWindow, context: "\(label) before assertions")
    requireVisible(sourceWindow, previewWindow)

    requireFixture(stats.generated == generatedEvents,
                   "\(label): generated presentation statistics did not match onPresentation callbacks")
    requireFixture(stats.presentedSource == sourceEvents,
                   "\(label): source presentation statistics did not match onPresentation callbacks")
    let ingress = inspectIngress(recorderGlobal, from: start, to: end, token: token)

    requireFixture(sourceRateRange.contains(sourceFPS),
                   "\(label): source output \(sourceFPS) FPS is outside \(sourceRateRange)")
    requireFixture(generatedRateRange.contains(generatedFPS),
                   "\(label): generated output \(generatedFPS) FPS is outside \(generatedRateRange) (only generated > 0 is insufficient)")
    requireFixture(outputRateRange.contains(outputFPS),
                   "\(label): total output \(outputFPS) FPS is outside \(outputRateRange) around 20+40≈60")
    requireFixture(intervalP95MS <= p95Limit * 1000,
                   "\(label): presentation P95 \(intervalP95MS)ms exceeds \(p95Limit * 1000)ms")
    requireFixture(framesGlobal.currentEngine() == "MetalFX",
                   "\(label): requested MetalFX screen path was not observed (engine=\(framesGlobal.currentEngine()))")
    requireFixture(abs((activity?.multiplier ?? .nan) - 3) < 0.001,
                   "\(label): production renderer did not publish the 3x Flow step")
    requireFixture(sourceRateRange.contains(activity?.basisFPS ?? .nan),
                   "\(label): published interpolation basis is not the measured ~20 FPS")

    let sample = WindowSample(
        label: label, duration: elapsed,
        source: stats.presentedSource, generated: stats.generated,
        sourceFPS: sourceFPS, generatedFPS: generatedFPS, outputFPS: outputFPS,
        p95MS: intervalP95MS, engine: framesGlobal.currentEngine(),
        multiplier: activity?.multiplier, basisFPS: activity?.basisFPS)
    print(String(format: "%@: %.2fs source=%.2f FPS generated=%.2f FPS output=%.2f FPS P95=%.2fms | SCK PTS median=%.2fms content=%.2f FPS (%d updates/%@) rawPTS=%.6f...%.6f",
                 label, elapsed, sourceFPS, generatedFPS, outputFPS, intervalP95MS,
                 ingress.medianPTSIntervalMS, ingress.contentFPS ?? .nan,
                 ingress.uniqueUpdates,
                 ingress.measurementDuration.map { String(format: "%.3fs", $0) } ?? "—",
                 ingress.firstPTS, ingress.lastPTS))
    return sample
}

private func validatePhasePairs(_ events: [PresentationEvent], label: String) {
    let pairs = pairSummary(events)
    requireFixture(pairs.sources > 0, "\(label): no source endpoint presented")
    requireFixture(pairs.badOrderGroups == 0,
                   "\(label): \(pairs.badOrderGroups) groups had extra or out-of-order generated phases")
    let required = Int(ceil(Double(pairs.sources) * completePairFraction))
    requireFixture(pairs.completePairs >= required,
                   "\(label): complete ordered pairs \(pairs.completePairs)/\(pairs.sources), required \(required)")
    print("\(label): pairs complete=\(pairs.completePairs)/\(pairs.sources), generated presentations=\(pairs.generated), bad-order groups=0")
}

private func windowVisibilityIssue(_ source: NSWindow, _ preview: NSWindow) -> String? {
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       (session["CGSSessionScreenIsLocked"] as? Bool) == true {
        return "screen became locked"
    }
    guard source.isVisible, !source.isMiniaturized, source.occlusionState.contains(.visible),
          preview.isVisible, !preview.isMiniaturized, preview.occlusionState.contains(.visible),
          source.screen != nil, preview.screen != nil, source.screen == preview.screen,
          !source.frame.intersects(preview.frame) else {
        return "source and preview windows must remain visible, unoccluded and non-overlapping"
    }
    guard let screen = preview.screen, screen.maximumFramesPerSecond >= 60 else {
        return "the preview display does not report the required 60 Hz minimum"
    }
    return nil
}

private func printWindowDiagnostics(_ source: NSWindow, _ preview: NSWindow, context: String) {
    print("Window diagnostics [\(context)]: sameScreen=\(source.screen == preview.screen) overlap=\(source.frame.intersects(preview.frame)) automaticTabbing=\(NSWindow.allowsAutomaticWindowTabbing)")
    for (name, window) in [("source", source), ("preview", preview)] {
        let screenInfo = window.screen.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
            return "id=\(id) frame=\(NSStringFromRect(screen.frame)) visibleFrame=\(NSStringFromRect(screen.visibleFrame)) maximumFPS=\(screen.maximumFramesPerSecond) backingScale=\(screen.backingScaleFactor)"
        } ?? "nil"
        print("  \(name): number=\(window.windowNumber) frame=\(NSStringFromRect(window.frame)) isVisible=\(window.isVisible) miniaturized=\(window.isMiniaturized) occlusionVisible=\(window.occlusionState.contains(.visible)) occlusionRaw=\(window.occlusionState.rawValue) activeSpace=\(window.isOnActiveSpace) level=\(window.level.rawValue) tabbingMode=\(window.tabbingMode.rawValue) tabbedWindows=\(window.tabbedWindows?.count ?? 0) screen={\(screenInfo)}")
    }
}

private func requireVisible(_ source: NSWindow, _ preview: NSWindow) {
    if let issue = windowVisibilityIssue(source, preview) {
        printWindowDiagnostics(source, preview, context: "visibility check failed")
        skipFixture(issue)
    }
}

private func printPresentationLifecycle(_ context: String) {
    let counts = lifecycleCounts[previewGeneration] ?? (source: 0, generated: 0)
    let latest = framesGlobal.latestSnapshot()
    print(String(format: "Lifecycle +%.3fs [%@]: renderer=%d recoveries=%d pending=%@ measured=%@ sourceCallbacks=%d generatedCallbacks=%d",
                 CACurrentMediaTime() - lifecycleStartedAt, context, previewGeneration, recoveryCount,
                 String(recoveryPending), String(steadySamplingStarted), counts.source, counts.generated))
    print("  previewState=\(framesGlobal.currentPreviewState()) interpolationState=\(framesGlobal.currentInterpolationState()) blankRequestPending=\(framesGlobal.isBlankRequestPending) latestSequence=\(String(describing: latest?.sequence)) streamEpoch=\(framesGlobal.streamGeneration())")
    print("  lifetime CADticks=\(preview.displayTickTimes.count) frameDrawableAcquisitions=\(preview.drawableWaitMS.count) first3FrameWaitMS=\(Array(preview.drawableWaitMS.prefix(3))) zeroPresentedTime=\(preview.testZeroPresentedTimeCount) queuePeak=\(preview.peakOutstandingPresentations) retiredQueuePeak=\(retiredQueuePeak)")
    print("  viewAttached=\(preview.window === previewWindow) hidden=\(preview.isHiddenOrHasHiddenAncestor) frame=\(NSStringFromRect(preview.frame)) drawableSize=\(preview.drawableSize)")
    if let layer = preview.layer as? CAMetalLayer {
        print("  metalLayer frame=\(NSStringFromRect(layer.frame)) attached=\(layer.superlayer != nil) hidden=\(layer.isHidden) sync=\(layer.displaySyncEnabled) presentsWithTransaction=\(layer.presentsWithTransaction) maximumDrawables=\(layer.maximumDrawableCount)")
    }
}

private func makeFixturePreview() -> CapturePreviewNSView {
    let view = CapturePreviewNSView(frames: framesGlobal)
    view.settings.enhancementEnabled = true
    view.settings.enhancementStrength = 0.60
    view.settings.lowLatency = true
    view.settings.upscaleTarget = .screen
    view.settings.upscaleMethod = .metalFX
    view.settings.frameInterpolation = .flowBlend
    view.settings.forceFrameInterpolation = true
    view.settings.skipsExactDuplicateInterpolation = true
    // Match PreviewLayerView.updateNSView for this fixed, supported Flow configuration.
    (view.layer as? CAMetalLayer)?.displaySyncEnabled = true
    let generation = previewGeneration
    view.onPresentation = { sequence, generated, time in
        recorderGlobal.recordPresentation(sequence: sequence, generated: generated, time: time,
                                          renderer: generation)
        var counts = lifecycleCounts[generation] ?? (source: 0, generated: 0)
        if generated { counts.generated += 1 } else { counts.source += 1 }
        lifecycleCounts[generation] = counts
        if (generated ? counts.generated : counts.source) <= 3 {
            print("First presentations: renderer=\(generation) seq=\(sequence) generated=\(generated) presentedTime=\(time) callbackAt=\(CACurrentMediaTime() - lifecycleStartedAt)s sourceCallbacks=\(counts.source) generatedCallbacks=\(counts.generated)")
        }
        requireFixture(!steadySamplingStarted || generation == previewGeneration,
                       "a retired renderer delivered a presentation after steady sampling began")
    }
    view.onPresentationRecovery = { [weak view] in
        guard let view else { return }
        printPresentationLifecycle("onPresentationRecovery request \(recoveryCount + 1) from renderer \(generation)")
        printWindowDiagnostics(sourceWindow, previewWindow, context: "presentation recovery")
        requireVisible(sourceWindow, previewWindow)
        requireFixture(view === preview && generation == previewGeneration,
                       "a retired renderer requested another preview rebuild")
        recoveryCount += 1
        requireFixture(!steadySamplingStarted && recoveryCount <= maximumStartupRecoveries && !recoveryPending,
                       "preview recovery is limited to one startup rebuild; no recovery is allowed after sampling begins")
        retiredQueuePeak = max(retiredQueuePeak, view.peakOutstandingPresentations)
        requireFixture(retiredQueuePeak <= presentationLimit,
                       "retired preview exceeded the outstanding drawable bound")
        recoveryPending = true
        // Like the product's SwiftUI identity change, replace the whole view after draw returns.
        // Keep the same mailbox/token/epoch and all observations; do not restart warmup.
        DispatchQueue.main.async {
            requireFixture(!steadySamplingStarted, "preview rebuild crossed the steady sampling boundary")
            previewWindow.contentView = nil
            previewGeneration += 1
            preview = makeFixturePreview()
            previewWindow.contentView = preview
            preview.layoutSubtreeIfNeeded()
            preview.configureInterpolation()
            preview.requestRender()
            recoveryPending = false
            printPresentationLifecycle("replacement attached")
        }
    }
    return view
}

@MainActor
private func observeStartupPresentation() async {
    var previous = ""
    var reports = 0
    // Diagnostic only: at most 10 seconds and 24 changed-state reports; no redraws or retries.
    for _ in 0..<400 {
        if steadySamplingStarted { return }
        let key = "\(previewGeneration):\(framesGlobal.currentPreviewState()):\(framesGlobal.isBlankRequestPending):\(framesGlobal.latestSnapshot() == nil):\(min(3, preview.drawableWaitMS.count)):\(preview.testZeroPresentedTimeCount)"
        if key != previous, reports < 24 {
            printPresentationLifecycle("startup observation \(reports + 1)")
            previous = key
            reports += 1
        }
        await pump(0.025)
    }
}

if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
   (session["CGSSessionScreenIsLocked"] as? Bool) == true {
    skipFixture("screen is locked")
}
guard MTLCreateSystemDefaultDevice() != nil else { skipFixture("Metal is unavailable") }
guard FrameInterpolatorSupport.isSupported(.flowBlend) else { skipFixture("Flow Blend is unavailable") }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSWindow.allowsAutomaticWindowTabbing = false
let windowsAboveAll = ProcessInfo.processInfo.environment["MONIVIEW_TEST_WINDOW_ABOVE_ALL"] == "1"
let fixtureWindowLevel: NSWindow.Level = windowsAboveAll
    ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow))) : .floating

guard let screen = NSScreen.main ?? NSScreen.screens.first else { skipFixture("no display is available") }
guard screen.maximumFramesPerSecond >= 60 else {
    skipFixture("display reports \(screen.maximumFramesPerSecond) Hz; 60 Hz is required for 20→60")
}
let visible = screen.visibleFrame
let sourceSize = CGSize(width: 480, height: 270)
let previewSize = CGSize(width: 640, height: 360)
let sideGap: CGFloat = 32
let edgeMargin: CGFloat = 24
guard visible.width >= sourceSize.width + previewSize.width + sideGap + edgeMargin * 2,
      visible.height >= max(sourceSize.height, previewSize.height) + edgeMargin * 2 + 48 else {
    skipFixture("visible screen area is too small for the two non-overlapping test windows")
}

let sourceWindow = NSWindow(contentRect: NSRect(origin: .zero, size: sourceSize),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
sourceWindow.title = "MoniView real-window cadence source (20 FPS)"
sourceWindow.tabbingMode = .disallowed
sourceWindow.level = fixtureWindowLevel
sourceWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
private let motionView = MotionView(frame: NSRect(origin: .zero, size: sourceSize))
motionView.autoresizingMask = [.width, .height]
sourceWindow.contentView = motionView
sourceWindow.setFrameTopLeftPoint(NSPoint(x: visible.minX + edgeMargin,
                                         y: visible.maxY - edgeMargin))
sourceWindow.orderFront(nil)

private let framesGlobal = LatestVideoFrame()
private let recorderGlobal = ProbeRecorder()
private var preview = makeFixturePreview()

let previewWindow = NSWindow(contentRect: NSRect(origin: .zero, size: previewSize),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
cleanupWindows = {
    previewWindow.orderOut(nil)
    sourceWindow.orderOut(nil)
}
previewWindow.title = "MoniView real-window Flow 3x / MetalFX screen 0.60"
previewWindow.tabbingMode = .disallowed
previewWindow.level = fixtureWindowLevel
previewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
previewWindow.contentView = preview
previewWindow.setFrameTopLeftPoint(NSPoint(x: sourceWindow.frame.maxX + sideGap,
                                          y: visible.maxY - edgeMargin))
previewWindow.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
preview.configureInterpolation()

requireFixture(preview.settings.frameInterpolation == .flowBlend &&
               preview.settings.forceFrameInterpolation &&
               preview.settings.skipsExactDuplicateInterpolation &&
               preview.settings.upscaleMethod == .metalFX &&
               preview.settings.upscaleTarget == .screen &&
               abs(preview.settings.enhancementStrength - 0.60) < 0.0001,
               "fixture settings are not Flow + force + Follow + MetalFX screen 0.60")

private let driver = AnimationDriver(view: motionView)
@MainActor
private func runFixture() async {
    driver.start()
    printWindowDiagnostics(sourceWindow, previewWindow, context: "initialized; aboveAll=\(windowsAboveAll)")
    let visibilityWaitStarted = CACurrentMediaTime()
    let visibleWithinTimeout = await waitUntil(timeout: 3) {
        windowVisibilityIssue(sourceWindow, previewWindow) == nil
    }
    print(String(format: "Startup visibility wait: %.3fs (limit 3s), ready=%@",
                 CACurrentMediaTime() - visibilityWaitStarted, String(visibleWithinTimeout)))
    requireVisible(sourceWindow, previewWindow)
    printWindowDiagnostics(sourceWindow, previewWindow, context: "visible after initialization")

    let shareableResult: Result<SCShareableContent, Error>
    do {
        shareableResult = .success(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
    } catch {
        shareableResult = .failure(error)
    }
    let shareable: SCShareableContent
    switch shareableResult {
    case let .success(value):
        shareable = value
    case let .failure(error):
        skipFixture("ScreenCaptureKit content enumeration failed (Screen Recording permission or display availability): \(error.localizedDescription)")
    }
    guard shareable.windows.contains(where: { $0.windowID == UInt32(sourceWindow.windowNumber) }) else {
        skipFixture("the visible synthetic AppKit window is not discoverable by ScreenCaptureKit")
    }

    lifecycleStartedAt = CACurrentMediaTime()
    print("Startup diagnostics: blankRequestPending tracks the request, not confirmed presentation; existing hooks expose neither blank callbacks nor the current outstanding-token count. Frame drawable acquisitions exclude blank draws.")
    let startupObserver = Task { @MainActor in await observeStartupPresentation() }
    let initialToken = framesGlobal.beginInput(blankPreview: true)
    printPresentationLifecycle("beginInput(blankPreview:true), before capture.start")
    let capture = MacWindowCapture(
        frameSink: { sample, generation, source in
            let sourceAccepted = source.acceptsFrame(generation: generation)
            let token = source.ingestToken(forGeneration: generation)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let accepted: UInt64?
            if let token, let buffer = CMSampleBufferGetImageBuffer(sample) {
                accepted = framesGlobal.put(buffer, pts: pts,
                                            formatDescription: CMSampleBufferGetFormatDescription(sample),
                                            token: token)
            } else {
                accepted = nil
            }
            let epoch = accepted == nil ? nil : framesGlobal.streamGeneration()
            recorderGlobal.recordIngress(generation: generation, generationAccepted: sourceAccepted,
                                         token: token, pts: pts, acceptedSequence: accepted,
                                         acceptedEpoch: epoch)
        },
        state: { recorderGlobal.recordState($0) },
        dropped: { recorderGlobal.recordDrop() })

    capture.start(windowID: UInt32(sourceWindow.windowNumber), ingestToken: initialToken)
    let started = await waitUntil(timeout: 5) {
        capture.state == .running &&
        recorderGlobal.ingressEvents.contains { $0.acceptedSequence != nil && $0.token == initialToken }
    }
    if !started {
        printPresentationLifecycle("capture start timeout")
        requireFixture(false, "real window capture did not start and deliver a frame (state=\(capture.state), states=\(recorderGlobal.captureStates))")
    }
    printPresentationLifecycle("capture running; first accepted ingress observed")
    preview.requestRender()
    await pump(warmupSeconds)
    requireVisible(sourceWindow, previewWindow)
    printPresentationLifecycle("startup warmup finished")
    requireFixture(!recoveryPending, "startup ended with a preview rebuild still pending")
    steadySamplingStarted = true
    await startupObserver.value

    var phaseStart = recorderGlobal.presentationEvents.count
    var samples: [WindowSample] = []
    for index in 1...3 {
        requireVisible(sourceWindow, previewWindow)
        let sample = await samplePresentationWindow("steady \(index)", duration: sampleSeconds,
                                                    token: initialToken)
        samples.append(sample)
        requireFixture(preview.peakOutstandingPresentations <= presentationLimit,
                       "outstanding drawable tokens exceeded \(presentationLimit)")
    }
    let steadyEvents = Array(recorderGlobal.presentationEvents.dropFirst(phaseStart))
    validatePhasePairs(steadyEvents, label: "steady motion")

    // Stop the AppKit timer while leaving both windows visible. Queued work gets one source
    // period plus interpolation lifetime to drain; after that no old pair may keep presenting.
    driver.stop()
    motionView.needsDisplay = true
    motionView.displayIfNeeded()
    await pump(1.5)
    requireVisible(sourceWindow, previewWindow)
    let staticEventStart = recorderGlobal.presentationEvents.count
    _ = framesGlobal.presentationStatistics()
    await pump(1.5)
    let staticStats = framesGlobal.presentationStatistics()
    let staticEvents = Array(recorderGlobal.presentationEvents.dropFirst(staticEventStart))
    requireFixture(staticStats.generated == 0 && !staticEvents.contains(where: \.generated),
                   "static real-window content continued generating frames")
    requireFixture(framesGlobal.recentGeneratedPresentationEvidence() == nil,
                   "static content still claimed stale generated-presentation evidence")
    requireFixture(framesGlobal.currentInterpolationActivity() == nil,
                   "static content still carried stale interpolation activity")
    print("static: generated=0, presentation evidence=nil, activity=nil; duplicate skips=\(framesGlobal.takeDuplicateSkips())")

    driver.start()
    await pump(warmupSeconds)
    requireVisible(sourceWindow, previewWindow)
    phaseStart = recorderGlobal.presentationEvents.count
    var resumed: [WindowSample] = []
    for index in 1...2 {
        requireVisible(sourceWindow, previewWindow)
        resumed.append(await samplePresentationWindow("resumed \(index)", duration: sampleSeconds,
                                                      token: initialToken))
    }
    validatePhasePairs(Array(recorderGlobal.presentationEvents.dropFirst(phaseStart)), label: "resumed motion")

    let oldIngress = recorderGlobal.ingressEvents.last { $0.acceptedSequence != nil }
    requireFixture(oldIngress != nil, "no old generation/token was available for the restart isolation check")
    let oldGeneration = oldIngress!.generation
    let oldToken = oldIngress!.token!
    let oldEpoch = framesGlobal.streamGeneration()
    guard let oldSnapshot = framesGlobal.latestSnapshot(),
          let oldFormat = framesGlobal.latestFormatSnapshot()?.description else {
        requireFixture(false, "the pre-restart mailbox snapshot was missing")
        fatalError("unreachable")
    }

    capture.stop()
    await pump(0.2)
    let stoppedIngressIndex = recorderGlobal.ingressEvents.count
    requireFixture(!capture.acceptsFrame(generation: oldGeneration),
                   "MacWindowCapture still accepted the stopped generation")
    await pump(0.5)
    let ingressAfterStop = recorderGlobal.ingressEvents.dropFirst(stoppedIngressIndex)
    requireFixture(!ingressAfterStop.contains { $0.acceptedSequence != nil },
                   "the stopped ScreenCaptureKit stream kept writing accepted frames")

    let restartToken = framesGlobal.beginInput(blankPreview: true)
    printPresentationLifecycle("restart beginInput(blankPreview:true)")
    let newEpoch = framesGlobal.streamGeneration()
    let restartPresentationStart = recorderGlobal.presentationEvents.count
    requireFixture(newEpoch > oldEpoch, "restart did not advance the LatestVideoFrame epoch")
    requireFixture(framesGlobal.recentGeneratedPresentationEvidence() == nil &&
                   framesGlobal.currentInterpolationActivity() == nil,
                   "restart retained generated evidence or activity from the old epoch")
    // This negative probe checks ownership only. All measured motion above came from real
    // ScreenCaptureKit CMSampleBuffers, never from a constructed test frame.
    let lateOldWrite = framesGlobal.put(oldSnapshot.buffer, pts: oldSnapshot.pts,
                                        formatDescription: oldFormat, token: oldToken)
    requireFixture(lateOldWrite == nil,
                   "a late frame with the old ingest token was accepted into the new epoch")
    requireFixture(framesGlobal.streamGeneration() == newEpoch && framesGlobal.latest() == nil,
                   "the rejected old-epoch probe changed current mailbox state")

    let restartStart = CACurrentMediaTime()
    capture.start(windowID: UInt32(sourceWindow.windowNumber), ingestToken: restartToken)
    let restarted = await waitUntil(timeout: 5) {
        capture.state == .running &&
        recorderGlobal.ingressEvents.contains {
            $0.arrival >= restartStart && $0.generation > oldGeneration &&
            $0.token == restartToken && $0.acceptedSequence != nil
        }
    }
    if !restarted {
        requireFixture(false, "stopped real-window source did not restart (state=\(capture.state))")
    }
    preview.requestRender()
    await pump(warmupSeconds)
    requireVisible(sourceWindow, previewWindow)

    let currentRestartEpoch = framesGlobal.streamGeneration()
    let restartedIngress = recorderGlobal.ingressEvents.filter {
        $0.arrival >= restartStart && $0.acceptedSequence != nil
    }
    requireFixture(!restartedIngress.isEmpty &&
                   restartedIngress.allSatisfy { $0.generation > oldGeneration && $0.token == restartToken &&
                       $0.acceptedEpoch == currentRestartEpoch },
                   "accepted restarted input included old-generation or old-epoch data")
    let restartPresentationEvents = Array(recorderGlobal.presentationEvents.dropFirst(restartPresentationStart))
    requireFixture(restartPresentationEvents.allSatisfy { $0.sequence > oldSnapshot.sequence },
                   "presentation callbacks after restart included an old-epoch frame sequence")
    phaseStart = recorderGlobal.presentationEvents.count
    var restartedSamples: [WindowSample] = []
    for index in 1...2 {
        requireVisible(sourceWindow, previewWindow)
        restartedSamples.append(await samplePresentationWindow("restarted \(index)", duration: sampleSeconds,
                                                                token: restartToken))
    }
    validatePhasePairs(Array(recorderGlobal.presentationEvents.dropFirst(phaseStart)), label: "restarted source")

    requireFixture(framesGlobal.latestSnapshot()?.streamEpoch == framesGlobal.streamGeneration(),
                   "the preview mailbox retained a frame from an older epoch")
    requireFixture(preview.peakOutstandingPresentations <= presentationLimit,
                   "final outstanding drawable bound exceeded \(presentationLimit)")
    requireFixture(recoveryCount <= maximumStartupRecoveries && !recoveryPending &&
                   max(retiredQueuePeak, preview.peakOutstandingPresentations) <= presentationLimit,
                   "preview recovery repeated or hid a drawable bound violation")
    print("Lifecycle acceptance: startup rebuilds=\(recoveryCount)/\(maximumStartupRecoveries), renderer=\(previewGeneration), no rebuilds during steady/static/resume/restart; callbacks by renderer=\(lifecycleCounts)")

    let steadyAverage = {
        let source = samples.map(\.sourceFPS).reduce(0, +) / Double(samples.count)
        let generated = samples.map(\.generatedFPS).reduce(0, +) / Double(samples.count)
        return (source: source, generated: generated, output: source + generated)
    }()
    let sampleP95 = samples.map(\.p95MS).reduce(0, +) / Double(samples.count)
    let captureDrops = recorderGlobal.dropCount
    print(String(format: "steady average: source=%.2f FPS generated=%.2f FPS output=%.2f FPS; mean per-sample P95=%.2fms; queue peak=%d; capture drops=%d",
                 steadyAverage.source, steadyAverage.generated, steadyAverage.output, sampleP95,
                 preview.peakOutstandingPresentations, captureDrops))
    print("PASS real AppKit window → ScreenCaptureKit/MacWindowCapture → LatestVideoFrame → CapturePreviewNSView, Flow 3x, force, Follow, MetalFX screen/0.60. This does NOT certify HDMI, a capture card, game picture quality, or long-run throughput.")

    driver.stop()
    capture.stop()
    cleanupWindows?()
    exit(0)
}

private final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchOnMainThread = Thread.isMainThread
        Task { @MainActor in
            print("AppKit lifecycle: didFinishLaunching=true isRunning=\(NSApp.isRunning) launchMainThread=\(launchOnMainThread) runner=asyncMainActor")
            await runFixture()
        }
    }
}

private let fixtureApplicationDelegate = FixtureApplicationDelegate()
app.delegate = fixtureApplicationDelegate
app.run()
skipFixture("AppKit event loop ended before fixture completion")
