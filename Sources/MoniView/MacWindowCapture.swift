@preconcurrency import ScreenCaptureKit
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
    private var stream: SCStream?
    private var windowID: UInt32?
    private var generation: UInt64 = 0
    private var configuredSize = CGSize.zero
    private(set) var state: State = .idle
    /// The pixel size frames are delivered at; the recorder uses it for its writer.
    var configuredPixelSize: CGSize { configuredSize }

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
        generation &+= 1
        let expected = generation
        publish(.starting)
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == expected else { return }
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    self.publish(.failed(MacWindowCaptureError.windowUnavailable.localizedDescription)); return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                // Keep the source's own pixel size; enhancement targets are applied later.
                let scale = min(1, 3840 / max(1, window.frame.width))
                let width = max(2, Int(window.frame.width * scale) & ~1)
                let height = max(2, Int(window.frame.height * scale) & ~1)
                configuration.width = width
                configuration.height = height
                // Ask for the display's own rate: a 120 Hz panel would otherwise be
                // capped at 60 by a hardcoded interval. This is a requested cadence,
                // not proof of a source's render rate.
                let displayRate = await Self.displayRefreshRate()
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(displayRate))
                configuration.queueDepth = 5
                configuration.showsCursor = false
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.scalesToFit = true
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard self.generation == expected else { try? await stream.stopCapture(); return }
                self.windowID = windowID
                self.configuredSize = CGSize(width: width, height: height)
                self.stream = stream
                self.publish(.running)
            } catch {
                guard self.generation == expected else { return }
                self.publish(.failed(MacWindowCaptureError.startFailed(error.localizedDescription).localizedDescription))
            }
        }
    }

    func stop() {
        generation &+= 1
        let existing = stream
        stream = nil
        windowID = nil
        configuredSize = .zero
        publish(.stopped)
        guard let existing else { return }
        Task { try? await existing.stopCapture() }
    }

    /// The refresh limit of the display showing the source window. Apple reports this
    /// per screen; it is the ceiling the compositor can deliver, not a measured rate.
    private static func displayRefreshRate() async -> Int {
        await MainActor.run {
            let reported = NSScreen.main?.maximumFramesPerSecond ?? 60
            return min(240, max(30, reported))
        }
    }

    private func publish(_ newState: State) {
        state = newState
        DispatchQueue.main.async { [weak self] in self?.stateHandler(newState) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw) else { return }
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
        publish(.failed(MacWindowCaptureError.startFailed(error.localizedDescription).localizedDescription))
    }
}
