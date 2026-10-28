import AppKit
import SwiftUI

/// A pop-up button in a given font. SwiftUI's menu `Picker` draws through `NSPopUpButton` but never passes
/// a font on, so its title and items stay in the system font whatever `[font]` says; this sets the button's
/// and its menu's own `font`.
struct PopUpPicker<Value: Hashable>: NSViewRepresentable {
    struct Option {
        let label: String
        let value: Value
        /// Draws a separator above the option.
        var startsGroup = false
    }

    let title: String
    let options: [Option]
    @Binding var selection: Value
    let font: NSFont

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.picker = self
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            if option.startsGroup, index > 0 {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: option.label, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        menu.font = font
        button.menu = menu
        button.font = font
        button.isEnabled = context.environment.isEnabled
        if let index = options.firstIndex(where: { $0.value == selection }) {
            button.selectItem(withTag: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(picker: self) }

    @MainActor
    final class Coordinator: NSObject {
        var picker: PopUpPicker

        init(picker: PopUpPicker) {
            self.picker = picker
        }

        @objc func select(_ button: NSPopUpButton) {
            guard let item = button.selectedItem, picker.options.indices.contains(item.tag) else { return }
            picker.selection = picker.options[item.tag].value
        }
    }
}
