import AppKit
import CoreImage
import CoreVideo
import CoreMedia
import Foundation

// A native window and GPU with synthetic SDR input. This is not a capture-card,
// picture-quality, HDMI-latency or long-running throughput certification.
let environment = ProcessInfo.processInfo.environment
let fps = Int(environment["MONIVIEW_TEST_FPS"] ?? "30") ?? 30
let width = Int(environment["MONIVIEW_TEST_WIDTH"] ?? "1920") ?? 1920
let height = Int(environment["MONIVIEW_TEST_HEIGHT"] ?? "1080") ?? 1080
let presentationLimit = 3
let require120 = environment["MONIVIEW_REQUIRE_120"] == "1"
let stopAt = require120 ? 36 : 16
let finishAt = stopAt + 3
let fault = environment["MONIVIEW_TEST_PRESENTATION_FAILURE"] == "1"
precondition(fps > 0 && width >= 640 && height >= 480)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard FrameInterpolatorSupport.isSupported else { print("SKIP runtime interpolation unavailable (not a pass)"); exit(2) }
let frames = LatestVideoFrame()
let preview = CapturePreviewNSView(frames: frames)
preview.settings.enhancementEnabled = true
preview.settings.enhancementStrength = 0
preview.settings.upscaleTarget = UpscaleTarget(rawValue: environment["MONIVIEW_TEST_TARGET"] ?? "") ?? .native
preview.settings.lowLatency = environment["MONIVIEW_TEST_UNCAPPED"] != "1"
preview.settings.interpolationMode = .efficient
var events: [(sequence: UInt64, generated: Bool, time: Double)] = []
preview.onPresentation = { events.append(($0, $1, $2)) }
var recovered = false
preview.onPresentationRecovery = { recovered = true }
preview.suppressPresentedCallbacks = fault
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "MoniView — synthetic interpolation validation"
window.contentView = preview
window.center(); window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
preview.configureInterpolation()
print("Display maximum \(window.screen?.maximumFramesPerSecond ?? 0) Hz; synthetic \(width)x\(height) @ \(fps) FPS")
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
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!, plane == 0 ? 96 : 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer,plane) * CVPixelBufferGetHeightOfPlane(buffer,plane))
    }
    let y = CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
    let offset = Int(sequence * 8) % (width - 160)
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
var tick = 0, total = 0, steady = 0, eventOffset = 0, strictWindows = 0
var stableEvents: [(sequence: UInt64, generated: Bool, time: Double)] = []
let stats = DispatchSource.makeTimerSource(queue: .main)
stats.schedule(deadline:.now()+1, repeating:1)
stats.setEventHandler {
    tick += 1
    let counts = frames.statistics(), gen = frames.generatedStatistics(), cost = frames.interpolationCost()
    let newEvents = events.dropFirst(eventOffset); eventOffset = events.count
    let sourcePresentations = Set(newEvents.filter { !$0.generated }.map(\.sequence)).count
    if require120, tick >= 6, tick < stopAt {
        stableEvents.append(contentsOf: newEvents)
        if gen >= 57 && sourcePresentations >= 57 { strictWindows += 1 }
    }
    total += gen
    if gen >= Int(Double(fps) * 0.85) { steady += 1 }
    print("tick=\(tick) capture=\(counts.0) GPU-source=\(counts.1) actual-source=\(sourcePresentations) presented-generated=\(gen) work=\(frames.currentInterpolationWorkingSize() ?? "—") costP95=\(String(format: "%.2f",cost.0))ms slot=\(String(format: "%.2f",cost.1))ms state=\(frames.currentInterpolationState()) display=\(window.screen?.maximumFramesPerSecond ?? 0)Hz observed=\(Int(frames.currentDisplayRates().observed.rounded()))")
    if fault && tick == 2 {
        precondition(recovered && preview.peakOutstandingPresentations <= presentationLimit, "lost callbacks did not retire old preview")
        print("PASS injected presentation-callback loss: old layer retired without recycling outstanding tokens")
        input.cancel(); stats.cancel(); app.terminate(nil); return
    }
    if tick == 8 && !require120 && environment["MONIVIEW_TEST_KEEP_EFFICIENT"] != "1" { preview.settings.interpolationMode = .quality; preview.configureInterpolation(); preview.requestRender() }
    if tick == 13 && !require120 { window.miniaturize(nil) }
    if tick == 14 && !require120 { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil) }
    if tick == stopAt { preview.settings.frameInterpolation = .off; preview.configureInterpolation(); preview.requestRender() }
    if tick == finishAt {
        precondition(gen == 0 && !recovered, "disable/recovery failure")
        precondition(preview.peakOutstandingPresentations <= presentationLimit, "unpresented drawable bound")
        let sorted = events.sorted { $0.time < $1.time }
        for (a,b) in zip(sorted, sorted.dropFirst()) {
            precondition(b.sequence >= a.sequence, "presentation went backwards")
        }
        let eligible = fps * 2 <= (window.screen?.maximumFramesPerSecond ?? 0)
        if eligible { precondition(total > 0, "no generated frame actually presented") }
        else { precondition(total == 0, "interpolation despite insufficient refresh") }
        let waits = preview.drawableWaitMS.sorted()
        if !waits.isEmpty { print("Drawable wait P95=\(waits[min(waits.count-1, Int(Double(waits.count)*0.95))])ms, max=\(waits.last!)ms") }
        if require120 {
            precondition(fps == 60 && (window.screen?.maximumFramesPerSecond ?? 0) >= 120, "120 Hz environment required")
            let ordered = stableEvents.sorted { $0.time < $1.time }
            let intervals = zip(ordered, ordered.dropFirst()).map { $1.time - $0.time }.sorted()
            let mean = intervals.reduce(0,+) / Double(max(1,intervals.count))
            let p95 = intervals.isEmpty ? 1 : intervals[min(intervals.count-1, Int(Double(intervals.count)*0.95))]
            print("120 acceptance: strict windows \(strictWindows)/30, actual mean interval \(mean*1000)ms, P95 \(p95*1000)ms")
            precondition(strictWindows >= 27 && mean <= 0.0089 && p95 <= 0.0125, "sustained 60→120 acceptance failed")
        }
        print("PASS source ordering, drawable bound, disable\(require120 ? ", strict 60→120 synthetic window" : ", minimize/restore smoke"); generated=\(total), >=85% target windows=\(steady). This does NOT certify quality, HDMI latency or real UVC.")
        input.cancel(); stats.cancel(); app.terminate(nil)
    }
}
stats.resume()
app.run()
