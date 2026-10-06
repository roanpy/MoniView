import AppKit
import CoreImage
import CoreVideo
import CoreMedia
import Foundation
import Darwin

// Preserve the final acceptance measurements even when a precondition fails.
setbuf(stdout, nil)

// A native window and GPU with synthetic SDR input. This is not a capture-card,
// picture-quality, HDMI-latency or long-running throughput certification.
let environment = ProcessInfo.processInfo.environment
let fps = Int(environment["MONIVIEW_TEST_FPS"] ?? "30") ?? 30
let width = Int(environment["MONIVIEW_TEST_WIDTH"] ?? "1920") ?? 1920
let height = Int(environment["MONIVIEW_TEST_HEIGHT"] ?? "1080") ?? 1080
let presentationLimit = 3
let require120 = environment["MONIVIEW_REQUIRE_120"] == "1"
let requireCadence = environment["MONIVIEW_REQUIRE_2X"] == "1"
let expectedContentFPS = Double(fps) / (environment["MONIVIEW_TEST_DUPLICATES"] == "1" ? 2 : 1)
let stopAt = require120 ? 36 : 16
let testRestart = environment["MONIVIEW_TEST_RESTART"] == "1"
precondition(!testRestart || !require120, "Restart test uses the non-strict fixture")
let finishAt = testRestart ? 29 : stopAt + 3
let fault = environment["MONIVIEW_TEST_PRESENTATION_FAILURE"] == "1"
let targetName = (environment["MONIVIEW_TEST_TARGET"] ?? "native").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
let testTarget: UpscaleTarget
switch targetName {
case "native", "original", "原始": testTarget = .native
case "2k", "qhd": testTarget = .qhd
case "4k", "uhd": testTarget = .uhd
case "screen", "display", "屏幕": testTarget = .screen
default: fatalError("MONIVIEW_TEST_TARGET must be native, 2k, 4k, or screen (got \(targetName))")
}
let lowLatency: Bool
if let raw = environment["MONIVIEW_TEST_LOW_LATENCY"] {
    switch raw.lowercased() {
    case "1", "true", "on": lowLatency = true
    case "0", "false", "off": lowLatency = false
    default: fatalError("MONIVIEW_TEST_LOW_LATENCY must be 0 or 1 (got \(raw))")
    }
} else {
    lowLatency = environment["MONIVIEW_TEST_UNCAPPED"] != "1"
}
let enhancementStrength = Double(environment["MONIVIEW_TEST_STRENGTH"] ?? "0") ?? .nan
precondition(enhancementStrength.isFinite && (0...1).contains(enhancementStrength), "MONIVIEW_TEST_STRENGTH must be between 0 and 1")
let requireMetalFX = environment["MONIVIEW_TEST_REQUIRE_METALFX"] == "1"
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
precondition(fps > 0 && width >= 640 && height >= 480)
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
preview.settings.skipsExactDuplicateInterpolation = environment["MONIVIEW_TEST_DUPLICATES"] == "1"
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
var recovered = false
preview.onPresentationRecovery = { recovered = true }
preview.suppressPresentedCallbacks = fault
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
if testFullscreen {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}
preview.configureInterpolation()
print("Display maximum \(window.screen?.maximumFramesPerSecond ?? 0) Hz; synthetic \(width)x\(height) @ \(fps) FPS")
print("Fixture config: target=\(testTarget.rawValue) lowLatency=\(lowLatency) strength=\(String(format: "%.2f", enhancementStrength)) spatial=MetalFX interpolation=\(preview.settings.frameInterpolation.rawValue) force=\(preview.settings.forceFrameInterpolation) fullscreenTest=\(testFullscreen)")
var sequence: Int64 = 0
let input = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "synthetic.capture"))
input.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
input.setEventHandler {
    var buffer: CVPixelBuffer?
    let attrs: [String:Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String:true]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { fatalError("allocation") }
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
    let motionSequence = environment["MONIVIEW_TEST_DUPLICATES"] == "1" ? sequence / 2 : sequence
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
var restartGenerated = 0
var stableEvents: [(sequence: UInt64, generated: Bool, time: Double)] = []
var countedSources = Set<UInt64>()
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
    let skippedDuplicates = frames.takeDuplicateSkips(); totalDuplicateSkips += skippedDuplicates
    if testInterpolationMode == .quality, let work = frames.currentInterpolationWorkingSize() {
        let expected = FrameInterpolationPolicy.targetDimensions(width: width, height: height, mode: .quality)!
        precondition(work == "\(expected.width)×\(expected.height)", "Clear silently reduced its working resolution")
    }
    if testInterpolationMode == .balanced, let work = frames.currentInterpolationWorkingSize() {
        let expected = FrameInterpolationPolicy.targetDimensions(width: width, height: height, mode: .balanced)!
        precondition(work == "\(expected.width)×\(expected.height)", "Medium silently reduced its working resolution")
    }
    let newEvents = events.dropFirst(eventOffset); eventOffset = events.count
    let sourcePresentations = newEvents.filter { !$0.generated && countedSources.insert($0.sequence).inserted }.count
    if requireCadence, tick >= 6, tick <= 12 {
        cadenceWindows += 1
        cadenceSources += sourcePresentations; cadenceGenerated += gen
        cadenceElapsed += cadWindowDuration
        if Double(gen) / cadWindowDuration >= expectedContentFPS * 0.9 &&
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
    if testRestart, tick >= 21, tick <= 25 { restartGenerated += gen }
    if Double(gen) >= expectedContentFPS * 0.85 { steady += 1 }
    // Count source presentations independently from renderer statistics. The pair
    // shares the same sampling boundary, including native fallback and redraws.
    precondition(presented.presentedSource == sourcePresentations, "output statistics differ from drawable presentation callbacks")
    print("tick=\(tick) newCADcount=\(newCADCount) window=\(String(format: "%.3f", cadWindowDuration))s capture=\(counts.0) GPU-source=\(counts.1) actual-source=\(sourcePresentations) presented-generated=\(gen) output=\(presented.presentedSource + gen) engine=\(frames.currentEngine()) spatial=\(frames.currentEnhancedSize() ?? "native") work=\(frames.currentInterpolationWorkingSize() ?? "—") pairP95=\(String(format: "%.2f",cost.0))ms pairBudget=\(String(format: "%.2f",cost.1))ms state=\(frames.currentInterpolationState()) display=\(window.screen?.maximumFramesPerSecond ?? 0)Hz observed=\(Int(frames.currentDisplayRates().observed.rounded()))")
    if fault && tick == 2 {
        precondition(recovered && preview.peakOutstandingPresentations <= presentationLimit, "lost callbacks did not retire old preview")
        print("PASS injected presentation-callback loss: old layer retired without recycling outstanding tokens")
        input.cancel(); stats.cancel(); app.terminate(nil); return
    }
    if tick == 8 && !require120 && !requireCadence && testInterpolationMode != .flowBlend && environment["MONIVIEW_TEST_KEEP_EFFICIENT"] != "1" { preview.settings.interpolationMode = .quality; preview.configureInterpolation(); preview.requestRender() }
    if tick == 13 && !require120 { window.miniaturize(nil) }
    if tick == 14 && !require120 { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
    if tick == stopAt { preview.settings.frameInterpolation = .off; preview.configureInterpolation(); preview.requestRender() }
    if testRestart && tick == 20 {
        preview.settings.frameInterpolation = testInterpolationMode
        preview.configureInterpolation(); preview.requestRender()
    }
    if testRestart && tick == 26 {
        preview.settings.frameInterpolation = .off
        preview.configureInterpolation(); preview.requestRender()
    }
    if tick == finishAt {
        if testRestart {
            precondition(restartGenerated >= Int(expectedContentFPS * 4),
                         "Interpolation did not resume after stop/start")
            print("PASS stop/start: \(restartGenerated) generated presentations after re-enabling")
        }
        if requireCadence {
            print("2x acceptance: windows \(cadencePassWindows)/\(cadenceWindows), source \(Double(cadenceSources) / cadenceElapsed) FPS, generated \(Double(cadenceGenerated) / cadenceElapsed) FPS, expected content \(expectedContentFPS) FPS")
            precondition(cadenceWindows == 7 && cadencePassWindows >= 6,
                         "2x content-cadence throughput failed; smoke success is not throughput acceptance")
        }
        if environment["MONIVIEW_TEST_DUPLICATES"] == "1" { precondition(totalDuplicateSkips > 0, "identical pairs were not skipped") }
        precondition(gen == 0 && !recovered, "disable/recovery failure")
        precondition(preview.peakOutstandingPresentations <= presentationLimit, "unpresented drawable bound")
        if testInterpolationMode == .flowBlend {
            precondition(total > 0, "FlowBlend produced no generated frame actually presented")
        }
        let sorted = events.sorted { $0.time < $1.time }
        for (a,b) in zip(sorted, sorted.dropFirst()) {
            precondition(b.sequence >= a.sequence, "presentation went backwards")
        }
        let eligible = expectedContentFPS * 2 <= Double(window.screen?.maximumFramesPerSecond ?? 0)
        if eligible {
            if environment["MONIVIEW_ALLOW_BUDGET_FALLBACK"] != "1" { precondition(total > 0, "no generated frame actually presented") }
        } else { precondition(total == 0, "interpolation despite insufficient refresh") }
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
            precondition(fps == 60 && (window.screen?.maximumFramesPerSecond ?? 0) >= 120, "120 Hz environment required")
            if requireMetalFX { precondition(strictMetalFXObserved, "MetalFX spatial upscaler was not observed during strict windows") }
            let ordered = stableEvents.sorted { $0.time < $1.time }
            let intervals = zip(ordered, ordered.dropFirst()).map { $1.time - $0.time }.sorted()
            let mean = intervals.reduce(0,+) / Double(max(1,intervals.count))
            let p95Index = intervals.isEmpty ? 0 : max(0, min(intervals.count - 1, Int(ceil(Double(intervals.count) * 0.95)) - 1))
            let p95 = intervals.isEmpty ? 1 : intervals[p95Index]
            let measuredDuration = max(strictElapsed, .leastNonzeroMagnitude)
            let sourceFPS = Double(strictSourceFrames) / measuredDuration
            let generatedFPS = Double(strictGeneratedFrames) / measuredDuration
            print("120 acceptance: strict windows \(strictWindows)/30, actual mean interval \(mean*1000)ms, P95 \(p95*1000)ms, source FPS \(String(format: "%.2f", sourceFPS)), generated FPS \(String(format: "%.2f", generatedFPS)), output FPS \(String(format: "%.2f", sourceFPS + generatedFPS)), sampled \(strictSampleWindows) windows/\(String(format: "%.3f", measuredDuration))s")
            precondition(strictWindows >= 27 && mean <= 0.0089 && p95 <= 0.0125, "sustained 60→120 acceptance failed")
        }
        print("PASS source ordering, drawable bound, disable\(require120 ? ", strict 60→120 synthetic window" : ", minimize/restore smoke"); generated=\(total), >=85% target windows=\(steady). This does NOT certify quality, HDMI latency or real UVC.")
        input.cancel(); stats.cancel(); app.terminate(nil)
    }
}
stats.resume()
app.run()
