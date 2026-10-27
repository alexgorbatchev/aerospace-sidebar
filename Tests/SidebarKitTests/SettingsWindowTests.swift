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

    @Test(arguments: [
        (SidebarSettings.Font(size: 40), "Size must be between 8 and 32 points."),
        (SidebarSettings.Font(name: "No Such Font Family"), "No installed font family is named “No Such Font Family”."),
    ])
    func rejectsInvalidFont(font: SidebarSettings.Font, status: String) {
        let editor = SettingsEditor(store: store)
        editor.draft.font = font

        #expect(!editor.save())
        #expect(editor.status == status)
        #expect(store.settings.font == SidebarSettings.Font())
    }

    @Test(arguments: [(" menlo ", "Menlo"), ("  ", "")])
    func savesFontFamilyAsInstalled(typed: String, saved: String) {
        let editor = SettingsEditor(store: store)
        editor.draft.font = SidebarSettings.Font(name: typed, size: 15)

        #expect(editor.save())
        #expect(store.settings.font == SidebarSettings.Font(name: saved, size: 15))
    }

    @Test func reportsMissingFontFromFile() throws {
        try directory.write("[font]\nname = \"No Such Font Family\"\n", to: "config.toml")
        store.reload()

        #expect(SettingsEditor(store: store).status == "Font “No Such Font Family” is not installed, so the system font is used.")
    }

    @Test func draftFontPreviewsUntilSavedOrReverted() throws {
        let editor = SettingsEditor(store: store)

        editor.draft.history.maxCount = 300
        #expect(store.fontPreview == nil)

        editor.draft.font.size = 18
        #expect(store.font == SidebarSettings.Font(size: 18))
        #expect(store.settings.font == SidebarSettings.Font())

        editor.revert()
        #expect(store.fontPreview == nil)
        #expect(store.font == SidebarSettings.Font())

        editor.draft.font = SidebarSettings.Font(name: "Menlo", size: 16)
        #expect(editor.save())
        #expect(store.fontPreview == nil)
        #expect(store.font == SidebarSettings.Font(name: "Menlo", size: 16))
        #expect(try store.file.load().font == SidebarSettings.Font(name: "Menlo", size: 16))
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

    func setup() -> SetupPane {
        SetupPane(onboarding: onboarding)
    }

    func general(configURL: URL? = nil, close: @escaping () -> Void = {}) -> GeneralPane {
        GeneralPane(editor: editor, configURL: configURL ?? store.file.url, reveal: { _ in }, chooseFont: {}, quit: {}, close: close)
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
        // Setup steps act immediately; only General has a draft to save.
        #expect(throws: (any Error).self) { try sut.find(button: "Save") }
        #expect(throws: (any Error).self) { try sut.find(button: "Cancel") }
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
        var chooses = 0
        let sut = try GeneralPane(editor: editor, configURL: store.file.url, reveal: { revealed.append($0) }, chooseFont: { chooses += 1 }, quit: {}, close: { closed += 1 }).inspect()

        try sut.find(ViewType.Toggle.self).tap()
        try sut.find(ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Leave notifications with buttons to macOS" }).tap()
        try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Apps left to macOS" }).setInput("zoom.us, Calendar")
        try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Family" }).setInput("Menlo")
        try sut.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Size" }).setInput("15")
        try sut.find(button: "Show in Finder").tap()
        try sut.find(button: "Choose…").tap()
        #expect(chooses == 1)
        #expect(store.settings == SidebarSettings())

        try sut.find(button: "Save").tap()

        #expect(store.settings.notifications == .init(replaceSystem: false, actionableLeftToMacOS: false, appsLeftToMacOS: ["zoom.us", "Calendar"]))
        #expect(store.settings.font == SidebarSettings.Font(name: "Menlo", size: 15))
        #expect(revealed == [store.file.url])
        #expect(closed == 1)
        #expect(throws: Never.self) { try sut.find(text: store.file.url.path) }
    }

    @Test func panesUseFontSettings() throws {
        platform.trusted = false
        loginItems.status = .enabled
        onboarding.refresh()
        let typography = Typography(SidebarSettings.Font(name: "Menlo", size: 18))
        let general = try GeneralPane(editor: editor, configURL: store.file.url, reveal: { _ in }, chooseFont: {}, quit: {}, close: {})
            .environment(\.typography, typography).inspect()
        let setupPane = try setup().environment(\.typography, typography).inspect()
        #expect(throws: Never.self) { try general.find(text: "Family:") }

        #expect(try general.find(text: "Font").attributes().font() == typography.font(.headline))
        #expect(try general.find(text: store.file.url.path).attributes().font() == typography.font(.subheadline))
        for title in ["Save", "Cancel", "Show in Finder", "Choose…", "Quit Sidebar"] {
            #expect(try general.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
        for title in ["Open Accessibility", "Remove", "Copy Settings"] {
            #expect(try setupPane.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
    }

    @Test func quitButtonQuits() throws {
        var quits = 0

        try GeneralPane(editor: editor, configURL: store.file.url, reveal: { _ in }, chooseFont: {}, quit: { quits += 1 }, close: {}).inspect()
            .find(button: "Quit Sidebar").tap()

        #expect(quits == 1)
    }

    @Test func cancelRevertsAndCloses() throws {
        var closed = 0
        editor.draft.history.maxCount = 900

        try GeneralPane(editor: editor, configURL: store.file.url, reveal: { _ in }, chooseFont: {}, quit: {}, close: { closed += 1 }).inspect()
            .find(button: "Cancel").tap()

        #expect(editor.draft == store.settings)
        #expect(closed == 1)
    }

    @Test func invalidSaveStaysOpenAndShowsStatus() throws {
        var closed = 0
        editor.draft.history.retentionHours = 0
        let sut = try general(close: { closed += 1 }).inspect()

        try sut.find(button: "Save").tap()

        #expect(closed == 0)
        #expect(editor.status == "Keep for must be between 1 and 720 hours.")
    }

    @Test func settingsFileUnderHomeIsShownWithTilde() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aerospace-sidebar/config.toml")

        #expect(throws: Never.self) { try general(configURL: url).inspect().find(text: "~/.config/aerospace-sidebar/config.toml") }
    }

    @Test func everyNumberFieldHasArrows() throws {
        #expect(try general().inspect().findAll(ViewType.Stepper.self).count == 3)
    }

    @Test func numberFieldShowsUnit() throws {
        let sut = try NumberField(title: "Keep for", value: .constant(24), unit: "hours").inspect()

        #expect(throws: Never.self) { try sut.find(text: "hours") }
        #expect(throws: (any Error).self) { try sut.find(ViewType.Stepper.self) }
    }

    @Test func fontSizeArrowsStepWithinRange() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GeneralPane(editor: editor, configURL: store.file.url, reveal: { _ in }, chooseFont: {}, quit: {}, close: {}))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // AppKit's steppers carry no label; Size is the pane's last number field, so its arrows are lowest.
        let stepper = try #require(Self.subviews(of: host).compactMap { $0 as? NSStepper }.max { a, b in
            a.convert(a.bounds, to: host).minY < b.convert(b.bounds, to: host).minY
        })

        Self.click(stepper, up: true)
        #expect(editor.draft.font.size == 14)
        #expect(store.font.size == 14)
        Self.click(stepper, up: false)
        Self.click(stepper, up: false)
        #expect(editor.draft.font.size == 12)

        editor.draft.font.size = SidebarSettings.Font.sizeRange.upperBound
        host.layoutSubtreeIfNeeded()
        Self.click(stepper, up: true)
        #expect(editor.draft.font.size == SidebarSettings.Font.sizeRange.upperBound)
        editor.draft.font.size = SidebarSettings.Font.sizeRange.lowerBound
        host.layoutSubtreeIfNeeded()
        Self.click(stepper, up: false)
        #expect(editor.draft.font.size == SidebarSettings.Font.sizeRange.lowerBound)
    }

    /// What a click on an arrow does: SwiftUI's stepper reads the direction of the change.
    private static func click(_ stepper: NSStepper, up: Bool) {
        stepper.doubleValue += up ? stepper.increment : -stepper.increment
        stepper.sendAction(stepper.action, to: stepper.target)
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
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
        #expect(controller.window.isFloatingPanel)
        #expect(controller.window.level == .floating)
        #expect(controller.window.contentRect(forFrameRect: controller.window.frame).width == SettingsMetrics.paneWidth)
        #expect(controller.editor.draft == store.settings)

        controller.editor.draft.history.maxCount = 999
        controller.window.close()
        #expect(controller.editor.draft == store.settings)
    }

    @Test func quitButtonTerminatesApp() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        var terminateCalls = 0
        let controller = SettingsWindowController(store: store, onboarding: OnboardingModel(
            accessibility: FakePlatform(),
            loginItems: FakeLoginItems(),
            setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
            performer: RecordingPerformer(),
            copy: { _ in }
        ), reveal: { _ in }, terminate: { _ in terminateCalls += 1 })
        let general = try #require(
            controller.tabs.tabViewItems[1].viewController as? NSHostingController<ModifiedContent<GeneralPane, TypographyModifier>>
        )

        try general.rootView.content.inspect().find(button: "Quit Sidebar").tap()

        #expect(terminateCalls == 1)
    }

    @Test func fontPanelPicksGoIntoTheDraftUntilTheWindowCloses() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let picked = try #require(NSFont(name: "Menlo-Regular", size: 16))
        let controller = SettingsWindowController(store: store, onboarding: OnboardingModel(
            accessibility: FakePlatform(),
            loginItems: FakeLoginItems(),
            setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
            performer: RecordingPerformer(),
            copy: { _ in }
        ), fontChooser: FontChooser(panel: { panel }, convert: { _ in picked }), reveal: { _ in })
        controller.show()

        controller.chooseFont()
        try #require(NSFontManager.shared.target as? FontChooser).changeFont(NSFontManager.shared)

        #expect(controller.editor.draft.font == SidebarSettings.Font(name: "Menlo", size: 16))
        #expect(store.settings.font == SidebarSettings.Font())
        controller.window.close()
        #expect(!panel.isVisible)
        #expect(NSFontManager.shared.target == nil)
    }

    @Test func eachTabSizesTheWindowToItsOwnContent() throws {
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
        controller.show()
        let setup = controller.window.frame

        controller.tabs.selectedTabViewItemIndex = 1
        let general = controller.window.frame
        controller.tabs.selectedTabViewItemIndex = 0

        #expect(general.height > setup.height)
        #expect(general.maxY == setup.maxY)
        #expect(controller.window.frame == setup)
        controller.window.close()
    }

    @Test func windowFollowsSetupContentThatChangesWhileOpen() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let onboarding = OnboardingModel(
            accessibility: FakePlatform(),
            loginItems: FakeLoginItems(),
            setup: AeroSpaceSetup(home: directory.url, environment: [:], cli: FakeAeroSpaceCLI()),
            performer: RecordingPerformer(),
            copy: { _ in }
        )
        let controller = SettingsWindowController(store: store, onboarding: onboarding, reveal: { _ in })
        controller.show()
        let before = controller.window.frame

        // A config with problems adds warning lines to the Setup pane.
        try directory.write("[mode.main.binding]\nalt-f = 'fullscreen --no-outer-gaps'\n", to: ".aerospace.toml")
        onboarding.refresh()
        for _ in 0..<100 where controller.window.frame.height == before.height {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.window.frame.height > before.height)
        #expect(controller.window.frame.maxY == before.maxY)
        controller.window.close()
    }

    @Test func previewResizesWindowAndCancelRestoresIt() throws {
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
        controller.show()
        let before = controller.window.frame

        controller.editor.draft.font.size = 26
        #expect(controller.window.frame.height > before.height)

        controller.editor.revert()
        #expect(controller.window.frame == before)
        controller.window.close()
    }

    @Test func resizesWithFontSizeKeepingTopEdge() throws {
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
        let before = controller.window.frame

        store.update { $0.font.size = 26 }

        #expect(controller.window.frame.height > before.height)
        let width = SettingsMetrics.paneWidth * Typography(SidebarSettings.Font(size: 26)).scale
        #expect(abs(controller.window.contentRect(forFrameRect: controller.window.frame).width - width) <= 1)
        #expect(controller.window.frame.maxY == before.maxY)
        #expect(controller.window.frame.minX == before.minX)
    }
}
