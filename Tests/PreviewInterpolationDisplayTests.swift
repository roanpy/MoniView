import AppKit
import CoreImage
import CoreVideo
import CoreMedia
import Foundation
import Darwin

// Preserve the final acceptance measurements even when a precondition fails.
setbuf(stdout, nil)

/// An optimized Swift build traps on a failing precondition without printing its message, so a
/// failed fixture assertion used to be indistinguishable from a crash in the code under test.
/// These helpers report before they stop: exit 2 marks an unusable configuration (not a pass),
/// exit 1 marks a failed acceptance assertion.
func skipFixture(_ why: String) -> Never {
    print("SKIP fixture: \(why)")
    exit(2)
}
func requireFixture(_ condition: Bool, _ message: String) {
    guard !condition else { return }
    print("FAIL fixture assertion: \(message)")
    exit(1)
}

// A native window and GPU with synthetic SDR input. This is not a capture-card,
// picture-quality, HDMI-latency or long-running throughput certification.
let environment = ProcessInfo.processInfo.environment
let fps = Int(environment["MONIVIEW_TEST_FPS"] ?? "30") ?? 30
let width = Int(environment["MONIVIEW_TEST_WIDTH"] ?? "1920") ?? 1920
let height = Int(environment["MONIVIEW_TEST_HEIGHT"] ?? "1080") ?? 1080
let presentationLimit = 3
let require120 = environment["MONIVIEW_REQUIRE_120"] == "1"
let requireCadence = environment["MONIVIEW_REQUIRE_2X"] == "1"
let requireForcedAttempts = environment["MONIVIEW_TEST_FORCE_CONTINUOUS"] == "1"
let repeatDivisor = Int(environment["MONIVIEW_TEST_REPEAT"] ?? (environment["MONIVIEW_TEST_DUPLICATES"] == "1" ? "2" : "1")) ?? 1
let expectedContentFPS = Double(fps) / Double(max(1, repeatDivisor))
// The renderer targets 60 FPS by the smallest whole step, using the flow tier for a third phase.
let expectedMultiplier: Double = {
    let content = expectedContentFPS
    if content * 2 >= 60 - 0.5 { return 2 }
    if content * 3 >= 60 - 0.5, content < 25 { return 3 }
    return 2
}()
let testRestart = environment["MONIVIEW_TEST_RESTART"] == "1"
let testEngineSwitch = environment["MONIVIEW_TEST_SWITCH"] == "1"
let testFollowSwitch = environment["MONIVIEW_TEST_FOLLOW_SWITCH"] == "1"
let testEndpointEvidence = environment["MONIVIEW_TEST_ENDPOINT_EVIDENCE"] == "1"
let testBlankFailure = environment["MONIVIEW_TEST_BLANK_FAILURE"] == "1"
let followEnabled = environment["MONIVIEW_TEST_FOLLOW"] == "1" || environment["MONIVIEW_TEST_DUPLICATES"] == "1"
let fault = environment["MONIVIEW_TEST_PRESENTATION_FAILURE"] == "1"
if testRestart && require120 { skipFixture("the restart test uses the non-strict fixture") }
if testEngineSwitch && !testRestart { skipFixture("engine-switch acceptance requires restart sampling") }
if testFollowSwitch && (testRestart || testEngineSwitch || require120 || requireCadence || fault) {
    skipFixture("follow-switch acceptance is exclusive with restart, engine-switch, strict, cadence and fault modes")
}
if testFollowSwitch && !(fps == 60 && repeatDivisor == 2 && followEnabled) {
    skipFixture("follow-switch acceptance requires Follow initially enabled, 60 FPS and repeat divisor 2")
}
if testEndpointEvidence && (testRestart || testEngineSwitch || testFollowSwitch || require120 || requireCadence || fault) {
    skipFixture("the endpoint-evidence probe stands alone; it cannot share a run with restart, engine-switch, follow-switch, strict, cadence or fault modes")
}
if testBlankFailure && (testRestart || testEngineSwitch || testFollowSwitch || testEndpointEvidence || require120 || requireCadence || fault) {
    skipFixture("the blank-failure probe stands alone; it cannot share a run with restart, engine-switch, follow-switch, endpoint-evidence, strict, cadence or fault modes")
}
let stopAt = require120 ? 36 : 16
let finishAt = testFollowSwitch ? 24 : (testRestart ? 33 : stopAt + 3)
let targetName = (environment["MONIVIEW_TEST_TARGET"] ?? "native").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
let testTarget: UpscaleTarget
switch targetName {
case "native", "original", "原始": testTarget = .native
case "2k", "qhd": testTarget = .qhd
case "4k", "uhd": testTarget = .uhd
case "screen", "display", "屏幕": testTarget = .screen
default: skipFixture("MONIVIEW_TEST_TARGET must be native, 2k, 4k, or screen (got \(targetName))")
}
let lowLatency: Bool
if let raw = environment["MONIVIEW_TEST_LOW_LATENCY"] {
    switch raw.lowercased() {
    case "1", "true", "on": lowLatency = true
    case "0", "false", "off": lowLatency = false
    default: skipFixture("MONIVIEW_TEST_LOW_LATENCY must be 0 or 1 (got \(raw))")
    }
} else {
    lowLatency = environment["MONIVIEW_TEST_UNCAPPED"] != "1"
}
let enhancementStrength = Double(environment["MONIVIEW_TEST_STRENGTH"] ?? "0") ?? .nan
if !(enhancementStrength.isFinite && (0...1).contains(enhancementStrength)) {
    skipFixture("MONIVIEW_TEST_STRENGTH must be between 0 and 1 (got \(environment["MONIVIEW_TEST_STRENGTH"] ?? "unset"))")
}
let requireMetalFX = environment["MONIVIEW_TEST_REQUIRE_METALFX"] == "1"
let testSpatialOverload = environment["MONIVIEW_TEST_SPATIAL_OVERLOAD"] == "1"
let testFullscreen = environment["MONIVIEW_TEST_FULLSCREEN"] == "1"
let testInterpolationMode: FrameInterpolationMode
if environment["MONIVIEW_TEST_FLOWBLEND"] == "1" {
    testInterpolationMode = .flowBlend
} else if environment["MONIVIEW_TEST_QUALITY"] == "1" {
    testInterpolationMode = .quality
} else if environment["MONIVIEW_TEST_BALANCED"] == "1" {
    testInterpolationMode = .balanced
} else {
    testInterpolationMode = .efficient
}
requireFixture(fps > 0 && width >= 640 && height >= 480,
               "MONIVIEW_TEST_FPS must be positive and MONIVIEW_TEST_WIDTH/HEIGHT at least 640x480 (got \(fps) FPS, \(width)x\(height))")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard testInterpolationMode == .flowBlend || FrameInterpolatorSupport.isSupported else { print("SKIP runtime interpolation unavailable (not a pass)"); exit(2) }
let frames = LatestVideoFrame()
let preview = CapturePreviewNSView(frames: frames)
preview.settings.enhancementEnabled = true
preview.settings.enhancementStrength = enhancementStrength
preview.settings.upscaleMethod = .metalFX
preview.settings.upscaleTarget = testTarget
preview.settings.lowLatency = lowLatency
preview.settings.frameInterpolation = testInterpolationMode
preview.settings.forceFrameInterpolation = environment["MONIVIEW_TEST_FORCE"] == "1"
preview.settings.skipsExactDuplicateInterpolation = followEnabled
preview.injectInterpolationOverBudget = testSpatialOverload
if testSpatialOverload {
    requireFixture(testTarget == .screen && preview.settings.forceFrameInterpolation &&
                   (testInterpolationMode == .quality || testInterpolationMode == .flowBlend),
                   "spatial overload probe requires Match Display, Force, and High or Flow Beta")
}
let originalInterpolationMode = preview.settings.frameInterpolation
let originalForceSetting = preview.settings.forceFrameInterpolation
let originalUpscaleMethod = preview.settings.upscaleMethod
let originalFollowSetting = preview.settings.skipsExactDuplicateInterpolation
// The color path runs before enhancing and is part of the real per-frame cost. The
// default fixture settings skip it entirely (all neutral), so a preset can be applied
// to measure the chain the shipped app actually runs.
if environment["MONIVIEW_TEST_VIVID"] == "1" {
    preview.settings.contrast = 1.025
    preview.settings.saturation = 1.07
    preview.settings.vibrance = 0.08
    preview.settings.highlightRecovery = 0.08
}
var events: [(sequence: UInt64, generated: Bool, time: Double)] = []
preview.onPresentation = { events.append(($0, $1, $2)) }
/// The endpoint of a pair reports the midpoint's presentation as its evidence. A fallback reason
/// stated after a midpoint and before that pair's already-scheduled endpoint must stay: the
/// endpoint is the source frame, so its later presentation is not evidence that the engine ran.
var endpointEvidenceSequence: UInt64?
var endpointEvidenceOutcome: (keptReason: Bool, caption: String)?
if testEndpointEvidence {
    preview.onPresentation = { sequence, generated, time in
        events.append((sequence, generated, time))
        if generated, endpointEvidenceSequence == nil {
            // Midpoint on screen: state the reason before the endpoint of this same pair presents.
            endpointEvidenceSequence = sequence
            frames.setInterpolationState("处理超预算，暂用原始帧率")
        } else if let injected = endpointEvidenceSequence, !generated, sequence == injected,
                  endpointEvidenceOutcome == nil {
            // Read the caption once this endpoint's handler has finished: its own call is what must
            // keep the reason instead of announcing running from the endpoint's time.
            DispatchQueue.main.async {
                guard endpointEvidenceOutcome == nil else { return }
                let caption = frames.currentInterpolationState()
                endpointEvidenceOutcome = (caption == "处理超预算，暂用原始帧率", caption)
            }
        }
    }
}
var recovered = false
var blankWasRetried = false
preview.onPresentationRecovery = { recovered = true }
preview.suppressPresentedCallbacks = fault
// The blank-failure probe suppresses only the clearing draw's presentation callback: its frame
// path stays healthy, so the layer is retired by the unconfirmed blank and not by a lost frame.
preview.suppressBlankPresentedCallbacks = testBlankFailure
// The drawable cost is dominated by the visible output size, so the window size is
// configurable: a 960x540 window is not representative of a near-fullscreen preview.
let testWindowWidth = Int(environment["MONIVIEW_TEST_WINDOW_WIDTH"] ?? "960") ?? 960
let testWindowHeight = Int(environment["MONIVIEW_TEST_WINDOW_HEIGHT"] ?? "540") ?? 540
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: testWindowWidth, height: testWindowHeight), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "MoniView — synthetic interpolation validation"
if testFullscreen {
    // This helper window must be the primary window in its own fullscreen Space.
    window.level = .normal
    window.collectionBehavior = [.fullScreenPrimary]
} else {
    // Keep the validation surface visible when the production app is in another
    // fullscreen Space; otherwise occlusion zeros are not throughput evidence.
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    if environment["MONIVIEW_TEST_WINDOW_ABOVE_ALL"] == "1" {
        // Another app holding a large window over the whole screen otherwise makes the
        // run inconclusive. This only raises the short-lived measurement window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    }
}
window.contentView = preview
var testFullscreenEntered = false
let fullscreenEnteredObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main
) { _ in testFullscreenEntered = true }
window.center(); window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
if require120, let boundScreen = window.screen, boundScreen.maximumFramesPerSecond < 120 {
    print("SKIP ineligible strict environment: attached display reports \(boundScreen.maximumFramesPerSecond) Hz; 120 Hz required; exit 2, not a pass")
    exit(2)
}
if testFollowSwitch && (window.screen?.maximumFramesPerSecond ?? 0) < 120 {
    print("SKIP ineligible Follow-switch environment: attached display reports \(window.screen?.maximumFramesPerSecond ?? 0) Hz; 120 Hz required; exit 2, not a pass")
    exit(2)
}
if testFullscreen {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}
preview.configureInterpolation()
print("Display maximum \(window.screen?.maximumFramesPerSecond ?? 0) Hz; synthetic \(width)x\(height) @ \(fps) FPS")
print("Fixture config: target=\(testTarget.rawValue) lowLatency=\(lowLatency) strength=\(String(format: "%.2f", enhancementStrength)) spatial=MetalFX interpolation=\(preview.settings.frameInterpolation.rawValue) force=\(preview.settings.forceFrameInterpolation) follow=\(followEnabled) repeat=\(repeatDivisor) fullscreenTest=\(testFullscreen)")
var sequence: Int64 = 0
let input = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "synthetic.capture"))
input.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
input.setEventHandler {
    var buffer: CVPixelBuffer?
    let attrs: [String:Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String:true]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { skipFixture("input buffer allocation failed") }
    if environment["MONIVIEW_TEST_METADATA"] != "missing" {
        for (key, value) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2), (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2), (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        // This synthetic source has uniform neutral chroma, constructed at Center.
        // Product capture never invents this attachment for an unknown device.
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!, plane == 0 ? 96 : 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer,plane) * CVPixelBufferGetHeightOfPlane(buffer,plane))
    }
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
    // Repeat divisor selects the content rate inside the 60 Hz signal: 2 gives 30 FPS
    // content, 3 gives 20 FPS, which is the case the 3x path exists to fill.
    let repeatDivisor = Int(environment["MONIVIEW_TEST_REPEAT"] ?? (environment["MONIVIEW_TEST_DUPLICATES"] == "1" ? "2" : "1")) ?? 1
    let motionSequence = repeatDivisor > 1 ? sequence / Int64(repeatDivisor) : sequence
    let offset = Int(motionSequence * 8) % (width - 160)
    for h in (height / 3)..<(height * 2 / 3) { memset(y + h * row + offset, 220, 160) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    frames.put(buffer, pts: CMTime(value: sequence, timescale: CMTimeScale(fps)))
    sequence += 1
}
input.resume()
if fault {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        preview.settings.frameInterpolation = .off
        preview.configureInterpolation()
        // Turning interpolation off must clear the readout at once, not after the window.
        requireFixture(frames.currentInterpolationActivity() == nil, "disabling interpolation clears the readout immediately")
        input.cancel() // no display-link or future input may rescue a lost callback
        if environment["MONIVIEW_TEST_CLEAR_INPUT"] == "1" { frames.clear() }
        preview.requestRender()
    }
}
var tick = 0, total = 0, steady = 0, eventOffset = 0, strictWindows = 0, totalDuplicateSkips = 0
var strictSampleWindows = 0, strictSourceFrames = 0, strictGeneratedFrames = 0
var strictElapsed = 0.0, previousStatsTime: Double?, strictMetalFXObserved = false
var cadWindowCounts: [Int] = [], strictCADWindowCounts: [Int] = [], cadElapsed = 0.0
var strictEnvironmentFailure: String?
var cadenceWindows = 0, cadencePassWindows = 0
var cadenceSources = 0, cadenceGenerated = 0
var cadenceElapsed = 0.0
var spatialTargetSamples = 0
var activitySamples = 0, missingActivitySamples = 0, mismatchedActivitySamples = 0
let activityProbe = DispatchSource.makeTimerSource(queue: .main)
activityProbe.schedule(deadline: .now() + 0.05, repeating: 0.05)
activityProbe.setEventHandler {
    guard requireCadence, (6...11).contains(tick) else { return }
    activitySamples += 1
    guard let activity = frames.currentInterpolationActivity() else {
        missingActivitySamples += 1
        return
    }
    // The readout exists to name the published pair, and its step follows the content
    // estimate. In the 2x regime that estimate settles inside the window, so the value
    // must match from tick 9 on. Low-rate 3x content keeps re-estimating while the
    // three-phase queue fills, so there only the presence of a pair is asserted here;
    // the 3x step itself is covered by the phase-structure checks below.
    if tick >= 9, expectedMultiplier <= 2,
       abs(activity.multiplier - expectedMultiplier) > 0.001 || abs(activity.basisFPS - expectedContentFPS) > 0.5 {
        mismatchedActivitySamples += 1
        print("activity mismatch tick=\(tick) multiplier=\(activity.multiplier) basis=\(activity.basisFPS) expected=\(expectedMultiplier)/\(expectedContentFPS)")
    }
}
activityProbe.resume()
var restartGenerated = 0, restartSources = 0, restartWindows = 0, restartPassWindows = 0
var restartElapsed = 0.0
var restartCaptionWindows = 0
var restartCaptionContradictions: [String] = []
var cadenceEvents: [(sequence: UInt64, generated: Bool, time: Double)] = []
var restartEvents: [(sequence: UInt64, generated: Bool, time: Double)] = []
var stableEvents: [(sequence: UInt64, generated: Bool, time: Double)] = []
var followSwitchEngine = ""
var followSwitchSampleTicks: [Int] = []
var countedSources = Set<UInt64>()
func validateCadencePresentations(_ samples: [(sequence: UInt64, generated: Bool, time: Double)], multiplier: Int) {
    let ordered = samples.sorted { $0.time < $1.time }
    let intervals = zip(ordered, ordered.dropFirst()).map { $1.time - $0.time }.filter { $0 > 0 }.sorted()
    requireFixture(!intervals.isEmpty, "no presentation spacing samples")
    let slot = 1 / (expectedContentFPS * Double(multiplier))
    let p95 = intervals[min(intervals.count - 1, Int(ceil(Double(intervals.count) * 0.95)) - 1)]
    let intervalTolerance = testInterpolationMode == .quality ? 1.35 : 1.6
    requireFixture(p95 <= slot * intervalTolerance + 0.001, "presentation spacing is not consistent with target output")
    // Each completed sequence needs the requested number of distinct generated presentations
    // before its source endpoint; a lone midpoint cannot pass the third-phase acceptance.
    var completePairs = 0
    for group in Dictionary(grouping: ordered, by: { $0.sequence }).values {
        let sequenceEvents = group.sorted { $0.time < $1.time }
        guard let endpoint = sequenceEvents.first(where: { !$0.generated }) else { continue }
        let midpoints = sequenceEvents.filter { $0.generated && $0.time < endpoint.time }
        if midpoints.count == multiplier - 1 { completePairs += 1 }
    }
    requireFixture(completePairs >= Int(Double(samples.count) / Double(multiplier) * 0.8),
                 "too few completed pairs contain every generated phase before the endpoint")
    print("PASS \(multiplier)x presentation structure: complete pairs=\(completePairs), interval P95=\(p95 * 1000) ms")
}
let strictOcclusionObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
) { _ in
    // Tick 6 consumes the interval since tick 5; tick 35 closes the last strict interval.
    guard require120, tick >= 5, tick < stopAt - 1 else { return }
    let visible = window.isVisible
    let miniaturized = window.isMiniaturized
    let unoccluded = window.occlusionState.contains(.visible)
    if !visible || miniaturized || !unoccluded {
        strictEnvironmentFailure = "occlusion changed (isVisible=\(visible), miniaturized=\(miniaturized), occlusionVisible=\(unoccluded))"
    }
}
let strictMiniaturizeObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.willMiniaturizeNotification, object: window, queue: .main
) { _ in
    if require120, tick >= 5, tick < stopAt - 1 { strictEnvironmentFailure = "window began minimizing" }
}
let strictCloseObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.willCloseNotification, object: window, queue: .main
) { _ in
    if require120, tick >= 5, tick < stopAt - 1 { strictEnvironmentFailure = "window began closing" }
}
let strictScreenParametersObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    guard require120, tick >= 5, tick < stopAt else { return }
    guard let changedScreen = window.screen else {
        strictEnvironmentFailure = "strict window lost its screen association during sampling"
        return
    }
    if changedScreen.maximumFramesPerSecond < 120 {
        strictEnvironmentFailure = "strict display maximum fell to \(changedScreen.maximumFramesPerSecond) Hz during sampling (120 Hz required)"
    }
}
let stats = DispatchSource.makeTimerSource(queue: .main)
stats.schedule(deadline:.now()+1, repeating:1)
stats.setEventHandler {
    let sampleTime = CACurrentMediaTime()
    tick += 1
    if requireCadence, (6...12).contains(tick) || (testRestart && (21...25).contains(tick)) {
        guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else {
            print("SKIP 2x/restart acceptance: fixture is not visible; exit 2, not a pass")
            input.cancel(); stats.cancel(); exit(2)
        }
    }
    // Tick 5 samples eligibility for the tick 5→6 interval counted by strict stats.
    // The smoke test's own minimize/restore at ticks 13/14 runs only when require120 is false.
    if require120, tick >= 5, tick < stopAt {
        guard let sampleScreen = window.screen else {
            strictEnvironmentFailure = "strict window is not bound to a screen at tick \(tick)"
            print("SKIP inconclusive: \(strictEnvironmentFailure!); exit 2, not a pass")
            input.cancel()
            stats.cancel()
            exit(2)
        }
        if sampleScreen.maximumFramesPerSecond < 120 {
            strictEnvironmentFailure = "strict display maximum fell to \(sampleScreen.maximumFramesPerSecond) Hz at tick \(tick) (120 Hz required)"
        }
        if testFullscreen && !testFullscreenEntered {
            strictEnvironmentFailure = "fixture full-screen transition did not complete before strict sampling"
        }
        let isVisible = window.isVisible
        let isMiniaturized = window.isMiniaturized
        let isUnoccluded = window.occlusionState.contains(.visible)
        if !isVisible || isMiniaturized || !isUnoccluded {
            strictEnvironmentFailure = "window not visible at tick \(tick) (isVisible=\(isVisible), miniaturized=\(isMiniaturized), occlusionVisible=\(isUnoccluded))"
        }
        if let strictEnvironmentFailure {
            print("SKIP inconclusive: \(strictEnvironmentFailure); exit 2, not a pass")
            input.cancel()
            stats.cancel()
            exit(2)
        }
    }
    let cadWindowStart = previousStatsTime ?? (sampleTime - 1)
    let cadWindowDuration = max(0, sampleTime - cadWindowStart)
    let newCADCount = preview.displayTickTimes.reduce(into: 0) { count, time in
        if time > cadWindowStart && time <= sampleTime { count += 1 }
    }
    cadWindowCounts.append(newCADCount)
    cadElapsed += cadWindowDuration
    let counts = frames.statistics(), presented = frames.presentationStatistics(), cost = frames.interpolationCost()
    let gen = presented.generated
    if testSpatialOverload, (6...12).contains(tick) {
        guard window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
              let screen = window.screen else { skipFixture("spatial overload probe window is not visible") }
        let sourceLongEdge = Double(max(width, height))
        let displayScale = max(1, min(preview.drawableSize.width / Double(width), preview.drawableSize.height / Double(height)))
        let edge = testTarget.processingLongEdge(
            screenLongEdge: Double(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor),
            sourceLongEdge: sourceLongEdge, visibleLongEdge: sourceLongEdge * displayScale, lowLatency: lowLatency)
        guard edge / sourceLongEdge > 1.01 else { skipFixture("spatial overload probe needs a drawable larger than its source") }
        let scale = edge / sourceLongEdge
        let expectedSize = "\(Int((Double(width) * scale).rounded()))×\(Int((Double(height) * scale).rounded()))"
        requireFixture(frames.currentEngine() == "MetalFX" && frames.currentEnhancedSize() == expectedSize,
                       "interpolation overload silently reduced source-frame enhancement: expected \(expectedSize), got \(frames.currentEnhancedSize() ?? "native") / \(frames.currentEngine())")
        spatialTargetSamples += 1
    }
    if testSpatialOverload, tick == 12 {
        // An over-budget tier must demote its generated midpoint's spatial pass instead of
        // dropping pairs: the cheap path is what keeps the source cadence presentable.
        requireFixture(preview.testMidpointSpatialDemoted,
                       "over-budget midpoint never demoted its spatial pass")
        requireFixture(gen > 0, "demoted midpoint stopped generating frames")
    }
    let skippedDuplicates = frames.takeDuplicateSkips(); totalDuplicateSkips += skippedDuplicates
    if testInterpolationMode == .quality, let work = frames.currentInterpolationWorkingSize() {
        let expected = FrameInterpolationPolicy.targetDimensions(width: width, height: height, mode: .quality)!
        requireFixture(work == "\(expected.width)×\(expected.height)", "Clear silently reduced its working resolution")
    }
    if testInterpolationMode == .balanced, let work = frames.currentInterpolationWorkingSize() {
        let expected = FrameInterpolationPolicy.targetDimensions(width: width, height: height, mode: .balanced)!
        requireFixture(work == "\(expected.width)×\(expected.height)", "Medium silently reduced its working resolution")
    }
    let newEvents = events.dropFirst(eventOffset); eventOffset = events.count
    if requireForcedAttempts, tick >= 6, tick <= 12 {
        requireFixture(preview.settings.forceFrameInterpolation && gen > 0,
                       "successful forced processing repeatedly paused or lost deadline eligibility")
    }
    let sourcePresentations = newEvents.filter { !$0.generated && countedSources.insert($0.sequence).inserted }.count
    if requireCadence, tick >= 6, tick <= 12 {
        cadenceEvents.append(contentsOf: newEvents)
        cadenceWindows += 1
        cadenceSources += sourcePresentations; cadenceGenerated += gen
        cadenceElapsed += cadWindowDuration
        // Acceptance is against the interpolation target, not the content rate: a 20 FPS
        // source is expected to produce about 40 generated frames, and a gate that only
        // asked for 20 would pass a run where the third phase never happened.
        let expectedGenerated = expectedContentFPS * (expectedMultiplier - 1)
        if Double(gen) / cadWindowDuration >= expectedGenerated * 0.9 &&
           Double(sourcePresentations) / cadWindowDuration >= expectedContentFPS * 0.9 {
            cadencePassWindows += 1
        }
    }
    if require120, tick >= 6, tick < stopAt {
        stableEvents.append(contentsOf: newEvents)
        strictSampleWindows += 1
        strictSourceFrames += sourcePresentations
        strictGeneratedFrames += gen
        strictCADWindowCounts.append(newCADCount)
        strictElapsed += cadWindowDuration
        strictMetalFXObserved = strictMetalFXObserved || frames.currentEngine() == "MetalFX"
        if gen >= 57 && sourcePresentations >= 57 { strictWindows += 1 }
    }
    previousStatsTime = sampleTime
    total += gen
    if testRestart, tick >= 24, tick <= 29 {
        restartGenerated += gen; restartSources += sourcePresentations
        restartElapsed += cadWindowDuration; restartWindows += 1
        restartEvents.append(contentsOf: newEvents)
        let expectedGenerated = expectedContentFPS * (expectedMultiplier - 1)
        if Double(gen) / cadWindowDuration >= expectedGenerated * 0.9 &&
           Double(sourcePresentations) / cadWindowDuration >= expectedContentFPS * 0.9 {
            restartPassWindows += 1
        }
        // The caption is judged by current evidence, not by how many frames moved: a window that
        // presented source frames only can honestly report a preparation state, while a generated
        // frame that reached the display for this stream may not be described as still preparing.
        if let evidence = frames.recentGeneratedPresentationEvidence() {
            restartCaptionWindows += 1
            let caption = frames.currentInterpolationState()
            if caption.contains("准备中") {
                restartCaptionContradictions.append("tick=\(tick) state=\(caption) evidence=\(String(format: "%.3f", evidence)) source=\(sourcePresentations) generated=\(gen)")
            }
        }
    }
    if Double(gen) >= expectedContentFPS * 0.85 { steady += 1 }
    // Count source presentations independently from renderer statistics. The pair
    // shares the same sampling boundary, including native fallback and redraws.
    requireFixture(presented.presentedSource == sourcePresentations, "output statistics differ from drawable presentation callbacks")
    print("tick=\(tick) newCADcount=\(newCADCount) window=\(String(format: "%.3f", cadWindowDuration))s capture=\(counts.0) GPU-source=\(counts.1) actual-source=\(sourcePresentations) presented-generated=\(gen) output=\(presented.presentedSource + gen) engine=\(frames.currentEngine()) spatial=\(frames.currentEnhancedSize() ?? "native") work=\(frames.currentInterpolationWorkingSize() ?? "—") pairP95=\(String(format: "%.2f",cost.0))ms pairBudget=\(String(format: "%.2f",cost.1))ms state=\(frames.currentInterpolationState()) display=\(window.screen?.maximumFramesPerSecond ?? 0)Hz observed=\(Int(frames.currentDisplayRates().observed.rounded()))")
    if testFollowSwitch && (tick == 18 || tick == 19) {
        let basis = frames.currentInterpolationBasisFPS()
        let multiplier = frames.currentActiveMultiplier()
        let engine = frames.currentEngine()
        followSwitchSampleTicks.append(tick)
        print("follow-switch tick=\(tick) generated=\(gen) basisFPS=\(basis.map { String(format: "%.2f", $0) } ?? "nil") multiplier=\(multiplier.map { String(format: "%.2f", $0) } ?? "nil") engine=\(engine)")
        requireFixture(gen > 0, "Follow-switch generation did not resume by tick \(tick)")
        requireFixture(abs((basis ?? .nan) - 60) < 0.5 && abs((multiplier ?? .nan) - 2) < 0.001,
                     "Follow-switch retained a stale content-rate basis or multiplier at tick \(tick)")
        requireFixture(preview.settings.frameInterpolation == originalInterpolationMode &&
                     preview.settings.forceFrameInterpolation == originalForceSetting &&
                     preview.settings.upscaleMethod == originalUpscaleMethod && engine == followSwitchEngine,
                     "Follow-switch changed the original interpolation or spatial engine")
    }
    if fault && tick == 2 {
        requireFixture(recovered && preview.peakOutstandingPresentations <= presentationLimit, "lost callbacks did not retire old preview")
        print("PASS injected presentation-callback loss: old layer retired without recycling outstanding tokens")
        input.cancel(); stats.cancel(); activityProbe.cancel(); app.terminate(nil); return
    }
    if testBlankFailure, tick == 2 {
        // Stop the synthetic input first so the pipeline is quiet before the clear: an in-flight
        // frame callback would otherwise be dropped by the epoch change and distort the drawable
        // accounting this fixture also checks. Interpolation goes off as well, which removes the
        // display link: the blank's own deadline must be the only thing that retries it.
        input.cancel()
        preview.settings.frameInterpolation = .off
        preview.configureInterpolation()
        preview.requestRender()
    }
    if testBlankFailure, tick == 3 {
        // A source switch clears the mailbox and asks for a blank, but in this mode the clearing
        // draw's presentation callback never arrives. No frames remain, so nothing can supersede
        // the blank: it must be retried from its own deadline (the display link is not the only
        // way out) and, after the attempt limit, retire the layer instead of leaving the previous
        // picture on screen.
        recovered = false
        frames.clear(blankPreview: true)
        preview.requestRender()
    }
    if testBlankFailure, tick > 3 {
        if frames.isBlankRequestPending || frames.currentInterpolationState() == "呈现中断，重建预览" {
            blankWasRetried = true
        }
        if tick >= 5 {
            requireFixture(blankWasRetried, "a blank whose presentation callback was lost was never retried")
            requireFixture(recovered, "a blank that never presented did not retire the layer")
            requireFixture(frames.currentInterpolationState() == "呈现中断，重建预览",
                           "retiring the layer for an unconfirmed blank left a stale caption: \(frames.currentInterpolationState())")
            print("PASS injected blank-presentation loss: retried from its own deadline and retired after the attempt limit")
            input.cancel(); stats.cancel(); activityProbe.cancel(); app.terminate(nil); return
        }
    }
    if testEndpointEvidence, tick >= 3 {
        guard let outcome = endpointEvidenceOutcome else {
            print("SKIP endpoint-evidence probe: no complete pair presented its endpoint")
            input.cancel(); stats.cancel(); activityProbe.cancel(); exit(2)
        }
        requireFixture(outcome.keptReason,
                     "the endpoint of a pair re-announced running from its own time: \(outcome.caption)")
        print("PASS endpoint evidence: a fallback reason stated after the midpoint survived the pair's endpoint presentation")
        input.cancel(); stats.cancel(); activityProbe.cancel(); app.terminate(nil); return
    }
    if tick == 8 && !testFollowSwitch && !require120 && !requireCadence && testInterpolationMode != .flowBlend && environment["MONIVIEW_TEST_KEEP_EFFICIENT"] != "1" { preview.settings.interpolationMode = .quality; preview.configureInterpolation(); preview.requestRender() }
    if tick == 13 && !testFollowSwitch && !require120 { window.miniaturize(nil) }
    if tick == 14 && !testFollowSwitch && !require120 { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
    if tick == stopAt && !testFollowSwitch {
        if testEngineSwitch {
            preview.settings.frameInterpolation = .quality
            preview.configureInterpolation(); preview.requestRender()
            // The engine switch invalidates the evidence the previous engine recorded: the new
            // engine has not presented anything yet.
            requireFixture(frames.recentGeneratedPresentationEvidence() == nil,
                         "an engine switch kept the previous engine's evidence")
        } else {
            // A steady run must clear the published pair at once, not after the window.
            let hadActivity = frames.currentInterpolationActivity() != nil
            preview.settings.frameInterpolation = .off
            preview.configureInterpolation()
            requireFixture(!hadActivity || frames.currentInterpolationActivity() == nil,
                         "disabling interpolation clears the readout immediately")
            preview.requestRender()
        }
    }
    if testFollowSwitch && tick == 16 {
        requireFixture(originalFollowSetting && preview.settings.frameInterpolation == originalInterpolationMode &&
                     preview.settings.forceFrameInterpolation == originalForceSetting &&
                     preview.settings.upscaleMethod == originalUpscaleMethod,
                     "Follow-switch did not start from the expected enabled state")
        followSwitchEngine = frames.currentEngine()
        preview.settings.skipsExactDuplicateInterpolation = false
        preview.configureInterpolation(); preview.requestRender()
        requireFixture(preview.settings.frameInterpolation == originalInterpolationMode &&
                     preview.settings.forceFrameInterpolation == originalForceSetting &&
                     preview.settings.upscaleMethod == originalUpscaleMethod,
                     "Follow toggle changed interpolation or spatial engine settings")
    }
    if testFollowSwitch && tick == 20 {
        preview.settings.skipsExactDuplicateInterpolation = originalFollowSetting
        preview.configureInterpolation(); preview.requestRender()
    }
    if testFollowSwitch && tick == 21 {
        requireFixture(preview.settings.skipsExactDuplicateInterpolation == originalFollowSetting &&
                     preview.settings.frameInterpolation == originalInterpolationMode &&
                     preview.settings.forceFrameInterpolation == originalForceSetting &&
                     preview.settings.upscaleMethod == originalUpscaleMethod &&
                     frames.currentEngine() == followSwitchEngine,
                     "Follow-switch did not restore the original state and engine")
        preview.settings.frameInterpolation = .off
        preview.configureInterpolation(); preview.requestRender()
    }
    if testRestart && tick == 20 {
        preview.settings.frameInterpolation = testInterpolationMode
        preview.configureInterpolation(); preview.requestRender()
    }
    if testRestart && tick == 30 {
        preview.settings.frameInterpolation = .off
        preview.configureInterpolation(); preview.requestRender()
        // Switching the engine off must invalidate the evidence the previous configuration
        // recorded; nothing generated has presented for the disabled one.
        requireFixture(frames.recentGeneratedPresentationEvidence() == nil,
                     "switching the engine off kept the previous configuration's evidence")
    }
    if testRestart, tick > 30, tick < finishAt {
        // Reverse direction: a success callback from the generation that was switched off may
        // still arrive, and it must not label the disabled engine as running.
        let caption = frames.currentInterpolationState()
        requireFixture(!caption.contains("运行中"),
                     "a superseded generation labelled the disabled engine as running: tick=\(tick) state=\(caption)")
        requireFixture(frames.recentGeneratedPresentationEvidence() == nil,
                     "a superseded generation left presentation evidence behind: tick=\(tick)")
    }
    if tick == finishAt {
        if requireCadence {
            print("recent interpolation activity: \(activitySamples) samples at 20Hz, missing \(missingActivitySamples), mismatched \(mismatchedActivitySamples), expected \(expectedMultiplier)x/\(expectedContentFPS) FPS")
            requireFixture(activitySamples >= 100 && missingActivitySamples == 0 && mismatchedActivitySamples == 0,
                         "recent pair readout flickered or changed step during steady interpolation")
        }
        if testRestart {
            print("restart acceptance: windows \(restartPassWindows)/\(restartWindows), caption non-preparing \(restartCaptionWindows - restartCaptionContradictions.count)/\(restartCaptionWindows), source \(Double(restartSources) / restartElapsed) FPS, generated \(Double(restartGenerated) / restartElapsed) FPS, expected multiplier \(expectedMultiplier)")
            requireFixture(restartWindows == 6 && restartPassWindows >= 5,
                         "Interpolation did not restore its target throughput after stop/start")
            requireFixture(restartCaptionContradictions.isEmpty,
                         "restart caption kept claiming preparation while pairs presented: \(restartCaptionContradictions.joined(separator: "; "))")
            validateCadencePresentations(restartEvents, multiplier: Int(expectedMultiplier))
            print("PASS stop/start: target generated rate, source rate, pair structure and spacing restored")
        }
        if requireCadence {
            print("2x acceptance: windows \(cadencePassWindows)/\(cadenceWindows), source \(Double(cadenceSources) / cadenceElapsed) FPS, generated \(Double(cadenceGenerated) / cadenceElapsed) FPS, expected content \(expectedContentFPS) FPS")
            requireFixture(cadenceWindows == 7 && cadencePassWindows >= 6,
                         "2x content-cadence throughput failed; smoke success is not throughput acceptance")
            if followEnabled && repeatDivisor > 1 {
                requireFixture(Double(cadenceSources) / cadenceElapsed <= expectedContentFPS * 1.10,
                               "duplicate source presentations hid missing generated frames")
            }
            validateCadencePresentations(cadenceEvents, multiplier: Int(expectedMultiplier))
        }
        if followEnabled && repeatDivisor > 1 { requireFixture(totalDuplicateSkips > 0, "identical pairs were not skipped") }
        if testFollowSwitch {
            requireFixture(followSwitchSampleTicks == [18, 19], "Follow-switch did not record both recovery samples")
            requireFixture(originalFollowSetting && preview.settings.skipsExactDuplicateInterpolation == originalFollowSetting,
                         "Follow-switch failed to restore the initial Follow setting")
        }
        requireFixture(gen == 0 && !recovered, "disable/recovery failure")
        requireFixture(frames.currentInterpolationActivity() == nil, "disable leaves stale interpolation activity")
        requireFixture(preview.peakOutstandingPresentations <= presentationLimit, "unpresented drawable bound")
        if testInterpolationMode == .flowBlend {
            requireFixture(total > 0, "FlowBlend produced no generated frame actually presented")
        }
        let sorted = events.sorted { $0.time < $1.time }
        for (a,b) in zip(sorted, sorted.dropFirst()) {
            requireFixture(b.sequence >= a.sequence, "presentation went backwards")
        }
        let eligible = expectedContentFPS * 2 <= Double(window.screen?.maximumFramesPerSecond ?? 0)
        if eligible {
            if environment["MONIVIEW_ALLOW_BUDGET_FALLBACK"] != "1" { requireFixture(total > 0, "no generated frame actually presented") }
        } else { requireFixture(total == 0, "interpolation despite insufficient refresh") }
        let waits = preview.drawableWaitMS.sorted()
        if !waits.isEmpty { print("Drawable wait P95=\(waits[min(waits.count-1, Int(Double(waits.count)*0.95))])ms, max=\(waits.last!)ms") }
        let measuredCADCounts = require120 ? strictCADWindowCounts : cadWindowCounts
        let sortedCADCounts = measuredCADCounts.sorted()
        let cadCountTotal = measuredCADCounts.reduce(0, +)
        let cadCountMean = Double(cadCountTotal) / Double(max(1, measuredCADCounts.count))
        let cadP95Index = sortedCADCounts.isEmpty ? 0 : max(0, min(sortedCADCounts.count - 1, Int(ceil(Double(sortedCADCounts.count) * 0.95)) - 1))
        let cadCountP95 = sortedCADCounts.isEmpty ? 0 : sortedCADCounts[cadP95Index]
        let cadDuration = require120 ? strictElapsed : cadElapsed
        print("DisplayLink callback diagnostic (not screen FPS): callbacks=\(cadCountTotal), per-tick count mean=\(String(format: "%.2f", cadCountMean)), P95=\(cadCountP95), sampled=\(measuredCADCounts.count) windows/\(String(format: "%.3f", cadDuration))s")
        if require120 {
            requireFixture(fps == 60 && (window.screen?.maximumFramesPerSecond ?? 0) >= 120, "120 Hz environment required")
            if requireMetalFX { requireFixture(strictMetalFXObserved, "MetalFX spatial upscaler was not observed during strict windows") }
            let ordered = stableEvents.sorted { $0.time < $1.time }
            let intervals = zip(ordered, ordered.dropFirst()).map { $1.time - $0.time }.sorted()
            let mean = intervals.reduce(0,+) / Double(max(1,intervals.count))
            let p95Index = intervals.isEmpty ? 0 : max(0, min(intervals.count - 1, Int(ceil(Double(intervals.count) * 0.95)) - 1))
            let p95 = intervals.isEmpty ? 1 : intervals[p95Index]
            let measuredDuration = max(strictElapsed, .leastNonzeroMagnitude)
            let sourceFPS = Double(strictSourceFrames) / measuredDuration
            let generatedFPS = Double(strictGeneratedFrames) / measuredDuration
            print("120 acceptance: strict windows \(strictWindows)/30, actual mean interval \(mean*1000)ms, P95 \(p95*1000)ms, source FPS \(String(format: "%.2f", sourceFPS)), generated FPS \(String(format: "%.2f", generatedFPS)), output FPS \(String(format: "%.2f", sourceFPS + generatedFPS)), sampled \(strictSampleWindows) windows/\(String(format: "%.3f", measuredDuration))s")
            requireFixture(strictWindows >= 27 && mean <= 0.0089 && p95 <= 0.0125, "sustained 60→120 acceptance failed")
        }
        if testSpatialOverload {
            requireFixture(spatialTargetSamples == 7 && preview.injectedOverBudgetCount > 0,
                           "spatial overload branch and all seven target-size samples must be exercised")
            print("PASS Match Display retained MetalFX target in all seven steady samples under \(preview.injectedOverBudgetCount) injected overloads; no target-FPS claim")
        }
        print("PASS source ordering, drawable bound, disable\(require120 ? ", strict 60→120 synthetic window" : ", minimize/restore smoke"); generated=\(total), >=85% target windows=\(steady). This does NOT certify quality, HDMI latency or real UVC.")
        input.cancel(); stats.cancel(); activityProbe.cancel(); app.terminate(nil)
    }
}
stats.resume()
app.run()
