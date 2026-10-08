import AppKit
import SwiftUI

@main
struct MoniViewApp: App {
    @NSApplicationDelegateAdaptor(MoniViewAppDelegate.self) private var appDelegate
    @StateObject private var captureManager = CaptureManager(supportedInterpolationQualities:
        FrameInterpolationMode.allCases.filter { $0 != .off && FrameInterpolatorSupport.isSupported($0) })
    @AppStorage("view.alwaysOnTop") private var alwaysOnTop = false

    var body: some Scene {
        Window("MoniView", id: "main") {
            MainView()
                .environmentObject(captureManager)
                .preferredColorScheme(.dark)
                .frame(minWidth: 880, minHeight: 590)
                .onAppear {
                    appDelegate.capture = captureManager
                }
                .background {
                    WindowLevelObserver(alwaysOnTop: alwaysOnTop)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        }
        .defaultSize(width: 1180, height: 790)
        .windowResizability(.contentMinSize)
        .commands {
            SaveFrameCommands(capture: captureManager)
            CommandGroup(after: .windowSize) {
                Button("切换全屏") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
                Toggle("窗口置顶", isOn: $alwaysOnTop)
            }
            CommandGroup(after: .help) {
                Button(L10n.text("使用指南")) {
                    let alert = NSAlert()
                    alert.messageText = L10n.text("使用指南")
                    alert.informativeText = L10n.text("连接 USB 采集卡后，在采集设置中选择视频设备。没有 USB 视频输入时不会自动打开内置或无线摄像头；这些摄像头只能手动选择。\n\n无需采集卡：打开一个有内容的其他应用窗口，将画面来源改为 Mac 窗口，授权屏幕录制后选择该窗口。源窗口需要保持打开并持续更新。\n\n音频可单独选择或关闭。录制与截图通过系统保存面板选择位置；画质增强仅处理实时预览，默认录制也应用色彩与源分辨率锐化，可在设置中关闭。\n\n拒绝权限后，可在系统设置的隐私与安全性中重新允许，再刷新设备或窗口；系统可能要求重启应用。")
                    alert.addButton(withTitle: L10n.text("好"))
                    alert.runModal()
                }
                Button(L10n.text("隐私政策")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/roanpy/MoniView/blob/main/docs/PRIVACY.md")!)
                }
                Button(L10n.text("支持与反馈")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/roanpy/MoniView/issues")!)
                }
            }
        }
    }
}

final class MoniViewAppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: CaptureManager?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        capture?.flushPicturePersistence()
        guard let capture, capture.isRecording else { return .terminateNow }
        capture.finishRecordingBeforeExit {
            if let message = capture.recordingError {
                let alert = NSAlert()
                alert.messageText = L10n.text("录制未能完成保存")
                alert.informativeText = message
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            } else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
