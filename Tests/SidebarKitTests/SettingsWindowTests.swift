import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
struct SettingsEditorTests {
    let directory: TemporaryDirectory
    let store: SettingsStore

    init() throws {
        directory = try TemporaryDirectory()
        store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
    }

    @Test func editsStayInDraftUntilSaved() throws {
        let editor = SettingsEditor(store: store)

        editor.draft.history.maxCount = 500
        #expect(editor.isDirty)
        #expect(store.settings.history.maxCount == 200)

        #expect(editor.save())
        #expect(!editor.isDirty)
        #expect(try store.file.load().history.maxCount == 500)
        #expect(editor.status == nil)
    }

    @Test func revertDiscardsDraft() {
        let editor = SettingsEditor(store: store)
        editor.draft.notifications.replaceSystem = false

        editor.revert()

        #expect(editor.draft == store.settings)
    }

    @Test func externalChangesReplaceCleanDraftOnly() {
        let editor = SettingsEditor(store: store)
        store.update { $0.history.retentionHours = 6 }
        #expect(editor.draft.history.retentionHours == 6)

        editor.draft.history.maxCount = 20
        store.update { $0.history.retentionHours = 7 }
        #expect(editor.draft.history.retentionHours == 6)
        #expect(editor.draft.history.maxCount == 20)
    }

    @Test func appsTextSplitsAndTrims() {
        let editor = SettingsEditor(store: store)

        editor.appsLeftToMacOSText = " zoom.us ,Calendar,, "

        #expect(editor.draft.notifications.appsLeftToMacOS == ["zoom.us", "Calendar"])
        #expect(editor.appsLeftToMacOSText == "zoom.us, Calendar")
    }

    @Test(arguments: [
        (0, 200, "Keep for must be between 1 and 720 hours."),
        (24, 5000, "Keep at most must be between 10 and 2000 notifications."),
    ])
    func rejectsOutOfRangeValues(hours: Int, count: Int, status: String) {
        let editor = SettingsEditor(store: store)
        editor.draft.history = SidebarSettings.History(retentionHours: hours, maxCount: count)

        #expect(!editor.save())
        #expect(editor.status == status)
        #expect(store.settings.history == SidebarSettings.History())
    }

    @Test func reportsSaveFailure() {
        let unwritable = SettingsStore(file: SettingsFile(url: URL(fileURLWithPath: "/nonexistent-root/config.toml")))
        let editor = SettingsEditor(store: unwritable)
        editor.draft.history.maxCount = 300

        #expect(!editor.save())
        #expect(editor.status?.hasPrefix("Couldn't save settings:") == true)
    }

    @Test func reportsInvalidFile() throws {
        try directory.write("[history\n", to: "config.toml")
        store.reload()

        #expect(SettingsEditor(store: store).status?.hasPrefix("config.toml is invalid") == true)
    }
}

@MainActor
struct SettingsPaneTests {
    let directory: TemporaryDirectory
    let store: SettingsStore
    let editor: SettingsEditor
    let platform = FakePlatform()
    let loginItems = FakeLoginItems()
    let onboarding: OnboardingModel

    init() throws {
        directory = try TemporaryDirectory()
        store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        editor = SettingsEditor(store: store)
        onboarding = OnboardingModel(
            accessibility: platform,
            loginItems: loginItems,
            setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
            performer: RecordingPerformer(),
            copy: { _ in }
        )
    }

    func setup(close: @escaping () -> Void = {}) -> SetupPane {
        SetupPane(onboarding: onboarding, editor: editor, close: close)
    }

    @Test func setupOffersActionsForMissingSteps() throws {
        platform.trusted = false
        onboarding.refresh()
        let sut = try setup().inspect()
        #expect(throws: Never.self) { try sut.find(text: "AerospaceSidebar does not open at login.") }
        #expect(try sut.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Not done" }).count == 3)

        try sut.find(button: "Open Accessibility").tap()
        try sut.find(button: "Add to Login Items").tap()
        try sut.find(button: "Copy Settings").tap()

        #expect(platform.promptRequests.contains(true))
        #expect(loginItems.status == .enabled)
        #expect(throws: Never.self) { try sut.find(text: "No AeroSpace config found.") }
        #expect(throws: Never.self) { try sut.find(button: "Update AeroSpace Config") }
    }

    @Test func finishedStepsShowCheckmarks() throws {
        loginItems.status = .enabled
        try directory.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        onboarding.refresh()
        let sut = try setup().inspect()

        for done in ["Accessibility granted", "Opens at login", "AeroSpace configured"] {
            #expect(throws: Never.self) { try sut.find(text: done) }
        }
        #expect(try sut.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Done" }).count == 3)
        #expect(throws: (any Error).self) { try sut.find(button: "Open Accessibility") }
        #expect(throws: Never.self) { try sut.find(text: ".aerospace.toml reserves 300 points for the sidebar.") }
        try sut.find(button: "Remove").tap()
        #expect(loginItems.status == .disabled)
    }

    @Test func setupShowsApprovalWarningsAndUnreadableStates() throws {
        loginItems.status = .requiresApproval
        try directory.write("[mode.main.binding]\nalt-f = 'fullscreen --no-outer-gaps'\n", to: ".aerospace.toml")
        onboarding.refresh()
        let sut = try setup().inspect()

        try sut.find(button: "Open Login Items").tap()
        #expect(loginItems.openedSettings == 1)
        #expect(throws: Never.self) { try sut.find(text: ".aerospace.toml is missing the sidebar gap and the floating rule.") }
        #expect(throws: Never.self) { try sut.find(textWhere: { text, _ in text.contains("--no-outer-gaps") }) }

        try directory.write("", to: ".config/aerospace/aerospace.toml")
        loginItems.status = .unavailable
        onboarding.refresh()
        let refreshed = try setup().inspect()
        #expect(throws: Never.self) { try refreshed.find(textWhere: { text, _ in text.hasPrefix("Cannot read the AeroSpace config") }) }
        #expect(throws: Never.self) { try refreshed.find(text: "Install the app in Applications to open it at login.") }
    }

    @Test func updateButtonEditsAeroSpaceConfig() async throws {
        try directory.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        onboarding.refresh()

        try setup().inspect().find(button: "Update AeroSpace Config").tap()
        for _ in 0..<100 where onboarding.message == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(onboarding.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
    }

    @Test func generalPaneEditsDraftAndSaves() throws {
        var closed = 0
        var revealed: [URL] = []
        let sut = try GeneralPane(editor: editor, configURL: store.file.url, reveal: { revealed.append($0) }, close: { closed += 1 }).inspect()

        try sut.find(ViewType.Toggle.self).tap()
        try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Apps left to macOS" }).setInput("zoom.us, Calendar")
        try sut.find(button: "Show in Finder").tap()
        #expect(store.settings == SidebarSettings())

        try sut.find(button: "Save").tap()

        #expect(store.settings.notifications == .init(replaceSystem: false, appsLeftToMacOS: ["zoom.us", "Calendar"]))
        #expect(revealed == [store.file.url])
        #expect(closed == 1)
        #expect(throws: Never.self) { try sut.find(text: store.file.url.path) }
    }

    @Test func cancelRevertsAndCloses() throws {
        var closed = 0
        editor.draft.history.maxCount = 900

        try GeneralPane(editor: editor, configURL: store.file.url, reveal: { _ in }, close: { closed += 1 }).inspect()
            .find(button: "Cancel").tap()

        #expect(editor.draft == store.settings)
        #expect(closed == 1)
    }

    @Test func invalidSaveStaysOpenAndShowsStatus() throws {
        var closed = 0
        editor.draft.history.retentionHours = 0
        let sut = try setup(close: { closed += 1 }).inspect()

        try sut.find(button: "Save").tap()

        #expect(closed == 0)
        #expect(editor.status == "Keep for must be between 1 and 720 hours.")
    }

    @Test func numberFieldShowsUnit() throws {
        let sut = try NumberField(title: "Keep for", value: .constant(24), unit: "hours").inspect()

        #expect(throws: Never.self) { try sut.find(text: "hours") }
    }
}

@MainActor
struct SettingsWindowControllerTests {
    @Test func opensOnSetupTabInFrontWithoutActivatingTheApp() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let controller = SettingsWindowController(store: store, onboarding: OnboardingModel(
            accessibility: FakePlatform(),
            loginItems: FakeLoginItems(),
            setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
            performer: RecordingPerformer(),
            copy: { _ in }
        ), reveal: { _ in })
        controller.tabs.selectedTabViewItemIndex = 1
        controller.editor.draft.history.maxCount = 999

        controller.show()

        #expect(controller.window.isVisible)
        #expect(controller.tabs.selectedTabViewItemIndex == 0)
        #expect(controller.tabs.tabViewItems.map(\.label) == ["Setup", "General"])
        #expect(controller.window.styleMask.contains(.nonactivatingPanel))
        #expect(!controller.window.styleMask.contains(.resizable))
        #expect(!controller.window.hidesOnDeactivate)
        #expect(controller.window.contentRect(forFrameRect: controller.window.frame).width == SettingsMetrics.paneWidth)
        #expect(controller.editor.draft == store.settings)

        controller.editor.draft.history.maxCount = 999
        controller.window.close()
        #expect(controller.editor.draft == store.settings)
    }
}
