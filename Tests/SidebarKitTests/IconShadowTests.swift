import AppKit
@testable import SidebarKit
import SwiftUI
import Testing

@MainActor
struct IconShadowTests {
    static let side = 1024

    /// Alpha, 0…255, at each point of a `side`-pixel square image, top-left origin.
    func alphas(of image: CGImage, at points: [(x: Int, y: Int)]) -> [Int] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return points.map { Int(((bitmap.colorAt(x: $0.x, y: $0.y)?.alphaComponent ?? 0) * 255).rounded()) }
    }

    /// An app icon as macOS draws it, shadow included.
    func appIcon(_ path: String) throws -> CGImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        return try #require(icon.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    /// A shape filling an app icon's artwork area, shadowed by `IconShadow`.
    func shadowedArtwork() throws -> CGImage {
        let artwork = CGFloat(Self.side) * NotificationCard.iconArtwork
        let view = Rectangle().fill(.white).frame(width: artwork, height: artwork)
            .frame(width: CGFloat(Self.side), height: CGFloat(Self.side))
            .modifier(IconShadow())
            .frame(width: CGFloat(Self.side), height: CGFloat(Self.side))
        return try render(view)
    }

    func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    /// Points just outside the artwork, above, below and beside it.
    var outside: [(x: Int, y: Int)] {
        let center = Self.side / 2
        return [76, 80, 88, 96, 99].map { (center, $0) }
            + [924, 928, 936, 944, 952, 960].map { (center, $0) }
            + [72, 80, 88, 96].map { ($0, center) }
    }

    /// The shadow falls off around the artwork the way it does around a system app icon: above, below and
    /// beside it, so a font icon looks like it sits on the card as an app icon does.
    @Test func matchesTheShadowOfSystemAppIcons() throws {
        let expected = alphas(of: try appIcon("/System/Applications/Notes.app"), at: outside)
        let actual = alphas(of: try shadowedArtwork(), at: outside)

        #expect(expected.contains { $0 > 10 })
        for (expected, actual) in zip(expected, actual) {
            #expect(abs(expected - actual) <= 3)
        }
    }
}
