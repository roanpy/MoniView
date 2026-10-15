import AppKit
import SwiftUI

/// Resolve the preview's actual NSWindow, including its first attachment at launch.
/// Never change panels, alerts or other windows found through NSApp.windows.
struct WindowLevelObserver: NSViewRepresentable {
    var alwaysOnTop: Bool
    var fittedPreview = false

    func makeNSView(context: Context) -> WindowLevelNSView {
        let view = WindowLevelNSView(frame: .zero)
        view.alwaysOnTop = alwaysOnTop
        view.fittedPreview = fittedPreview
        return view
    }

    func updateNSView(_ view: WindowLevelNSView, context: Context) {
        view.fittedPreview = fittedPreview
        view.alwaysOnTop = alwaysOnTop
    }
}

final class WindowLevelNSView: NSView {
    var alwaysOnTop = false { didSet { if oldValue != alwaysOnTop { applyLevel() } } }
    var fittedPreview = false { didSet { if oldValue != fittedPreview { applyLevel() } } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willEnterFullscreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didExitFullscreen), name: NSWindow.didExitFullScreenNotification, object: window)
        applyLevel()
    }

    private func applyLevel() {
        guard !fittedPreview, let window, !window.styleMask.contains(.fullScreen) else { return }
        let desired: NSWindow.Level = alwaysOnTop ? .floating : .normal
        if window.level != desired { window.level = desired }
    }

    @objc private func willEnterFullscreen() { window?.level = .normal }
    @objc private func didExitFullscreen() { applyLevel() }

    deinit { NotificationCenter.default.removeObserver(self) }
}
