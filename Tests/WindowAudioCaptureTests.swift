import AppKit
import AVFoundation
import CoreMedia
import Foundation

setbuf(stdout, nil)

final class AudioDeliveryCounter {
    private let lock = NSLock()
    private var deliveries = 0
    func record(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetNumSamples(sample) > 0 else { return }
        lock.lock(); deliveries += 1; lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return deliveries }
}

final class MovingAudioFixtureView: NSView {
    var position = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        NSColor.systemOrange.setFill()
        NSRect(x: position, y: 100, width: 80, height: 80).fill()
    }
}

func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func waitFor(_ name: String, timeout: Double = 10, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { pump(0.05) }
    precondition(condition(), name)
    print("PASS \(name)")
}

guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
    print("SKIP microphone authorization unavailable; no prompt or pass"); exit(2)
}
let audios = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
let requested = ProcessInfo.processInfo.environment["MONIVIEW_TEST_AUDIO_NAME"] ?? "Jemdo"
guard let audio = audios.first(where: { $0.localizedName.localizedCaseInsensitiveContains(requested) }) else {
    print("SKIP requested external audio device unavailable: \(requested)"); exit(2)
}
guard CGPreflightScreenCaptureAccess() else {
    print("SKIP screen recording authorization unavailable; no prompt or pass"); exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "MoniView window + external audio validation"
let view = MovingAudioFixtureView(frame: window.contentLayoutRect)
window.contentView = view
window.orderFrontRegardless()
let motion = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    view.position = (view.position + 5).truncatingRemainder(dividingBy: 540)
    view.display()
}
// This binary has its own process-name defaults domain, never dev.moniview.app.
let testDomain = ProcessInfo.processInfo.processName
precondition(Bundle.main.bundleIdentifier != "dev.moniview.app", "Use the independent fixture executable")
UserDefaults.standard.removePersistentDomain(forName: testDomain)
UserDefaults.standard.set(CaptureSourceKind.macWindow.rawValue, forKey: "source.kind")
UserDefaults.standard.set(window.windowNumber, forKey: "source.windowID")
UserDefaults.standard.set(audio.uniqueID, forKey: "audio.selection")
let manager = CaptureManager(supportedInterpolationQualities: [.flowBlend])
let counter = AudioDeliveryCounter()
manager.audioSampleObserverForTesting = { counter.record($0) }
// Mute the preview so the test does not play a game through the user's speakers.
// The recorded track must still receive the actual external-device samples.
manager.setMuted(true)
waitFor("saved external audio discovered on window-only startup") {
    manager.audioOptions.contains { $0.id == audio.uniqueID } &&
    manager.selectedAudioID == audio.uniqueID && manager.audioStatus == "实时监听中"
}
waitFor("window-only session running and delivering audio") {
    manager.session.isRunning && counter.count > 10
}
waitFor("window frames arrive through CaptureManager") {
    manager.frames.latest() != nil && manager.isRunning
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
manager.startRecording(to: output)
waitFor("window recording began") { manager.isRecording }
let selectedWindow = manager.selectedMacWindowID
let windowStartsBeforeRefresh = manager.windowCaptureStartCountForTesting
manager.refreshMacWindows()
pump(2.5)
precondition(manager.selectedMacWindowID == selectedWindow, "refresh must preserve the recorded window")
precondition(manager.windowCaptureStartCountForTesting == windowStartsBeforeRefresh,
             "refresh during recording must not restart the ScreenCaptureKit stream")
manager.stopRecording()
waitFor("window recording finalized", timeout: 15) { !manager.isRecording }
precondition(manager.recordingError == nil, manager.recordingError ?? "recording error")
precondition(FileManager.default.fileExists(atPath: output.path), "recording missing")
print("PASS recording finalized with external audio while preview muted; file \(output.path)")

if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
    let videos = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
    if let video = videos.first(where: { $0.localizedName.localizedCaseInsensitiveContains("Jemdo") }) {
        UserDefaults.standard.set(video.uniqueID, forKey: "device.lastVideo")
        manager.sourceKind = .device
        waitFor("switch to capture device preserves external audio") {
            !manager.formatOptions.isEmpty && manager.session.inputs.count == 2 && manager.audioStatus == "实时监听中"
        }
        let before = counter.count
        manager.sourceKind = .macWindow
        waitFor("switch back to window preserves external audio deliveries") {
            manager.session.inputs.count == 1 && manager.session.isRunning && counter.count > before + 10
        }
    } else { print("SKIP video-device roundtrip: Jemdo video unavailable") }
} else { print("SKIP video-device roundtrip: camera authorization unavailable") }

manager.selectAudioDevice(id: "invalid-fixture-device-id")
waitFor("failed audio selection restores running external input") {
    manager.selectedAudioID == audio.uniqueID && manager.session.isRunning && manager.statusMessage != nil
}
manager.selectAudioDevice(id: nil)
waitFor("audio off stops the empty capture session") {
    manager.session.inputs.isEmpty && !manager.session.isRunning && manager.audioStatus == "未连接音频"
}
pump(0.3)
let stopped = counter.count
pump(0.5)
precondition(counter.count == stopped, "audio continued while off")
let videoSequence = manager.frames.latest()?.1 ?? 0
pump(0.5)
precondition((manager.frames.latest()?.1 ?? 0) > videoSequence, "audio off stopped the window video stream")
manager.selectAudioDevice(id: audio.uniqueID)
waitFor("audio re-enable restarts delivery without changing the window") {
    manager.session.isRunning && counter.count > stopped + 10
}
manager.selectAudioDevice(id: nil)
waitFor("fixture audio teardown") { !manager.session.isRunning }
motion.invalidate()
window.orderOut(nil)
UserDefaults.standard.removePersistentDomain(forName: testDomain)
print("PASS real window-source audio lifecycle; delivery, mute independence and source roundtrip. File tracks are checked by the script.")
