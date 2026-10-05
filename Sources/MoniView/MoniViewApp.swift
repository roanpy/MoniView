import AppKit
import SwiftUI

@main
struct MoniViewApp: App {
    @NSApplicationDelegateAdaptor(MoniViewAppDelegate.self) private var appDelegate
    @StateObject private var captureManager = CaptureManager()

    var body: some Scene {
        Window("MoniView", id: "main") {
            MainView()
                .environmentObject(captureManager)
                .preferredColorScheme(.dark)
                .frame(minWidth: 880, minHeight: 590)
                .onAppear { appDelegate.capture = captureManager }
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
            }
            CommandGroup(after: .help) {
                Button(L10n.text("隐私政策")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/roanpy/MoniView/blob/main/docs/PRIVACY.md")!)
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
