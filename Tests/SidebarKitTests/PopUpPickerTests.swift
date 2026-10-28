import AppKit
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing

@MainActor
struct PopUpPickerTests {
    final class Selection {
        var value = NotificationSeverity.normal
    }

    let selection = Selection()
    let font = NSFont(name: "Menlo", size: 11) ?? .systemFont(ofSize: 11)

    var picker: PopUpPicker<NotificationSeverity> {
        PopUpPicker(
            title: "Then",
            options: [.init(label: "Low", value: .low), .init(label: "Normal", value: .normal), .init(label: "High", value: .high, startsGroup: true)],
            selection: Binding(get: { selection.value }, set: { selection.value = $0 }),
            font: font
        )
    }

    func button(_ view: some View) throws -> NSPopUpButton {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSPopUpButton? {
            view as? NSPopUpButton ?? view.subviews.lazy.compactMap(find).first
        }
        return try #require(find(host))
    }

    /// The button and its menu take the given font; an option that starts a group gets a separator above it.
    @Test func listsTheOptionsInTheGivenFont() throws {
        let button = try button(picker)

        #expect(button.font == font)
        #expect(button.menu?.font == font)
        #expect(button.accessibilityLabel() == "Then")
        #expect(button.itemArray.map { $0.isSeparatorItem ? "—" : $0.title } == ["Low", "Normal", "—", "High"])
    }

    @Test func showsAndChangesTheSelection() throws {
        let button = try button(picker)
        #expect(button.titleOfSelectedItem == "Normal")

        button.selectItem(withTitle: "High")
        #expect(button.sendAction(button.action, to: button.target))
        #expect(selection.value == .high)
    }

    @Test func followsTheEnvironmentsEnabledState() throws {
        #expect(try button(picker).isEnabled)
        #expect(try !button(picker.disabled(true)).isEnabled)
    }
}
