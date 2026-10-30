import AppKit
import SwiftUI

/// A native color well for an opaque color. SwiftUI's `ColorPicker` opens the shared color panel where AppKit
/// last left it, and the window server keeps that panel off screen while this app is inactive, which it always
/// is; `SettingsColorWell` shows it beside Settings like the font panel (`FontChooser`).
struct ColorWell: NSViewRepresentable {
    let title: String
    @Binding var color: SidebarSettings.RGBColor
    /// The sidebar's saved side, which the color panel opens away from.
    let sidebarSide: @MainActor () -> SidebarSettings.Sidebar.Side

    func makeNSView(context: Context) -> SettingsColorWell {
        // `init(style:)` is a class factory that makes a plain `NSColorWell`, not this subclass.
        let well = SettingsColorWell(frame: .zero)
        well.colorWellStyle = .default
        well.supportsAlpha = false
        well.target = context.coordinator
        well.action = #selector(Coordinator.pick(_:))
        well.setAccessibilityLabel(title)
        return well
    }

    func updateNSView(_ well: SettingsColorWell, context: Context) {
        context.coordinator.well = self
        well.sidebarSide = sidebarSide
        well.isEnabled = context.environment.isEnabled
        // Setting the same color again would end a drag in the color panel.
        if SidebarSettings.RGBColor(well.color) != color {
            well.color = color.nsColor
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(well: self) }

    @MainActor
    final class Coordinator: NSObject {
        var well: ColorWell

        init(well: ColorWell) {
            self.well = well
        }

        @objc func pick(_ sender: NSColorWell) {
            well.color = SidebarSettings.RGBColor(sender.color)
        }
    }
}

/// A color well whose color panel comes forward beside the Settings window, away from the sidebar, while this
/// app is inactive, and closes with Settings (`closePanel(of:)`).
final class SettingsColorWell: NSColorWell {
    var sidebarSide: @MainActor () -> SidebarSettings.Sidebar.Side = { .right }

    /// The well the color panel edits, if it is one of these.
    static weak var active: SettingsColorWell?

    override func activate(_ exclusive: Bool) {
        let panel = NSColorPanel.shared
        let wasVisible = panel.isVisible
        super.activate(exclusive)
        Self.active = self
        show(panel, placing: !wasVisible)
    }

    /// Shows `panel`, the color panel this well opened, while the app is inactive, beside the well's window and
    /// away from the sidebar when `placing` (it was hidden; one already showing stays where the user put it).
    func show(_ panel: NSPanel, placing: Bool) {
        // Like the font panel's: kept off screen otherwise while the app is inactive.
        panel.hidesOnDeactivate = false
        (panel as? NSColorPanel)?.showsAlpha = false
        if placing, let window, let screen = window.screen {
            panel.setFrame(
                FontChooser.frame(of: panel.frame.size, beside: window.frame, awayFrom: sidebarSide(), in: screen.visibleFrame),
                display: false
            )
        }
        panel.orderFrontRegardless()
    }

    /// Hides `panel`, the shared color panel outside tests, and stops it editing a color, when a well in `window`
    /// opened it. The panel is shared by the whole app, so closing another window leaves it alone.
    static func closePanel(of window: NSWindow, panel: @autoclosure () -> NSPanel = NSColorPanel.shared) {
        guard let active, active.window === window else { return }
        active.deactivate()
        self.active = nil
        panel().orderOut(nil)
    }
}
