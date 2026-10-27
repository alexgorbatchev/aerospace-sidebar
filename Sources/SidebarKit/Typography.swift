import AppKit
import SwiftUI

/// Fonts from the `[font]` settings for every text style. Each style keeps its macOS proportion to
/// the body text: at a 13-point base, `.callout` is 12 points, as in the system styles.
struct Typography: Equatable {
    /// The installed family to use, or `nil` for the system font.
    let family: String?
    /// Body text size in points.
    let size: CGFloat

    init(_ settings: SidebarSettings.Font) {
        family = Self.installedFamily(named: settings.name)
        // Previews show sizes before Save validates them.
        let range = SidebarSettings.Font.sizeRange
        size = min(max(settings.size, range.lowerBound), range.upperBound)
    }

    /// The configured size relative to macOS's; widths sized to fit text at the default size scale with it.
    var scale: CGFloat { size / SidebarSettings.Font.defaultSize }

    func font(_ style: NSFont.TextStyle) -> Font {
        let system = NSFont.preferredFont(forTextStyle: style)
        let size = size * system.pointSize / NSFont.preferredFont(forTextStyle: .body).pointSize
        let font: Font = if let family { .custom(family, fixedSize: size) } else { .system(size: size) }
        return system.fontDescriptor.symbolicTraits.contains(.bold) ? font.bold() : font
    }

    /// The body font as an `NSFont`, for AppKit APIs such as the font panel.
    var bodyFont: NSFont {
        family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) } ?? .systemFont(ofSize: size)
    }

    /// The installed family whose name matches `name` ignoring case; `nil` when empty or not installed.
    static func installedFamily(named name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return NSFontManager.shared.availableFontFamilies.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension Button where Label == Text {
    /// A button titled in `font`. Push buttons are drawn by AppKit, which ignores the inherited font and
    /// only honors a font applied to the `Text` label itself; a label view that applies it does not count.
    init(_ title: String, font: Font, action: @escaping () -> Void) {
        self.init(action: action) { Text(title).font(font) }
    }
}

extension EnvironmentValues {
    @Entry var typography = Typography(SidebarSettings.Font())
}

extension View {
    /// Applies the current font, previewed or saved: text that picks a style reads `typography`, and other text gets
    /// the body font. Push buttons ignore it; title them with `Button(_:font:action:)`.
    func typography(_ settings: SettingsStore) -> some View {
        modifier(TypographyModifier(settings: settings))
    }
}

struct TypographyModifier: ViewModifier {
    let settings: SettingsStore

    func body(content: Content) -> some View {
        let typography = Typography(settings.font)
        content
            .environment(\.typography, typography)
            .font(typography.font(.body))
    }
}
