import AppKit
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct OnboardingModelTests {
    let home: TemporaryDirectory
    let platform = FakePlatform()
    let loginItems = FakeLoginItems()
    let performer = RecordingPerformer()
    let cli = FakeAeroSpaceCLI()
    var copied: [String] = []

    init() throws {
        home = try TemporaryDirectory()
        platform.trusted = false
    }

    func model(onUpdated: @escaping @MainActor () -> Void = {}, copy: @escaping @MainActor (String) -> Void = { _ in }) -> OnboardingModel {
        OnboardingModel(
            accessibility: platform,
            loginItems: loginItems,
            setup: AeroSpaceSetup(home: home.url, environment: [:], cli: cli),
            performer: performer,
            copy: copy,
            onAeroSpaceUpdated: onUpdated
        )
    }

    @Test func refreshesLiveState() throws {
        let sut = model()
        #expect(!sut.accessibilityGranted && sut.loginItem == .disabled && sut.aeroSpace == .notFound)

        platform.trusted = true
        loginItems.status = .enabled
        try home.write("", to: ".aerospace.toml")
        sut.refresh()

        #expect(sut.accessibilityGranted && sut.loginItem == .enabled)
        guard case .ready = sut.aeroSpace else { Issue.record("expected ready"); return }
    }

    @Test func requestsAccessibilityWithPromptAndOpensSettings() {
        let sut = model()

        sut.requestAccessibility()

        #expect(platform.promptRequests.contains(true))
        #expect(performer.actions == [.open(SidebarModel.accessibilitySettingsURL)])
    }

    @Test func managesLoginItem() {
        let sut = model()

        sut.addLoginItem()
        #expect(sut.loginItem == .enabled)
        #expect(sut.message == "AerospaceSidebar opens at login.")

        sut.removeLoginItem()
        #expect(sut.loginItem == .disabled)
        #expect(sut.message == "AerospaceSidebar no longer opens at login.")

        loginItems.statusAfterRegister = .requiresApproval
        sut.addLoginItem()
        #expect(sut.message?.contains("Login Items") == true)

        sut.openLoginItemsSettings()
        #expect(loginItems.openedSettings == 1)
    }

    @Test func reportsLoginItemFailures() {
        loginItems.error = CocoaError(.fileWriteNoPermission)
        let sut = model()

        sut.addLoginItem()
        #expect(sut.message?.hasPrefix("Cannot add the login item") == true)
        sut.removeLoginItem()
        #expect(sut.message?.hasPrefix("Cannot remove the login item") == true)
    }

    @Test func updatesAeroSpaceAndNotifies() async throws {
        try home.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        var updates = 0
        let sut = model(onUpdated: { updates += 1 })

        await sut.updateAeroSpace()

        #expect(updates == 1)
        #expect(sut.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        #expect(!sut.isUpdatingAeroSpace)
        guard case .ready(let analysis, _) = sut.aeroSpace else { Issue.record("expected ready"); return }
        #expect(analysis.isConfigured)
    }

    @Test func explainsUpdateWithoutReload() async throws {
        try home.write("", to: ".config/aerospace/aerospace.toml")
        let sut = OnboardingModel(
            accessibility: platform,
            loginItems: loginItems,
            setup: AeroSpaceSetup(home: home.url, environment: [:], cli: FakeAeroSpaceCLI(results: ["--dry-run": CommandResult(status: 127, output: "")])),
            performer: performer
        )

        await sut.updateAeroSpace()

        #expect(sut.message?.contains("Reload AeroSpace yourself") == true)
    }

    @Test func reportsUpdateFailure() async {
        var updates = 0
        let sut = model(onUpdated: { updates += 1 })

        await sut.updateAeroSpace()

        #expect(updates == 0)
        #expect(sut.message?.hasPrefix("No AeroSpace config found") == true)
    }

    @Test(arguments: [
        (AeroSpaceSetup.SetupError.notFound, "No AeroSpace config found"),
        (.generated(URL(fileURLWithPath: "/c/aerospace.toml")), "aerospace.toml is generated"),
        (.unsupported("odd"), "automatically: odd"),
        (.rejected("bad"), "original config was restored: bad"),
        (.io("disk"), "Cannot update the config: disk"),
    ])
    func describesSetupErrors(error: AeroSpaceSetup.SetupError, fragment: String) {
        #expect(OnboardingModel.describe(error).contains(fragment))
    }

    @Test func copiesSnippetThatConfiguresAnEmptyConfig() {
        var copied: [String] = []
        let sut = model(copy: { copied.append($0) })

        sut.copySnippet()

        #expect(copied == [OnboardingModel.snippet])
        #expect(AeroSpaceConfigEditor.analyze(OnboardingModel.snippet).isConfigured)
        #expect(sut.message?.hasPrefix("Copied") == true)
    }

    @Test func revealsConfigFolderOnlyWhenFound() throws {
        let sut = model()
        sut.revealAeroSpaceConfig()
        #expect(performer.actions.isEmpty)

        try home.write("", to: ".aerospace.toml")
        sut.refresh()
        sut.revealAeroSpaceConfig()
        #expect(performer.actions == [.open(home.url.resolvingSymlinksInPath())] || performer.actions == [.open(home.url)])
    }

    @Test func copyToPasteboardWritesString() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }

        OnboardingModel.copyToPasteboard("snippet-\(getpid())")

        #expect(pasteboard.string(forType: .string) == "snippet-\(getpid())")
    }

    @Test func realLoginItemReportsStatusWithoutRegistering() {
        #expect([.enabled, .disabled, .requiresApproval, .unavailable].contains(MainAppLoginItem().status))
    }
}
