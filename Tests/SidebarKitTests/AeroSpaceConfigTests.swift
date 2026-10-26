import Foundation
import SidebarKit
import Testing

struct AeroSpaceConfigTests {
    @Test func sidebarWidthIsMainGapMinusFallback() throws {
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

        #expect(config.sidebarWidth == 300)
    }

    @Test(arguments: [
        "",
        "[gaps]\nouter.left = 5",
        "[gaps]\nouter.right = 305",
        "[gaps]\nouter.right = [{ monitor.secondary = 305 }, 5]",
    ])
    func rejectsConfigWithoutMainMonitorGap(toml: String) {
        #expect(throws: AeroSpaceConfig.Error.noMainMonitorGap) {
            try AeroSpaceConfig(toml: toml)
        }
    }

    @Test func rejectsMainGapNotWiderThanFallback() {
        #expect(throws: AeroSpaceConfig.Error.gapNotWiderThanFallback(main: 5, fallback: 5)) {
            try AeroSpaceConfig(toml: "[gaps]\nouter.right = [{ monitor.main = 5 }, 5]")
        }
    }

    @Test func loadsFromXDGConfigHome() throws {
        let home = try TemporaryDirectory()
        let xdg = home.url.appendingPathComponent("xdg")
        try home.write("[gaps]\nouter.right = [{ monitor.main = 250 }, 10]", to: "xdg/aerospace/aerospace.toml")

        let config = try AeroSpaceConfig.load(home: home.url, environment: ["XDG_CONFIG_HOME": xdg.path])

        #expect(config.sidebarWidth == 240)
    }

    @Test func loadsFromHomeDotfile() throws {
        let home = try TemporaryDirectory()
        try home.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]", to: ".aerospace.toml")

        let config = try AeroSpaceConfig.load(home: home.url, environment: [:])

        #expect(config.sidebarWidth == 300)
    }

    @Test func rejectsAmbiguousConfigLocations() throws {
        let home = try TemporaryDirectory()
        try home.write("", to: ".aerospace.toml")
        try home.write("", to: ".config/aerospace/aerospace.toml")

        #expect(throws: AeroSpaceConfig.Error.ambiguous([
            home.url.appendingPathComponent(".aerospace.toml"),
            home.url.appendingPathComponent(".config/aerospace/aerospace.toml"),
        ])) {
            try AeroSpaceConfig.load(home: home.url, environment: [:])
        }
    }

    @Test func reportsSearchedLocationsWhenMissing() throws {
        let home = try TemporaryDirectory()

        #expect(throws: AeroSpaceConfig.Error.notFound(searched: [
            home.url.appendingPathComponent(".aerospace.toml"),
            home.url.appendingPathComponent(".config/aerospace/aerospace.toml"),
        ])) {
            try AeroSpaceConfig.load(home: home.url, environment: [:])
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
