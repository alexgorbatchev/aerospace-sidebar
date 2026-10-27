import AppKit

/// Picks the font settings with the macOS font panel, so families can be browsed with previews
/// instead of typed by name.
///
/// The font manager sends `changeFont(_:)` to its target, which is otherwise the first responder of
/// the key window; this app's windows rarely are, so the chooser makes itself the target.
@MainActor
final class FontChooser: NSObject, NSFontChanging {
    /// Gap between the panel and the window it opens beside.
    static let spacing: CGFloat = 8

    private let manager: NSFontManager
    private let panel: () -> NSPanel?
    /// Applies the panel's pending change to a font; `NSFontManager.convert(_:)` outside tests.
    private let convert: (NSFont) -> NSFont
    private var current: NSFont?
    private var onChoose: ((SidebarSettings.Font) -> Void)?

    init(
        manager: NSFontManager = .shared,
        panel: @escaping () -> NSPanel? = { NSFontManager.shared.fontPanel(true) },
        convert: ((NSFont) -> NSFont)? = nil
    ) {
        self.manager = manager
        self.panel = panel
        self.convert = convert ?? { manager.convert($0) }
    }

    /// Shows the font panel beside `window` on `font` and reports every family or size picked in it.
    func choose(_ font: SidebarSettings.Font, beside window: NSWindow, onChoose: @escaping (SidebarSettings.Font) -> Void) {
        let selected = Typography(font).bodyFont
        current = selected
        self.onChoose = onChoose
        manager.target = self
        manager.setSelectedFont(selected, isMultiple: false)
        guard let panel = panel() else { return }
        // Without a saved frame AppKit can open the panel off-screen. A panel already showing stays
        // where the user put it.
        if !panel.isVisible, let screen = window.screen {
            panel.setFrame(Self.frame(of: panel.frame.size, beside: window.frame, in: screen.visibleFrame), display: false)
        }
        // The window server keeps panels that hide on deactivation off screen while their app is
        // inactive, which this app always is. Like Settings, the panel comes forward without waiting
        // for the app to be activated; it closes with Settings.
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
    }

    /// Top-aligned left of `window`, or right of it when the left does not fit, kept within `visible`.
    /// Left comes first because the sidebar, which floats above the panel, is on the right edge.
    static func frame(of size: NSSize, beside window: NSRect, in visible: NSRect) -> NSRect {
        var x = window.minX - spacing - size.width
        if x < visible.minX {
            x = window.maxX + spacing
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        let y = min(max(window.maxY - size.height, visible.minY), visible.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    /// Hides the panel and stops reporting picks.
    func close() {
        if manager.target === self {
            manager.target = nil
        }
        onChoose = nil
        current = nil
        panel()?.orderOut(nil)
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let current, let onChoose else { return }
        let picked = convert(current)
        self.current = picked
        // The system font's family is hidden (".AppleSystemUIFont"); settings spell it as empty.
        let family = picked.familyName.flatMap(Typography.installedFamily(named:)) ?? ""
        onChoose(SidebarSettings.Font(name: family, size: Double(picked.pointSize)))
    }

    /// Only family, face and size map to settings; color, underline and shadows do not.
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }
}
