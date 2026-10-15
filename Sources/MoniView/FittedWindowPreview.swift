import AppKit
import CoreGraphics
import CoreVideo
import SwiftUI

/// Reuses the main preview window. Main-thread state; window-server discovery is bounded
/// to one background request at a time. No input injection or Accessibility permission.
final class FittedWindowPreview: NSObject {
    private struct Geometry {
        let id: UInt32
        let pid: pid_t
        let frame: CGRect
        let layer: Int
    }
    private struct SavedWindow {
        let frame: CGRect
        let style: NSWindow.StyleMask
        let level: NSWindow.Level
        let minimum: CGSize
        let contentMinimum: CGSize
        let collection: NSWindow.CollectionBehavior
        let mouse: Bool
        let shadow: Bool
    }

    private weak var capture: CaptureManager?
    private weak var window: NSWindow?
    private var saved: SavedWindow?
    private var sourceID: UInt32?
    private var sourcePID: pid_t?
    private var screenID: UInt32?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem?
    private var polling = false
    private var revision: UInt64 = 0
    private let discovery = DispatchQueue(label: "dev.moniview.fitted-window", qos: .userInitiated)
    private var enteredAt = 0.0
    private var requestedSize = CGSize.zero
    private var resizeTask: Task<Void, Never>?
    private var resizeDeadline = 0.0

    init(capture: CaptureManager) { self.capture = capture; super.init() }

    func attach(window: NSWindow?) {
        guard let window, self.window !== window else { return }
        if saved != nil { stop() }
        self.window = window
    }

    func start() {
        guard saved == nil, let capture, let window,
              capture.sourceKind == .macWindow, capture.isRunning,
              !capture.isRecording, let id = capture.selectedMacWindowID,
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized else {
            capture?.setFittedPreviewState(false, message: "请先选择正在预览的普通 Mac 窗口，并停止录制或退出全屏。")
            return
        }
        // The first snapshot also runs off the UI thread. Its revision rejects a cancelled start.
        revision &+= 1
        let token = revision
        discovery.async { [weak self] in
            let windows = Self.visibleWindows()
            DispatchQueue.main.async {
                guard let self, self.revision == token, self.saved == nil,
                      capture.sourceKind == .macWindow, capture.selectedMacWindowID == id,
                      capture.isRunning, !capture.isRecording, window.isVisible,
                      !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
                guard let source = windows?.first(where: { $0.id == id && $0.layer == 0 }),
                      let screen = self.containingScreen(source.frame),
                      let displayID = Self.displayID(screen),
                      window.screen.flatMap(Self.displayID) == displayID,
                      source.pid != ProcessInfo.processInfo.processIdentifier else {
                    capture.setFittedPreviewState(false, message: "贴合预览仅支持与 MoniView 同屏、完整可见的普通窗口。")
                    return
                }
                self.begin(source: source, screen: screen, window: window)
            }
        }
    }

    private func begin(source: Geometry, screen: NSScreen, window: NSWindow) {
        guard let capture else { return }
        saved = SavedWindow(frame: window.frame, style: window.styleMask, level: window.level,
                            minimum: window.minSize, contentMinimum: window.contentMinSize,
                            collection: window.collectionBehavior, mouse: window.ignoresMouseEvents,
                            shadow: window.hasShadow)
        sourceID = source.id; sourcePID = source.pid
        screenID = Self.displayID(screen)
        requestedSize = .zero
        enteredAt = ProcessInfo.processInfo.systemUptime
        capture.setFittedPreviewState(true, message: nil)
        window.orderOut(nil)
        window.styleMask = .borderless
        window.minSize = .zero; window.contentMinSize = .zero
        window.level = .normal
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: L10n.text("返回 MoniView"))
        item.button?.toolTip = L10n.text("返回 MoniView")
        let menu = NSMenu()
        let exit = NSMenuItem(title: L10n.text("返回 MoniView"), action: #selector(returnToControls), keyEquivalent: "")
        exit.target = self; menu.addItem(exit); item.menu = menu
        statusItem = item
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop(activate: true)
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.stop() })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.stop(message: "显示器已改变，已返回独立预览。") })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.willSleepNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.stop(message: "工作区或窗口状态改变，已返回独立预览。") })
        }
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { self.stop(activate: true) }
            else if app.processIdentifier != self.sourcePID { self.stop(message: "已切换应用，已返回独立预览。") }
        })
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Public activation transfers focus; it does not move, resize or minimize the source.
        NSRunningApplication(processIdentifier: source.pid)?.activate(options: [])
        poll()
    }

    private func poll() {
        guard !polling, saved != nil else { return }
        guard let capture, capture.sourceKind == .macWindow, capture.selectedMacWindowID == sourceID,
              capture.isRunning, !capture.isRecording else { stop(message: "来源状态改变，已返回独立预览。"); return }
        polling = true
        let token = revision
        discovery.async { [weak self] in
            let windows = Self.visibleWindows()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                guard self.saved != nil, self.revision == token else { return }
                self.update(windows: windows)
            }
        }
    }

    private func update(windows: [Geometry]?) {
        guard let capture, let window, let sourceID, let sourcePID,
              let windows, let index = windows.firstIndex(where: { $0.id == sourceID && $0.pid == sourcePID }),
              windows[index].layer == 0,
              let screen = containingScreen(windows[index].frame), Self.displayID(screen) == screenID else {
            stop(message: "窗口已隐藏、关闭或移出当前屏幕，已返回独立预览。")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
            window.orderOut(nil)
            if now - enteredAt > 1 { stop(message: "请将所选来源窗口置于前台后再开启贴合预览。") }
            return
        }
        let source = windows[index]
        // Do not cover dialogs, other app windows or another document from the same app.
        // Also checks sheets extending beyond the source rectangle. Our own preview is excluded.
        if windows[..<index].contains(where: { $0.pid != ProcessInfo.processInfo.processIdentifier && $0.frame.intersects(source.frame) }) {
            stop(message: "来源前方出现其他窗口，已返回独立预览。")
            return
        }
        let appKitFrame = Self.appKitFrame(source.frame)
        if window.frame != appKitFrame { window.setFrame(appKitFrame, display: true, animate: false) }
        let expected = MacWindowCapturePolicy.pixelSize(forWindowFrameSize: source.frame.size, backingScaleFactor: screen.backingScaleFactor)
        if requestedSize != source.frame.size {
            window.orderOut(nil)
            guard resizeTask == nil else { return }
            requestedSize = source.frame.size
            resizeDeadline = now + 2
            let token = revision
            resizeTask = Task { @MainActor [weak self] in
                let success = await capture.resizeMacWindowPreview(to: source.frame.size, scale: screen.backingScaleFactor)
                guard let self, self.revision == token, self.saved != nil else { return }
                self.resizeTask = nil
                if !success { self.stop(message: "窗口尺寸更新失败，已返回独立预览。") }
            }
            return
        }
        guard resizeTask == nil, let (buffer, _, _) = capture.frames.latest(),
              CVPixelBufferGetWidth(buffer) == Int(expected.width), CVPixelBufferGetHeight(buffer) == Int(expected.height) else {
            window.orderOut(nil)
            if now > resizeDeadline { stop(message: "等待窗口新画面超时，已返回独立预览。") }
            return
        }
        // Remain in the normal window level; never take key focus or float over other apps.
        window.orderFrontRegardless()
    }

    @objc private func returnToControls() { stop(activate: true) }

    func stop(message: String? = nil, activate: Bool = false) {
        revision &+= 1
        guard let saved else { return }
        self.saved = nil
        timer?.invalidate(); timer = nil
        resizeTask?.cancel(); resizeTask = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceObservers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
        sourceID = nil; sourcePID = nil; screenID = nil
        capture?.setFittedPreviewState(false, message: message)
        guard let window else { return }
        window.orderOut(nil)
        window.ignoresMouseEvents = saved.mouse
        window.styleMask = saved.style
        window.minSize = saved.minimum; window.contentMinSize = saved.contentMinimum
        window.collectionBehavior = saved.collection
        window.hasShadow = saved.shadow
        window.level = saved.level
        window.setFrame(saved.frame, display: true, animate: false)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else { window.orderBack(nil) }
    }

    private func containingScreen(_ frame: CGRect) -> NSScreen? {
        guard frame.width >= 160, frame.height >= 120, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return nil }
        let rect = Self.appKitFrame(frame)
        // Excludes fullscreen, spanning displays, menu/Dock areas and off-screen geometry.
        return NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(rect) }
    }
    private static func appKitFrame(_ frame: CGRect) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }
    private static func displayID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private static func visibleWindows() -> [Geometry]? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return infos.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), !frame.isEmpty,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return Geometry(id: id, pid: pid, frame: frame, layer: layer)
        }
    }

    deinit {
        timer?.invalidate(); resizeTask?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

struct FittedPreviewWindowObserver: NSViewRepresentable {
    let capture: CaptureManager
    func makeNSView(context: Context) -> FittedPreviewAttachment {
        let view = FittedPreviewAttachment(frame: .zero)
        view.capture = capture
        return view
    }
    func updateNSView(_ view: FittedPreviewAttachment, context: Context) { view.capture = capture }
}
final class FittedPreviewAttachment: NSView {
    weak var capture: CaptureManager?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        capture?.fittedWindowPreview.attach(window: window)
    }
}
