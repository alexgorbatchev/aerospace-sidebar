import AppKit

/// The sidebar's background (`[background]`): a window the color of the setting that fills the strip from the
/// top of the screen to the bottom, so it also shows through the menu bar.
///
/// It sits just below the Dock (`level`): above every app's windows, floating ones over the strip included, and
/// under the Dock, the menu bar and the sidebar panel. While System Settings is in front, the panel steps behind it
/// at `.normal` (`SystemSettingsFollower`), and the background goes with it, just below the panel, so it covers
/// neither System Settings nor the cards. Clicks pass through it: the panel above takes the clicks on the strip
/// below the menu bar, and the menu bar and the Dock take theirs.
@MainActor
final class SidebarBackground {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)

    let window: NSPanel

    init() {
        // Borderless with no close button, like the sidebar panel: AeroSpace takes it for a popup and leaves it
        // alone.
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = Self.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.hasShadow = false
    }

    /// Shows `background` over `frame` under `panel`, at its own level while the panel `floats` and otherwise just
    /// below the panel at `.normal`; nothing when it is invisible or there is no screen.
    func show(_ background: SidebarSettings.Background, in frame: CGRect?, under panel: NSWindow, floats: Bool) {
        guard background.isVisible, let frame else {
            window.orderOut(nil)
            return
        }
        window.backgroundColor = background.color.nsColor.withAlphaComponent(background.opacity)
        window.setFrame(frame, display: true)
        window.level = floats ? Self.level : .normal
        if floats {
            window.orderFrontRegardless()
        } else {
            window.order(.below, relativeTo: panel.windowNumber)
        }
    }
}

extension SidebarSettings.RGBColor {
    /// The color in sRGB.
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    /// `color` in sRGB, rounded to whole steps of 1/255; its alpha is ignored.
    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        func component(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        self.init(red: component(srgb.redComponent), green: component(srgb.greenComponent), blue: component(srgb.blueComponent))
    }
}
