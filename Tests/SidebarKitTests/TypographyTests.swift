import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct TypographyTests {
    @Test func defaultsMatchMacOSTextStyles() {
        let typography = Typography(SidebarSettings.Font())

        #expect(typography.family == nil)
        #expect(typography.font(.body) == .system(size: 13))
        #expect(typography.font(.headline) == .system(size: 13).bold())
        #expect(typography.font(.callout) == .system(size: 12))
        #expect(typography.font(.subheadline) == .system(size: 11))
        #expect(typography.font(.caption1) == .system(size: 10))
        #expect(typography.size(.caption1) == 10)
    }

    @Test func everyStyleScalesWithTheBaseSize() {
        let typography = Typography(SidebarSettings.Font(size: 26))

        #expect(typography.font(.body) == .system(size: 26))
        #expect(typography.font(.callout) == .system(size: 24))
        #expect(typography.font(.caption1) == .system(size: 20))
        // Large sizes use the system font's tighter display design, so text grows a little less than 2×.
        #expect(typography.scale > 1.7 && typography.scale <= 2)
    }

    @Test func widthScaleCountsHowWideTheFamilyIs() {
        #expect(Typography(SidebarSettings.Font()).scale == 1)
        // Monospaced Menlo is wider than the system font at the same size.
        #expect(Typography(SidebarSettings.Font(name: "Menlo", size: 13)).scale > 1.1)
    }

    @Test func usesInstalledFamilyMatchedIgnoringCase() {
        let typography = Typography(SidebarSettings.Font(name: " menlo ", size: 15))

        #expect(typography.family == "Menlo")
        #expect(typography.font(.body) == .custom("Menlo", fixedSize: 15))
        #expect(typography.font(.headline) == .custom("Menlo", fixedSize: 15).bold())
    }

    @Test func bodyFontIsTheAppKitFontOfTheSettings() {
        #expect(Typography(SidebarSettings.Font(name: "Menlo", size: 15)).bodyFont.familyName == "Menlo")
        #expect(Typography(SidebarSettings.Font(name: "Menlo", size: 15)).bodyFont.pointSize == 15)
        #expect(Typography(SidebarSettings.Font(size: 14)).bodyFont == .systemFont(ofSize: 14))
    }

    @Test(arguments: [(2.0, 8.0), (500.0, 32.0)])
    func previewSizesStayInRange(size: Double, rendered: CGFloat) {
        #expect(Typography(SidebarSettings.Font(size: size)).size == rendered)
    }

    @Test func missingFamilyFallsBackToSystemFont() {
        let typography = Typography(SidebarSettings.Font(name: "No Such Font Family", size: 13))

        #expect(typography.family == nil)
        #expect(typography.font(.body) == .system(size: 13))
    }

    @Test func modifierAppliesCurrentSettingsToTextWithoutAStyle() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        store.update { $0.font = SidebarSettings.Font(name: "Menlo", size: 18) }

        #expect(try Text("plain").typography(store).inspect().find(text: "plain").attributes().font() == .custom("Menlo", fixedSize: 18))

        store.preview(font: SidebarSettings.Font(size: 20))

        #expect(try Text("plain").typography(store).inspect().find(text: "plain").attributes().font() == .system(size: 20))
    }
}
