import AppKit
import PermissionFlow
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
        rejectsDraft(status: status) { $0.history = SidebarSettings.History(retentionHours: hours, maxCount: count) }
    }

    @Test func rejectsOutOfRangeWidth() {
        rejectsDraft(status: "Width must be between 150 and 1000 points.") { $0.sidebar.width = 20 }
    }

    func rejectsDraft(status: String, _ change: (inout SidebarSettings) -> Void) {
        let editor = SettingsEditor(store: store)
        change(&editor.draft)

        #expect(!editor.save())
        #expect(editor.status == status)
        #expect(store.settings == SidebarSettings())
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
@Suite(.leavesDesktopAlone)
struct SettingsPaneTests {
    let directory: TemporaryDirectory
    let store: SettingsStore
    let editor: SettingsEditor
    let permissions = FakePermissions()
    let loginItems = FakeLoginItems()
    let onboarding: OnboardingModel
    let aeroSpace: AeroSpaceSync

    init() throws {
        directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        self.store = store
        editor = SettingsEditor(store: store)
        onboarding = OnboardingModel(permissions: permissions, loginItems: loginItems)
        aeroSpace = .fake(store: store, home: directory.url)
    }

    func permissionsPane() -> PermissionsPane {
        PermissionsPane(onboarding: onboarding)
    }

    func sidebarPane(reveal: @escaping (URL) -> Void = { _ in }, close: @escaping () -> Void = {}) -> SidebarPane {
        SidebarPane(editor: editor, aeroSpace: aeroSpace, reveal: reveal, close: close)
    }

    func appearance(chooseFont: @escaping () -> Void = {}, close: @escaping () -> Void = {}) -> AppearancePane {
        AppearancePane(editor: editor, chooseFont: chooseFont, close: close)
    }

    func general(configURL: URL? = nil, reveal: @escaping (URL) -> Void = { _ in }, quit: @escaping () -> Void = {}) -> GeneralPane {
        GeneralPane(configURL: configURL ?? store.file.url, reveal: reveal, quit: quit)
    }

    func history(close: @escaping () -> Void = {}) -> HistoryPane {
        HistoryPane(editor: editor, close: close)
    }

    /// Every permission is on one page with why the sidebar needs it; a granted one shows a checkmark only.
    @Test func permissionsOfferStepsUntilGranted() throws {
        onboarding.refresh()
        let sut = try permissionsPane().inspect()
        #expect(try sut.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Not done" }).count == 3)
        #expect(throws: Never.self) { try sut.find(textWhere: { text, _ in text == "Required to read and hide banners." }) }
        #expect(throws: Never.self) { try sut.find(textWhere: { text, _ in text.hasPrefix("Optional. Lists notifications that showed no banner") }) }
        #expect(throws: Never.self) { try sut.find(text: "Optional. Starts the sidebar when you log in.") }

        try sut.find(button: "Open Full Disk Access").tap()
        try sut.find(button: "Open Accessibility").tap()
        #expect(permissions.authorized == [.fullDiskAccess, .accessibility])

        permissions.states = [.accessibility: .granted, .fullDiskAccess: .granted]
        loginItems.status = .enabled
        onboarding.refresh()
        let granted = try permissionsPane().inspect()
        #expect(try granted.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Done" }).count == 3)
        // The checkmark says it; no text repeats it.
        for done in ["Accessibility granted", "Full Disk Access granted", "Opens at login"] {
            #expect(throws: (any Error).self) { try granted.find(text: done) }
        }
        #expect(throws: (any Error).self) { try granted.find(button: "Open Accessibility") }
        #expect(try granted.findAll(ViewType.Button.self, where: { try $0.labelView().text().string() == "Remove" }).count == 3)
    }

    /// Remove takes the app off each permission's list in System Settings and reports the result.
    @Test func permissionsCanBeRemoved() async throws {
        permissions.states = [.accessibility: .granted, .fullDiskAccess: .granted]
        onboarding.refresh()
        let removes = try permissionsPane().inspect().findAll(ViewType.Button.self, where: { try $0.labelView().text().string() == "Remove" })

        try removes[0].tap()
        for _ in 0..<100 where onboarding.accessibilityGranted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(permissions.resets == [.accessibility])
        #expect(!onboarding.accessibilityGranted)
        #expect(onboarding.message == "Removed AerospaceSidebar from Accessibility.")

        permissions.resetResult = CommandResult(status: 70, output: "tccutil: Failed to reset SystemPolicyAllFiles\n")
        await onboarding.removeFullDiskAccess()
        #expect(permissions.resets == [.accessibility, .fullDiskAccess])
        #expect(onboarding.fullDiskAccessGranted)
        #expect(onboarding.message == "Cannot remove AerospaceSidebar from Full Disk Access: tccutil: Failed to reset SystemPolicyAllFiles")
    }

    @Test func permissionsManageLoginItem() throws {
        onboarding.refresh()
        let disabled = try permissionsPane().inspect()
        #expect(try disabled.findAll(ViewType.Button.self, where: { try $0.labelView().text().string() == "Remove" }).count == 2)
        try disabled.find(button: "Add to Login Items").tap()
        #expect(loginItems.status == .enabled)

        let enabled = try permissionsPane().inspect()
        try enabled.findAll(ViewType.Button.self, where: { try $0.labelView().text().string() == "Remove" })[2].tap()
        #expect(loginItems.status == .disabled)

        loginItems.status = .requiresApproval
        onboarding.refresh()
        let approval = try permissionsPane().inspect()
        try approval.find(button: "Open Login Items").tap()
        #expect(loginItems.openedSettings == 1)
        #expect(throws: Never.self) { try approval.find(text: "Allow it in System Settings › General › Login Items.") }

        loginItems.status = .unavailable
        onboarding.refresh()
        #expect(throws: Never.self) { try permissionsPane().inspect().find(text: "Install the app in Applications to open it at login.") }
    }

    /// Permissions and General act immediately; the draft panes end with Cancel and Save.
    @Test func onlyDraftPanesHaveSaveAndCancel() throws {
        let immediate: [any View] = [permissionsPane(), general()]
        let draft: [any View] = [sidebarPane(), NotificationsPane(editor: editor, close: {}), history(), appearance()]
        for pane in immediate {
            let sut = try AnyView(pane).inspect()
            #expect(throws: (any Error).self) { try sut.find(button: "Save") }
            #expect(throws: (any Error).self) { try sut.find(button: "Cancel") }
        }
        for pane in draft {
            let sut = try AnyView(pane).inspect()
            #expect(throws: Never.self) { try sut.find(button: "Save") }
            #expect(throws: Never.self) { try sut.find(button: "Cancel") }
        }
    }

    @Test func aeroSpaceOffersUpdateUntilConfigured() throws {
        aeroSpace.refresh()
        let missing = try sidebarPane().inspect()
        #expect(throws: Never.self) { try missing.find(text: "No AeroSpace config found.") }
        #expect(throws: Never.self) { try missing.find(button: "Update Config") }
        #expect(try missing.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Not done" }).count == 1)
        #expect(throws: (any Error).self) { try missing.find(button: "Write Again") }
        try missing.find(button: "Copy Settings").tap()

        try directory.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        aeroSpace.refresh()
        let configured = try sidebarPane().inspect()
        #expect(throws: (any Error).self) { try configured.find(text: "AeroSpace configured") }
        #expect(throws: Never.self) { try configured.find(text: ".aerospace.toml reserves 300 points on the right for the sidebar.") }
        #expect(try configured.findAll(ViewType.Image.self, where: { try $0.accessibilityLabel().string() == "Done" }).count == 1)
        #expect(throws: Never.self) { try configured.find(button: "Write Again") }
    }

    /// A config that already matches can be written again, which reloads AeroSpace.
    @Test func aeroSpaceWritesConfiguredConfigAgain() async throws {
        try directory.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        aeroSpace.refresh()

        try sidebarPane().inspect().find(button: "Write Again").tap()
        for _ in 0..<100 where aeroSpace.message == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(aeroSpace.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
        #expect(try String(contentsOf: directory.url.appendingPathComponent(".aerospace.toml"), encoding: .utf8).contains(AeroSpaceConfigEditor.blockStart))
    }

    @Test func aeroSpaceShowsWarningsAndUnreadableConfig() throws {
        try directory.write("[mode.main.binding]\nalt-f = 'fullscreen --no-outer-gaps'\n", to: ".aerospace.toml")
        aeroSpace.refresh()
        let sut = try sidebarPane().inspect()

        #expect(throws: Never.self) { try sut.find(text: ".aerospace.toml reserves no sidebar strip on the right and lacks the floating rule.") }
        #expect(throws: Never.self) { try sut.find(textWhere: { text, _ in text.contains("--no-outer-gaps") }) }

        try directory.write("", to: ".config/aerospace/aerospace.toml")
        aeroSpace.refresh()
        let refreshed = try sidebarPane().inspect()
        #expect(throws: Never.self) { try refreshed.find(textWhere: { text, _ in text.hasPrefix("Cannot read the AeroSpace config") }) }
    }

    @Test(arguments: [
        (300, nil as Int?, false, "a.toml reserves 300 points on the left for the sidebar."),
        (250, nil, true, "a.toml reserves 250 points on the left, not 300 and lacks the floating rule."),
        (nil, 300, false, "a.toml reserves no sidebar strip on the left and also reserves 300 points on the right."),
    ] as [(Int?, Int?, Bool, String)])
    func describesAeroSpaceConfigAgainstSettings(reserved: Int?, opposite: Int?, missingFloatRule: Bool, hint: String) {
        let analysis = AeroSpaceConfigEditor.Analysis(
            sidebar: .init(side: .left, width: 300),
            reservedWidth: reserved,
            oppositeReservedWidth: opposite,
            missingFloatRule: missingFloatRule,
            warnings: []
        )

        #expect(AeroSpaceRows.describe(analysis, file: "a.toml") == hint)
    }

    @Test func aeroSpaceShowsItsConfigInFinder() throws {
        var revealed: [URL] = []
        #expect(throws: (any Error).self) { try sidebarPane().inspect().find(text: "AeroSpace config:") }

        try directory.write("", to: ".aerospace.toml")
        aeroSpace.refresh()
        let sut = try sidebarPane(reveal: { revealed.append($0) }).inspect()
        try sut.find(button: "Show in Finder").tap()

        #expect(revealed == [directory.url.appendingPathComponent(".aerospace.toml")])
        #expect(throws: Never.self) { try sut.find(text: directory.url.appendingPathComponent(".aerospace.toml").path) }
        // The file comes first, above the step that edits it.
        let labels = try sut.findAll(ViewType.Text.self).map { try $0.string() }
        #expect(try #require(labels.firstIndex(of: "AeroSpace config:")) < #require(labels.firstIndex(of: "AeroSpace:")))
    }

    @Test func aeroSpaceIsCheckedAgainstSavedSidebar() throws {
        try directory.write("[gaps]\nouter.right = [{ monitor.main = 305 }, 5]\n\n\(AeroSpaceConfigEditor.floatRule)\n", to: ".aerospace.toml")
        store.update { $0.sidebar.side = .left }
        aeroSpace.refresh()

        let sut = try sidebarPane().inspect()

        #expect(throws: Never.self) { try sut.find(button: "Update Config") }
        #expect(throws: Never.self) { try sut.find(text: ".aerospace.toml reserves no sidebar strip on the left and also reserves 300 points on the right.") }
    }

    @Test func updateButtonEditsAeroSpaceConfig() async throws {
        try directory.write("[gaps]\nouter.right = 5\n", to: ".config/aerospace/aerospace.toml")
        aeroSpace.refresh()

        try sidebarPane().inspect().find(button: "Update Config").tap()
        for _ in 0..<100 where aeroSpace.message == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(aeroSpace.message?.hasPrefix("Updated and reloaded AeroSpace.") == true)
    }

    @Test func generalShowsSettingsFileAndQuits() throws {
        var revealed: [URL] = []
        var quits = 0
        let sut = try general(reveal: { revealed.append($0) }, quit: { quits += 1 }).inspect()

        try sut.find(button: "Show in Finder").tap()
        try sut.find(button: "Quit Sidebar").tap()

        #expect(revealed == [store.file.url])
        #expect(quits == 1)
        #expect(throws: Never.self) { try sut.find(text: store.file.url.path) }
    }

    /// The draft panes edit one draft, so Save in any of them saves every pane's edits.
    @Test func draftPanesShareOneDraft() throws {
        var closed = 0
        var chooses = 0
        let sidebar = try sidebarPane(close: { closed += 1 }).inspect()
        let notifications = try NotificationsPane(editor: editor, close: { closed += 1 }).inspect()
        let font = try appearance(chooseFont: { chooses += 1 }, close: { closed += 1 }).inspect()

        try sidebar.find(ViewType.Picker.self).select(value: SidebarSettings.Sidebar.Side.left)
        try sidebar.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Width" }).setInput("420")
        try notifications.find(ViewType.Toggle.self).tap()
        try notifications.find(ViewType.Toggle.self, where: { try $0.labelView().text().string() == "Keep banners with buttons" }).tap()
        try notifications.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Keep banners for" }).setInput("zoom.us, Calendar")
        try font.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Font" }).setInput("Menlo")
        try font.find(ViewType.TextField.self, where: { try $0.labelView().text().string() == "Size" }).setInput("15")
        try font.find(button: "Choose…").tap()
        #expect(chooses == 1)
        #expect(store.settings == SidebarSettings())

        try history().inspect().find(button: "Save").tap()
        try sidebar.find(button: "Save").tap()

        #expect(store.settings.sidebar == .init(side: .left, width: 420))
        #expect(store.settings.notifications == .init(replaceSystem: false, actionableLeftToMacOS: false, appsLeftToMacOS: ["zoom.us", "Calendar"]))
        #expect(store.settings.font == SidebarSettings.Font(name: "Menlo", size: 15))
        #expect(closed == 1)
    }

    @Test func panesUseFontSettings() throws {
        loginItems.status = .enabled
        onboarding.refresh()
        let typography = Typography(SidebarSettings.Font(name: "Menlo", size: 18))
        let font = try appearance().environment(\.typography, typography).inspect()
        let general = try general().environment(\.typography, typography).inspect()
        let permissionsPane = try permissionsPane().environment(\.typography, typography).inspect()
        let aeroSpace = try sidebarPane().environment(\.typography, typography).inspect()

        #expect(throws: Never.self) { try font.find(text: "Font:") }
        #expect(try general.find(text: store.file.url.path).attributes().font() == typography.font(.subheadline))
        #expect(try permissionsPane.find(textWhere: { text, _ in text.hasPrefix("Required to read and hide") }).attributes().font() == typography.font(.subheadline))
        for title in ["Save", "Cancel", "Choose…"] {
            #expect(try font.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
        for title in ["Show in Finder", "Quit Sidebar"] {
            #expect(try general.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
        for title in ["Open Accessibility", "Remove"] {
            #expect(try permissionsPane.find(button: title).labelView().text().attributes().font() == typography.font(.body))
        }
        #expect(try aeroSpace.find(button: "Copy Settings").labelView().text().attributes().font() == typography.font(.body))
    }

    /// The Banners setting says what turning it off changes.
    @Test func notificationsExplainTakingOverBanners() throws {
        let sut = try NotificationsPane(editor: editor, close: {}).inspect()

        #expect(throws: Never.self) { try sut.find(text: "Banners:") }
        #expect(throws: Never.self) { try sut.find(text: "Needs Accessibility. Off, only pushed ones are listed.") }
    }

    @Test func cancelRevertsAndCloses() throws {
        var closed = 0
        editor.draft.history.maxCount = 900

        try history(close: { closed += 1 }).inspect().find(button: "Cancel").tap()

        #expect(editor.draft == store.settings)
        #expect(closed == 1)
    }

    @Test func invalidSaveStaysOpenAndShowsStatus() throws {
        var closed = 0
        editor.draft.history.retentionHours = 0
        let sut = try history(close: { closed += 1 }).inspect()

        try sut.find(button: "Save").tap()

        #expect(closed == 0)
        #expect(editor.status == "Keep for must be between 1 and 720 hours.")
    }

    @Test func settingsFileUnderHomeIsShownWithTilde() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aerospace-sidebar/config.toml")

        #expect(throws: Never.self) { try general(configURL: url).inspect().find(text: "~/.config/aerospace-sidebar/config.toml") }
    }

    @Test func everyNumberFieldHasArrows() throws {
        let panes: [any View] = [sidebarPane(), history(), appearance()]
        let steppers = try panes.map { try AnyView($0).inspect().findAll(ViewType.Stepper.self).count }

        #expect(steppers == [1, 2, 1])
    }

    @Test func numberFieldShowsUnit() throws {
        let sut = try NumberField(title: "Keep for", value: .constant(24), unit: "hours").inspect()

        #expect(throws: Never.self) { try sut.find(text: "hours") }
        #expect(throws: (any Error).self) { try sut.find(ViewType.Stepper.self) }
    }

    @Test func fontSizeArrowsStepWithinRange() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: appearance())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Size is the pane's only number field.
        let stepper = try #require(Self.subviews(of: host).compactMap { $0 as? NSStepper }.first)

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

    static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }
}

@MainActor
@Suite(.leavesDesktopAlone)
struct SettingsWindowControllerTests {
    @Test func opensOnGeneralInFrontWithoutActivatingTheApp() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url))
        controller.navigation.selection = .history
        controller.editor.draft.history.maxCount = 999

        controller.show()

        #expect(controller.window.isVisible)
        #expect(controller.navigation.selection == .general)
        #expect(controller.tabs.selectedTabViewItemIndex == 0)
        // The selected group names the pane; the title is only for VoiceOver and the window list.
        #expect(controller.window.title == "General")
        #expect(controller.window.titleVisibility == .hidden)
        #expect(controller.tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Sidebar", "Permissions", "Notifications", "History"])
        #expect(controller.window.styleMask.contains(.nonactivatingPanel))
        #expect(!controller.window.styleMask.contains(.resizable))
        #expect(!controller.window.hidesOnDeactivate)
        // Above the sidebar, which would otherwise cover the part over its strip.
        #expect(controller.window.level > SidebarPanelController.level)
        #expect(controller.tabs.view.frame.width == SettingsMetrics.paneWidth)
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
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url), terminate: { _ in terminateCalls += 1 })
        let general = try #require(
            controller.tabs.tabViewItems[SettingsGroup.general.rawValue].viewController as? NSHostingController<SettingsPaneHost<GeneralPane>>
        )

        try general.rootView.pane.inspect().find(button: "Quit Sidebar").tap()

        #expect(terminateCalls == 1)
    }

    /// Settings opens centered on the sidebar's screen, wherever it was left; while it is open, opening it
    /// again leaves it where it is.
    @Test func opensCenteredOnTheSidebarScreen() throws {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 40, width: 1600, height: 1000)
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url), sidebarScreenFrame: { screen })
        defer { controller.window.close() }

        controller.show()
        #expect(abs(controller.window.frame.midX - screen.midX) <= 1)
        #expect(abs(controller.window.frame.midY - screen.midY) <= 1)

        let moved = NSPoint(x: screen.minX + 10, y: screen.minY + 10)
        controller.window.setFrameOrigin(moved)
        controller.show()
        #expect(controller.window.frame.origin == moved)

        // Moved, the window keeps its top edge as it grows.
        let top = controller.window.frame.maxY
        store.update { $0.font.size = 20 }
        #expect(controller.window.frame.minX == moved.x)
        #expect(controller.window.frame.maxY == top)

        controller.window.close()
        controller.show()
        #expect(abs(controller.window.frame.midX - screen.midX) <= 1)
        #expect(abs(controller.window.frame.midY - screen.midY) <= 1)
    }

    /// Settings floats above other apps and the sidebar, but steps behind System Settings so the permission
    /// lists and their switches stay visible.
    @Test func stepsBehindSystemSettings() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let workspaceCenter = NotificationCenter()
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url), workspaceCenter: workspaceCenter)
        controller.follow(frontmostApp: SettingsWindowController.systemSettingsBundleID)
        #expect(controller.window.level == .normal)
        controller.show()
        defer { controller.window.orderOut(nil) }

        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(controller.window.level == SettingsWindowController.level)
        #expect(controller.window.isVisible)

        controller.follow(frontmostApp: SettingsWindowController.systemSettingsBundleID)
        #expect(controller.window.level == .normal)
        #expect(controller.window.isVisible)
    }

    @Test func fontPanelPicksGoIntoTheDraftUntilTheWindowCloses() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let panel = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let picked = try #require(NSFont(name: "Menlo-Regular", size: 16))
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url), fontChooser: FontChooser(panel: { panel }, convert: { _ in picked }))
        controller.show()

        controller.chooseFont()
        try #require(NSFontManager.shared.target as? FontChooser).changeFont(NSFontManager.shared)

        #expect(controller.editor.draft.font == SidebarSettings.Font(name: "Menlo", size: 16))
        #expect(store.settings.font == SidebarSettings.Font())
        controller.window.close()
        #expect(!panel.isVisible)
        #expect(NSFontManager.shared.target == nil)
    }

    /// The window fits the largest pane, so picking another group in the sidebar keeps its size.
    @Test func everyGroupShowsInOneWindowSize() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url))
        controller.show()
        defer { controller.window.close() }
        let frame = controller.window.frame

        for group in SettingsGroup.allCases {
            controller.navigation.selection = group
            let pane = try #require(controller.tabs.tabViewItems[group.rawValue].viewController)

            #expect(controller.tabs.selectedTabViewItemIndex == group.rawValue)
            #expect(controller.window.title == group.title)
            #expect(controller.window.frame == frame)
            #expect(pane.view.frame.height >= pane.view.fittingSize.height.rounded(.down))
            // Panes sit below the toolbar, so the toolbar is not counted in their size.
            #expect(pane.view.convert(pane.view.bounds, to: nil).maxY <= controller.window.contentLayoutRect.maxY)
        }
    }

    /// The group list is a sidebar `List`: selecting a row shows its group, and an empty selection, as
    /// after a click below the rows, keeps the shown group.
    @Test func sidebarSelectsGroups() throws {
        _ = NSApplication.shared
        let navigation = SettingsNavigation()
        var shown: [SettingsGroup] = []
        navigation.onSelect = { shown.append($0) }
        let host = NSHostingView(rootView: SettingsSidebar(navigation: navigation, onHeightChange: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let table = try #require(SettingsPaneTests.subviews(of: host).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows == SettingsGroup.allCases.count)

        table.selectRowIndexes([SettingsGroup.history.rawValue], byExtendingSelection: false)
        table.deselectAll(nil)
        host.layoutSubtreeIfNeeded()

        #expect(navigation.selection == .history)
        #expect(shown == [.history])
    }

    /// Group rows use the configured font, with an icon column sized from it.
    @Test func sidebarRowsUseFontSettings() throws {
        let typography = Typography(SidebarSettings.Font())
        let row = try SettingsSidebarLabelStyle().inspect().view(SettingsSidebarRow.self).hStack()

        #expect(try row.font() == typography.font(.body))
        #expect(try row.styleConfigurationIcon(0).fixedWidth() == typography.size * SettingsMetrics.sidebarIconWidth)
    }

    /// A pane whose content grows past the largest pane grows the window, which stays centered beside the
    /// sidebar until it is moved.
    @Test func windowFollowsPaneContentThatChangesWhileOpen() async throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let loginItems = FakeLoginItems()
        let onboarding = OnboardingModel(permissions: FakePermissions(), loginItems: loginItems)
        let controller = SettingsWindowController.forTesting(store: store, onboarding: onboarding, aeroSpace: .fake(store: store, home: directory.url))
        controller.show()
        defer { controller.window.close() }
        let before = controller.window.frame

        // A long error under the login item makes Permissions the largest pane.
        let reason = Array(repeating: "The login item service refused the request.", count: 20).joined(separator: " ")
        loginItems.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        onboarding.addLoginItem()
        for _ in 0..<100 where controller.window.frame.height == before.height {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(controller.window.frame.height > before.height)
        #expect(abs(controller.window.frame.midY - before.midY) <= 1)
        #expect(controller.window.frame.width == before.width)
    }

    @Test func previewResizesWindowAndCancelRestoresIt() throws {
        _ = NSApplication.shared
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url))
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
        let controller = SettingsWindowController.forTesting(store: store, aeroSpace: .fake(store: store, home: directory.url))
        let before = controller.window.frame

        store.update { $0.font.size = 26 }

        #expect(controller.window.frame.height > before.height)
        let width = SettingsMetrics.paneWidth * Typography(SidebarSettings.Font(size: 26)).scale
        #expect(abs(controller.tabs.view.frame.width - width) <= 1)
        #expect(controller.window.frame.maxY == before.maxY)
        #expect(controller.window.frame.minX == before.minX)
    }
}
