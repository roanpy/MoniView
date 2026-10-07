import AppKit
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

// Preserve progress even when a precondition fails later.
setbuf(stdout, nil)

// A real ScreenCaptureKit session against synthetic windows. This is not a game,
// quality or latency certification: it proves the source adapter delivers frames,
// maps unchanged content to dropped samples, and can stop and restart.

private final class Counter {
    private let lock = NSLock()
    private var frames: [Double] = []
    private var sizes = Set<String>()
    private var formats = Set<UInt32>()
    private var dropped = 0
    private var statusCounts: [String: Int] = [:]
    private var signatures: [UInt64] = []
    private var generations = Set<UInt64>()
    private var rejectedDeliveries = 0
    private(set) var states: [MacWindowCapture.State] = []
    private var stateObservations: [(reported: MacWindowCapture.State,
                                     captureState: MacWindowCapture.State?,
                                     configuredSize: CGSize,
                                     deliveredFrames: Int)] = []
    weak var capture: MacWindowCapture?

    func record(sample: CMSampleBuffer, generation: UInt64, accepted: Bool) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        lock.lock()
        if pts.isFinite { frames.append(pts) }
        sizes.insert("\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
        formats.insert(CVPixelBufferGetPixelFormatType(buffer))
        signatures.append(signature(of: buffer))
        generations.insert(generation)
        if !accepted { rejectedDeliveries += 1 }
        lock.unlock()
    }
    /// Stream generations that delivered frames, and how many deliveries the adapter itself
    /// rejected at hand-over time.
    var deliveryGenerations: (generations: Set<UInt64>, rejected: Int) {
        lock.lock(); defer { lock.unlock() }
        return (generations, rejectedDeliveries)
    }

    /// Sampled content signature. Two frames of unchanged content must match, which is
    /// what the duplicate detector relies on.
    private func signature(of buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        let stride = max(1, bytes / 4096)
        var hash: UInt64 = 1469598103934665603
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        var index = 0
        while index < bytes {
            hash = (hash ^ UInt64(pointer[index])) &* 1099511628211
            index += stride
        }
        return hash
    }

    var distinctSignatures: Int { lock.lock(); defer { lock.unlock() }; return Set(signatures).count }
    var signatureCount: Int { lock.lock(); defer { lock.unlock() }; return signatures.count }
    /// Signatures over the last `count` frames. A window that finished appearing must
    /// settle into one repeating picture; this is what duplicate detection compares.
    func steadySignatures(last count: Int = 20) -> Set<UInt64> {
        lock.lock(); defer { lock.unlock() }
        return Set(signatures.suffix(count))
    }
    func recordDrop() { lock.lock(); dropped += 1; lock.unlock() }

    func recordStatus(_ name: String) { lock.lock(); statusCounts[name, default: 0] += 1; lock.unlock() }

    var statuses: [String: Int] { lock.lock(); defer { lock.unlock() }; return statusCounts }

    func recordState(_ state: MacWindowCapture.State) {
        let captureState = capture?.state
        let configuredSize = capture?.configuredPixelSize ?? .zero
        lock.lock()
        states.append(state)
        stateObservations.append((state, captureState, configuredSize, frames.count))
        lock.unlock()
    }

    var runningStateObservation: (captureState: MacWindowCapture.State?, configuredSize: CGSize, deliveredFrames: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let observation = stateObservations.first(where: { $0.reported == .running }) else { return nil }
        return (observation.captureState, observation.configuredSize, observation.deliveredFrames)
    }

    var snapshot: (count: Int, dropped: Int, sizes: Set<String>, formats: Set<UInt32>, states: [MacWindowCapture.State], increasing: Bool) {
        lock.lock(); defer { lock.unlock() }
        let increasing = zip(frames, frames.dropFirst()).allSatisfy { $0 < $1 }
        return (frames.count, dropped, sizes, formats, states, increasing)
    }

    func reset() {
        lock.lock(); frames.removeAll(); sizes.removeAll(); formats.removeAll(); signatures.removeAll(); dropped = 0; lock.unlock()
    }
}

private func fourCC(_ value: UInt32) -> String {
    String(bytes: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)], encoding: .ascii) ?? "?"
}

/// Pump the main run loop while an async operation completes. The capture adapter
/// publishes state on the main queue, so a plain semaphore wait would deadlock it.
private func runBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>?
    Task {
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let result else { throw MacWindowCaptureError.startFailed("no result") }
    return try result.get()
}

private func pump(_ seconds: Double) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

private final class AnimatedView: NSView {
    var phase: Double = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let travel = max(1, bounds.width - 120)
        let x = (sin(phase) * 0.5 + 0.5) * travel
        NSColor.systemOrange.setFill()
        NSRect(x: x, y: bounds.midY - 60, width: 120, height: 120).fill()
    }
}

enum MacWindowCaptureTests {
    static var checks = 0

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        checks += 1
    }

    static func makeWindow(animated: Bool, title: String, origin: NSPoint = NSPoint(x: 80, y: 80)) -> (NSWindow, Timer?) {
        let contentRect = NSRect(x: origin.x, y: origin.y, width: 800, height: 500)
        let window = NSWindow(contentRect: contentRect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let view = AnimatedView(frame: window.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.title = title
        window.orderFrontRegardless()
        guard animated else {
            view.phase = 0
            return (window, nil)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            view.phase += 0.25
            view.setNeedsDisplay(view.bounds)
            view.displayIfNeeded()
        }
        RunLoop.current.add(timer, forMode: .common)
        return (window, timer)
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let (animated, timer) = makeWindow(animated: true, title: "MoniView capture test")
        pump(0.5)
        let expectedFrameWidth = Int(animated.frame.width)
        let expectedFrameHeight = Int(animated.frame.height)
        let backingScale = max(1, animated.screen?.backingScaleFactor ?? 1)
        let expectedPixelWidth = max(2, Int((animated.frame.width * backingScale).rounded(.down)) & ~1)
        let expectedPixelHeight = max(2, Int((animated.frame.height * backingScale).rounded(.down)) & ~1)
        check(expectedFrameWidth >= 160 && expectedFrameHeight >= 120, "Synthetic window is a valid capture size")

        // Discovery includes this process's window and reports its frame size.
        let options = try! runBlocking { try await MacWindowCapture.availableWindows(excludingBundleID: nil) }
        let option = options.first { $0.id == UInt32(animated.windowNumber) }
        check(options.contains { $0.id == UInt32(animated.windowNumber) }, "Discovery lists the synthetic window")
        check(option?.width == expectedFrameWidth && option?.height == expectedFrameHeight, "Discovery reports the window frame size")

        // Exclusion drops an owner's windows when its bundle identifier is passed.
        if let other = options.first(where: { $0.applicationName != "" }),
           let owner = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == other.applicationName }),
           let bundleID = owner.bundleIdentifier {
            let excluded = try! runBlocking { try await MacWindowCapture.availableWindows(excludingBundleID: bundleID) }
            check(!excluded.contains { $0.applicationName == other.applicationName }, "Excluding a bundle identifier removes its windows")
        }

        // System chrome owns the desktop picture and the window manager's own surfaces. They
        // pass every other filter, so they must be excluded explicitly: selecting one leaves
        // the previous source on screen with a readout that claims a running capture.
        check(MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: "com.apple.WindowManager") &&
              MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: "com.apple.dock") &&
              !MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: "com.example.game") &&
              !MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: nil),
              "System chrome is identified by its owning process, and only by that")
        let shareable = try! runBlocking { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        let chromeIDs = Set(shareable.windows.filter { window in
            window.frame.width >= 160 && window.frame.height >= 120 &&
                !(window.owningApplication?.applicationName ?? "").isEmpty &&
                MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: window.owningApplication?.bundleIdentifier)
        }.map { $0.windowID })
        print("System chrome windows present on screen: \(chromeIDs.count)")
        check(options.allSatisfy { !chromeIDs.contains($0.id) }, "Discovery offers no system chrome window as a source")

        // Animated source: frames arrive at the configured size in BGRA with increasing PTS.
        let counter = Counter()
        let capture = MacWindowCapture(
            frameSink: { sample, generation, source in
                counter.record(sample: sample, generation: generation,
                               accepted: source.acceptsFrame(generation: generation))
            },
            state: { counter.recordState($0) },
            dropped: { counter.recordDrop() })
        counter.capture = capture
        capture.start(windowID: UInt32(animated.windowNumber))
        pump(3.0)
        let animatedStats = counter.snapshot
        print("Animated window: frames=\(animatedStats.count) size=\(animatedStats.sizes.first ?? "-") format=\(animatedStats.formats.map { fourCC($0) }.first ?? "-") increasing=\(animatedStats.increasing)")
        check(animatedStats.states.contains(.running), "Animated capture reaches the running state")
        check(animatedStats.count > 100, "Animated capture delivers frames (got \(animatedStats.count))")
        check(animatedStats.sizes == ["\(expectedPixelWidth)x\(expectedPixelHeight)"], "Frames use the configured pixel size (got \(animatedStats.sizes))")
        check(animatedStats.formats == [kCVPixelFormatType_32BGRA], "Frames are BGRA (got \(animatedStats.formats.map { fourCC($0) }))")
        check(animatedStats.increasing, "Presentation timestamps strictly increase")
        check(capture.configuredPixelSize == CGSize(width: expectedPixelWidth, height: expectedPixelHeight), "Adapter reports the configured pixel size")
        let runningObservation = counter.runningStateObservation
        check(runningObservation?.captureState == .running &&
              runningObservation?.configuredSize == CGSize(width: expectedPixelWidth, height: expectedPixelHeight),
              "State callback can synchronously read state and configured pixels")
        // Running must describe a delivered picture, not a session that was merely installed.
        check((runningObservation?.deliveredFrames ?? 0) >= 1,
              "Running is published only after the first frame is delivered")
        // Every frame is handed over with the generation of the stream that produced it, and the
        // adapter still accepts it at hand-over time. That is what lets a client drop a frame
        // that passed this check just before a source switch and was delivered just after it.
        let deliveries = counter.deliveryGenerations
        check(deliveries.rejected == 0,
              "Frames delivered for the running stream are accepted (rejected \(deliveries.rejected))")
        check(deliveries.generations.count == 1,
              "Every delivered frame carries the running stream's generation (got \(deliveries.generations.count))")
        let deliveredGeneration = deliveries.generations.first ?? 0

        // Stop must stop delivery and report the stopped state.
        capture.stop()
        pump(0.4)
        check(!capture.acceptsFrame(generation: deliveredGeneration),
              "A stopped stream rejects the generation its frames carried")
        let afterStop = counter.snapshot.count
        pump(0.6)
        check(counter.snapshot.count == afterStop, "Stop ends frame delivery")
        check(counter.snapshot.states.contains(.stopped), "Stop publishes the stopped state")

        // Restart must resume delivery on the same instance.
        counter.reset()
        capture.start(windowID: UInt32(animated.windowNumber))
        pump(2.0)
        check(counter.snapshot.count > 60, "Restart resumes frame delivery (got \(counter.snapshot.count))")
        capture.stop()

        // Static source: ScreenCaptureKit reports unchanged content as idle, which the
        // adapter counts as dropped so cadence and duplicate statistics stay honest.
        // The animated window is closed first so nothing recomposites over the static one.
        timer?.invalidate()
        animated.orderOut(nil)
        pump(0.6)
        let (staticWindow, _) = makeWindow(animated: false, title: "MoniView static test",
                                           origin: NSPoint(x: 900, y: 420))
        pump(0.5)
        let staticCounter = Counter()
        let staticCapture = MacWindowCapture(
            frameSink: { sample, generation, source in
                staticCounter.record(sample: sample, generation: generation,
                                     accepted: source.acceptsFrame(generation: generation))
            },
            state: { staticCounter.recordState($0) },
            dropped: { staticCounter.recordDrop() })
        staticCounter.capture = staticCapture
        staticCapture.start(windowID: UInt32(staticWindow.windowNumber))
        pump(2.0)
        let staticStats = staticCounter.snapshot
        staticCapture.stop()
        check(staticStats.count >= 1, "Static window still delivers its first frame")
        // ScreenCaptureKit may keep delivering frames for unchanged content, so the
        // adapter cannot rely on the idle status alone. Unchanged content must arrive
        // byte-identical, which is exactly what the duplicate detector compares.
        let steady = staticCounter.steadySignatures()
        print("Settled window: frames=\(staticStats.count) distinct=\(staticCounter.distinctSignatures) steady signatures=\(steady.count)")
        check(steady.count == 1,
              "Unchanged window content repeats byte-identically once settled (got \(steady.count) signatures in the last 50 of \(staticCounter.signatureCount) frames; \(staticCounter.distinctSignatures) distinct overall)")

        // A window can accept a stream and stay silent forever. Running must never describe
        // that state, and the silence has to be reported rather than waiting indefinitely.
        // The window manager's own surfaces are exactly this: they exist on every Mac, so
        // they are used here directly instead of through the discovery list that excludes them.
        let silentCandidates = shareable.windows.filter {
            $0.frame.width >= 160 && $0.frame.height >= 120 &&
                MacWindowCapturePolicy.isSystemChromeWindow(bundleIdentifier: $0.owningApplication?.bundleIdentifier)
        }
        // The desktop picture first: it is the surface reported as never supplying content.
        if let silentWindow = silentCandidates.first(where: { ($0.title ?? "").contains("Wallpaper") })
            ?? silentCandidates.min(by: { $0.windowLayer < $1.windowLayer }) {
            let silentCounter = Counter()
            let silentCapture = MacWindowCapture(
                frameSink: { sample, generation, source in
                    silentCounter.record(sample: sample, generation: generation,
                                         accepted: source.acceptsFrame(generation: generation))
                },
                state: { silentCounter.recordState($0) },
                dropped: { silentCounter.recordDrop() })
            silentCounter.capture = silentCapture
            silentCapture.start(windowID: silentWindow.windowID)
            pump(MacWindowCapture.firstFrameDeadlineSeconds + 1.0)
            let silentStats = silentCounter.snapshot
            silentCapture.stop()
            print("Silent window \(silentWindow.windowID) (\(silentWindow.title ?? "-")): frames=\(silentStats.count) states=\(silentStats.states)")
            check(!(silentStats.states.contains(.running) && silentStats.count == 0),
                  "Running is not published for a window that delivered no frame")
            check(silentStats.states.contains(.noPicture) || silentStats.count > 0,
                  "A silent window is reported as having no picture")
        } else {
            print("SKIP silent-window check: no system chrome window is on screen")
        }

        timer?.invalidate()
        print("Mac window capture: \(checks) checks passed (real ScreenCaptureKit session; not a game, quality or latency claim).")
    }
}

MacWindowCaptureTests.run()
