@preconcurrency import ScreenCaptureKit
import AppKit
import CoreMedia
import CoreVideo
import Foundation

/// A selectable Mac window offered as a capture source.
struct MacWindowOption: Identifiable, Hashable {
    let id: UInt32
    let title: String
    let applicationName: String
    let width: Int
    let height: Int
    var displayTitle: String {
        let name = title.isEmpty ? applicationName : title
        return "\(name) — \(applicationName)"
    }
}

/// Small, framework-independent rules used by the ScreenCaptureKit adapter. Keeping
/// these calculations pure makes display selection, Retina sizing, and callback
/// identity checks testable without opening a capture session.
enum MacWindowCapturePolicy {
    struct Display: Equatable {
        let id: UInt32
        let frame: CGRect
    }

    static func displayID(forWindowFrame windowFrame: CGRect, among displays: [Display]) -> UInt32? {
        guard !windowFrame.isNull, !windowFrame.isEmpty else { return nil }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        var best: (id: UInt32, area: CGFloat, containsCenter: Bool)?

        for display in displays {
            let overlap = windowFrame.intersection(display.frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            let containsCenter = display.frame.contains(center)
            if best == nil || area > best!.area || (area == best!.area && containsCenter && !best!.containsCenter) {
                best = (display.id, area, containsCenter)
            }
        }
        return best?.id
    }

    /// SCWindow and SCDisplay geometry is in screen points, while configured stream
    /// dimensions are output pixels. Preserve the current 3840-pixel width ceiling.
    static func pixelSize(forWindowFrameSize size: CGSize,
                          backingScaleFactor: CGFloat,
                          maximumWidth: Int = 3840) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, maximumWidth >= 2 else { return .zero }
        let scale = backingScaleFactor.isFinite ? max(1, backingScaleFactor) : 1
        let pixelWidth = size.width * scale
        let outputScale = min(1, CGFloat(maximumWidth) / pixelWidth)
        func evenDimension(_ value: CGFloat) -> Int {
            max(2, Int((value * outputScale).rounded(.down)) & ~1)
        }
        return CGSize(width: evenDimension(pixelWidth), height: evenDimension(size.height * scale))
    }

    static func boundedRefreshRate(_ reportedRate: Int) -> Int {
        min(240, max(30, reportedRate > 0 ? reportedRate : 60))
    }

    static func acceptsCallback<Stream: AnyObject>(
        callbackStream: Stream,
        activeStream: Stream?,
        activeGeneration: UInt64?,
        generation: UInt64
    ) -> Bool {
        guard let activeStream, callbackStream === activeStream,
              activeGeneration == generation else { return false }
        return true
    }
}

enum MacWindowCaptureError: LocalizedError {
    case permissionDenied
    case noWindows
    case windowUnavailable
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return L10n.text("需要在系统设置中允许屏幕录制")
        case .noWindows: return L10n.text("没有可选择的窗口")
        case .windowUnavailable: return L10n.text("所选窗口已关闭")
        case .startFailed(let detail): return L10n.format("窗口捕获失败：%@", detail)
        }
    }
}

/// ScreenCaptureKit window source. Frames are delivered exactly like capture-device
/// buffers through `LatestVideoFrame.put`, so the preview, enhancement and
/// interpolation stages need no source-specific handling.
///
/// ScreenCaptureKit reports an `.idle` status when the window content did not change.
/// Only `.complete` frames carry a new picture; idle callbacks are counted as dropped
/// so the cadence detector never mistakes a repeat for new content.
final class MacWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
        case stopped
    }

    private let frameSink: (CMSampleBuffer) -> Void
    private let stateHandler: (State) -> Void
    private let droppedHandler: () -> Void
    private let queue = DispatchQueue(label: "dev.moniview.sck", qos: .userInteractive)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var streamGeneration: UInt64?
    private var generation: UInt64 = 0
    private var configuredSize = CGSize.zero
    private var stateValue: State = .idle
    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateValue
    }
    /// The pixel size frames are delivered at; the recorder uses it for its writer.
    var configuredPixelSize: CGSize {
        stateLock.lock()
        defer { stateLock.unlock() }
        return configuredSize
    }

    init(frameSink: @escaping (CMSampleBuffer) -> Void,
         state: @escaping (State) -> Void,
         dropped: @escaping () -> Void) {
        self.frameSink = frameSink
        self.stateHandler = state
        self.droppedHandler = dropped
        super.init()
    }

    /// Windows eligible as a source: real application windows with a usable size,
    /// excluding our own output so the enhanced copy never captures itself.
    static func availableWindows(excludingBundleID: String?) async throws -> [MacWindowOption] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw MacWindowCaptureError.permissionDenied
        }
        let options = content.windows.compactMap { window -> MacWindowOption? in
            let bundle = window.owningApplication?.bundleIdentifier
            if let excludingBundleID, bundle == excludingBundleID { return nil }
            guard window.frame.width >= 160, window.frame.height >= 120 else { return nil }
            let name = window.owningApplication?.applicationName ?? ""
            // System chrome is not a meaningful capture target.
            if name.isEmpty { return nil }
            return MacWindowOption(id: window.windowID, title: window.title ?? "",
                applicationName: name, width: Int(window.frame.width.rounded()), height: Int(window.frame.height.rounded()))
        }
        return options.sorted { lhs, rhs in
            if lhs.applicationName != rhs.applicationName { return lhs.applicationName < rhs.applicationName }
            return lhs.displayTitle < rhs.displayTitle
        }
    }

    func start(windowID: UInt32) {
        stateLock.lock()
        generation &+= 1
        let expected = generation
        let previous = stream
        stream = nil
        streamGeneration = nil
        configuredSize = .zero
        stateValue = .starting
        enqueueStateLocked(.starting, generation: expected)
        stateLock.unlock()

        Task { [weak self] in
            guard let self else { return }
            if let previous { try? await previous.stopCapture() }
            guard self.isCurrentGeneration(expected) else { return }
            await self.startCapture(windowID: windowID, generation: expected)
        }
    }

    func stop() {
        stateLock.lock()
        generation &+= 1
        let expected = generation
        let existing = stream
        stream = nil
        streamGeneration = nil
        configuredSize = .zero
        stateValue = .stopped
        enqueueStateLocked(.stopped, generation: expected)
        stateLock.unlock()

        guard let existing else { return }
        Task { try? await existing.stopCapture() }
    }

    private func startCapture(windowID: UInt32, generation expected: UInt64) async {
        var candidateStream: SCStream?
        var installedStream: SCStream?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isCurrentGeneration(expected) else { return }
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                _ = transition(to: .failed(MacWindowCaptureError.windowUnavailable.localizedDescription),
                               generation: expected, onlyWhileStarting: true)
                return
            }

            let displayID = MacWindowCapturePolicy.displayID(
                forWindowFrame: window.frame,
                among: content.displays.map { MacWindowCapturePolicy.Display(id: $0.displayID, frame: $0.frame) })
            let display = await Self.displayMetrics(for: displayID)
            guard isCurrentGeneration(expected) else { return }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            // Window/display geometry is in logical points; the stream output is pixels.
            let size = MacWindowCapturePolicy.pixelSize(
                forWindowFrameSize: window.frame.size,
                backingScaleFactor: display.backingScaleFactor)
            guard size != .zero else {
                _ = transition(to: .failed(MacWindowCaptureError.windowUnavailable.localizedDescription),
                               generation: expected, onlyWhileStarting: true)
                return
            }
            let width = Int(size.width)
            let height = Int(size.height)
            configuration.width = width
            configuration.height = height
            // This is the source display's maximum cadence, not a measured render rate.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(display.refreshRate))
            configuration.queueDepth = 5
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.scalesToFit = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            candidateStream = stream
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            guard installStartingStream(stream, generation: expected) else {
                try? await stream.stopCapture()
                return
            }
            installedStream = stream
            try await stream.startCapture()
            guard activate(stream, configuredSize: size, generation: expected) else {
                try? await stream.stopCapture()
                return
            }
            candidateStream = nil
        } catch {
            let detail = MacWindowCaptureError.startFailed(error.localizedDescription).localizedDescription
            _ = transition(to: .failed(detail), generation: expected,
                           matchingStream: installedStream, onlyWhileStarting: true, clearActiveStream: true)
            if let candidateStream { try? await candidateStream.stopCapture() }
        }
    }

    private static func displayMetrics(for displayID: UInt32?) async -> (backingScaleFactor: CGFloat, refreshRate: Int) {
        await MainActor.run {
            guard let displayID,
                  let screen = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                  }) else {
                return (1, MacWindowCapturePolicy.boundedRefreshRate(60))
            }
            return (max(1, screen.backingScaleFactor),
                    MacWindowCapturePolicy.boundedRefreshRate(screen.maximumFramesPerSecond))
        }
    }

    private func isCurrentGeneration(_ expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == expected
    }

    private func installStartingStream(_ candidate: SCStream, generation expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == expected, stateValue == .starting else { return false }
        stream = candidate
        streamGeneration = expected
        // Keep configuredPixelSize at zero until startCapture succeeds.
        configuredSize = .zero
        return true
    }

    private func activate(_ candidate: SCStream, configuredSize size: CGSize, generation expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == expected, stateValue == .starting,
              MacWindowCapturePolicy.acceptsCallback(callbackStream: candidate,
                                                     activeStream: stream,
                                                     activeGeneration: streamGeneration,
                                                     generation: generation) else { return false }
        self.configuredSize = size
        stateValue = .running
        enqueueStateLocked(.running, generation: expected)
        return true
    }

    private func transition(to newState: State, generation expected: UInt64,
                            matchingStream: SCStream? = nil,
                            onlyWhileStarting: Bool = false,
                            clearActiveStream: Bool = false) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == expected else { return false }
        if let matchingStream, !MacWindowCapturePolicy.acceptsCallback(
            callbackStream: matchingStream, activeStream: stream,
            activeGeneration: streamGeneration, generation: generation) { return false }
        if onlyWhileStarting, stateValue != .starting { return false }
        stateValue = newState
        if clearActiveStream {
            stream = nil
            streamGeneration = nil
            configuredSize = .zero
        }
        enqueueStateLocked(newState, generation: expected)
        return true
    }

    /// Caller holds stateLock so transition order and callback delivery order agree.
    private func enqueueStateLocked(_ newState: State, generation expected: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrent = self.generation == expected
            self.stateLock.unlock()
            guard isCurrent else { return }
            // Never invoke client code while holding stateLock. Handlers may read
            // state/configuration or synchronously call start/stop.
            self.stateHandler(newState)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return }
        stateLock.lock()
        let isCurrent = stateValue == .running &&
            MacWindowCapturePolicy.acceptsCallback(callbackStream: stream,
                                                   activeStream: self.stream,
                                                   activeGeneration: streamGeneration,
                                                   generation: generation)
        stateLock.unlock()
        // An accepted callback may finish if stop/restart races after this snapshot.
        // The next callback observes the new generation. Client code runs lock-free
        // so it can safely query or change capture state synchronously.
        guard isCurrent else { return }
        guard status == .complete else {
            // Unchanged content: the compositor re-sent the previous surface.
            // Counting it as dropped keeps cadence and duplicate statistics honest.
            if status == .idle { droppedHandler() }
            return
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        frameSink(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let detail = MacWindowCaptureError.startFailed(error.localizedDescription).localizedDescription
        stateLock.lock()
        defer { stateLock.unlock() }
        guard MacWindowCapturePolicy.acceptsCallback(callbackStream: stream,
                                                     activeStream: self.stream,
                                                     activeGeneration: streamGeneration,
                                                     generation: generation) else { return }
        stateValue = .failed(detail)
        self.stream = nil
        streamGeneration = nil
        configuredSize = .zero
        enqueueStateLocked(.failed(detail), generation: generation)
    }
}
