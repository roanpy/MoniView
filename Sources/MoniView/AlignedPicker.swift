import AppKit
import SwiftUI

struct PickerChoice<Value: Hashable> {
    let value: Value
    let title: String
}

/// A native pop-up control accepts the row's proposed width instead of hugging its title.
struct AlignedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    let choices: [PickerChoice<Value>]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> PickerCoordinator { PickerCoordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        view.font = .systemFont(ofSize: 11)
        view.target = context.coordinator
        view.action = #selector(PickerCoordinator.changed(_:))
        view.menu?.delegate = context.coordinator
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = { index in
            guard choices.indices.contains(index) else { return }
            selection = choices[index].value
        }
        // Capture statistics refresh SwiftUI while the native menu is tracking.
        // Re-selecting the old model value here cancels the user's pending choice.
        guard !context.coordinator.isTracking else { return }
        let titles = choices.map(\.title)
        if view.itemTitles != titles {
            view.removeAllItems()
            view.addItems(withTitles: titles)
        }
        // Do not leave a stale or automatically selected first item when the model has no match.
        let selectedIndex = choices.firstIndex(where: { $0.value == selection }) ?? -1
        if view.indexOfSelectedItem != selectedIndex { view.selectItem(at: selectedIndex) }
        view.isEnabled = isEnabled && !choices.isEmpty
        view.setAccessibilityLabel(L10n.text(title))
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 195, height: 27)
    }
}

final class PickerCoordinator: NSObject, NSMenuDelegate {
    private(set) var isTracking = false
    func menuWillOpen(_ menu: NSMenu) { isTracking = true }
    func menuDidClose(_ menu: NSMenu) { isTracking = false }
    var onSelect: ((Int) -> Void)?
    @objc func changed(_ sender: NSPopUpButton) { onSelect?(sender.indexOfSelectedItem) }
}
