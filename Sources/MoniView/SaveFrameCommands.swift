import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SaveFrameCommands: Commands {
    @ObservedObject var capture: CaptureManager
    @StateObject private var exporter = FrameExporter()
    @State private var isSaving = false

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("保存当前画面…", action: saveFrame)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!capture.isRunning || isSaving)
        }
    }

    private func saveFrame() {
        guard !isSaving, capture.isRunning, let (buffer, _, _) = capture.frames.latest() else { return }
        isSaving = true
        let date = Date()
        let settings = capture.picture
        // Snapshot the frame and settings at the command, not after the user dismisses the panel.
        exporter.png(buffer: buffer, settings: settings) { result in
            switch result {
            case .failure(let error):
                isSaving = false
                showError(error)
            case .success(let data):
                let panel = NSSavePanel()
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                panel.nameFieldStringValue = "MoniView-\(formatter.string(from: date)).png"
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                let finish: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let url = panel.url else { isSaving = false; return }
                    exporter.write(data, to: url) { error in
                        isSaving = false
                        if let error { showError(error) }
                    }
                }
                if let window = NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
                else { panel.begin(completionHandler: finish) }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.text("保存画面失败")
        alert.informativeText = error.localizedDescription
        if let window = NSApp.mainWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
