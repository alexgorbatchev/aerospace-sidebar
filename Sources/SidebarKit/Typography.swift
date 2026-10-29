import AppKit
import SwiftUI

/// Fonts from the `[font]` settings for every text style. Each style keeps its macOS proportion to
/// the body text: at a 13-point base, `.callout` is 12 points, as in the system styles.
struct Typography: Equatable {
    /// The installed family to use, or `nil` for the system font.
    let family: String?
    /// Body text size in points.
    let size: CGFloat
    /// How much wider body text is than in macOS's default font. Widths sized to fit text at the default
    /// font scale with it; the size alone undercounts wide families such as monospaced ones.
    let scale: CGFloat

    /// Text whose width stands for the average width of body text.
    static let widthSample = "The quick brown fox jumps over the lazy dog 0123456789"

    init(_ settings: SidebarSettings.Font) {
        family = Self.installedFamily(named: settings.name)
        // Previews show sizes before Save validates them.
        let range = SidebarSettings.Font.sizeRange
        size = min(max(settings.size, range.lowerBound), range.upperBound)
        scale = Self.sampleWidth(Self.bodyFont(family: family, size: size))
            / Self.sampleWidth(.systemFont(ofSize: SidebarSettings.Font.defaultSize))
    }

    /// `style` in the configured font, `scale` times its size.
    func font(_ style: NSFont.TextStyle, scale: CGFloat = 1) -> Font {
        let size = size(style) * scale
        let font: Font = if let family { .custom(family, fixedSize: size) } else { .system(size: size) }
        return NSFont.preferredFont(forTextStyle: style).fontDescriptor.symbolicTraits.contains(.bold) ? font.bold() : font
    }

    /// The point size of `style`, for text set in another font, such as app icons, to match.
    func size(_ style: NSFont.TextStyle) -> CGFloat {
        size * NSFont.preferredFont(forTextStyle: style).pointSize / NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    /// The body font as an `NSFont`, for AppKit APIs such as the font panel.
    var bodyFont: NSFont { Self.bodyFont(family: family, size: size) }

    private static func bodyFont(family: String?, size: CGFloat) -> NSFont {
        family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) } ?? .systemFont(ofSize: size)
    }

    private static func sampleWidth(_ font: NSFont) -> CGFloat {
        NSAttributedString(string: widthSample, attributes: [.font: font]).size().width
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
