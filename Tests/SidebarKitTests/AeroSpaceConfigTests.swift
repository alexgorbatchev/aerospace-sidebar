import Foundation
@testable import SidebarKit
import Testing

struct AeroSpaceConfigTests {
    @Test func readsBothOuterGaps() throws {
        let toml = """
            start-at-login = true

            [gaps]
            inner.horizontal = 10
            outer.left       = 5
            outer.right      = [{ monitor."^LG.*" = 50 }, { monitor.main = 305 }, 5]

            [[on-window-detected]]
            if = 'test %{app-bundle-id} = com.example'
            run = 'layout floating'

            [mode.main.binding]
            alt-f = 'fullscreen'
            """

        let config = try AeroSpaceConfig(toml: toml)

        #expect(config.gap(on: .left) == AeroSpaceConfig.Gap(fallback: 5))
        #expect(config.gap(on: .right) == AeroSpaceConfig.Gap(fallback: 5, monitors: [.init(pattern: "^LG.*", value: 50), .init(pattern: "main", value: 305)]))
        #expect(config.gap(on: .right).main == 305)
        #expect(config.gap(on: .left).reservedWidth == nil)
        #expect(config.gap(on: .right).reservedWidth == 300)
    }

    @Test(arguments: [
        ("", nil as Int?),
        ("[gaps]\nouter.left = 305", nil),
        ("[gaps]\nouter.left = [{ monitor.secondary = 305 }, 5]", nil),
        ("[gaps]\nouter.left = [{ monitor.main = 5 }, 5]", nil),
        ("[gaps.outer]\nleft = [{ monitor.main = 250 }, 10]", 240),
    ])
    func reservesOnlyAMainEntryWiderThanTheFallback(toml: String, reserved: Int?) throws {
        #expect(try AeroSpaceConfig(toml: toml).gap(on: .left).reservedWidth == reserved)
    }

    @Test(arguments: [
        "[gaps]\nouter.right = [{ monitor.main = 305 }]",
        "[gaps]\nouter.right = [{ monitor = { main = 1, secondary = 2 } }, 0]",
    ])
    func rejectsGapsItCannotKeepInOrder(toml: String) {
        #expect(throws: AeroSpaceConfig.Error.unsupportedGap(side: .right)) {
            try AeroSpaceConfig(toml: toml)
        }
    }

    @Test func locatesXDGConfigHome() throws {
        let home = try TemporaryDirectory()
        let xdg = home.url.appendingPathComponent("xdg")
        try home.write("", to: "xdg/aerospace/aerospace.toml")

        #expect(try AeroSpaceConfig.locate(home: home.url, environment: ["XDG_CONFIG_HOME": xdg.path])
            == xdg.appendingPathComponent("aerospace/aerospace.toml"))
    }

    @Test func locatesHomeDotfile() throws {
        let home = try TemporaryDirectory()
        try home.write("", to: ".aerospace.toml")

        #expect(try AeroSpaceConfig.locate(home: home.url, environment: [:]) == home.url.appendingPathComponent(".aerospace.toml"))
    }

    @Test func rejectsAmbiguousConfigLocations() throws {
        let home = try TemporaryDirectory()
        try home.write("", to: ".aerospace.toml")
        try home.write("", to: ".config/aerospace/aerospace.toml")

        #expect(throws: AeroSpaceConfig.Error.ambiguous([
            home.url.appendingPathComponent(".aerospace.toml"),
            home.url.appendingPathComponent(".config/aerospace/aerospace.toml"),
        ])) {
            try AeroSpaceConfig.locate(home: home.url, environment: [:])
        }
    }

    @Test func reportsSearchedLocationsWhenMissing() throws {
        let home = try TemporaryDirectory()

        #expect(throws: AeroSpaceConfig.Error.notFound(searched: [
            home.url.appendingPathComponent(".aerospace.toml"),
            home.url.appendingPathComponent(".config/aerospace/aerospace.toml"),
        ])) {
            try AeroSpaceConfig.locate(home: home.url, environment: [:])
        }
    }
}

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
}
