import Foundation
import Observation

/// The Settings window's working copy. Edits stay in `draft` until `save()` writes `config.toml`;
/// `revert()` discards them. Changes to the file, made by hand or by another tool, replace the groups of
/// the draft that hold no edits; Save warns before replacing a group that changed in both places, or a file
/// that does not load. The draft font and background are previewed right away, so their edits show before they
/// are saved.
@MainActor
@Observable
public final class SettingsEditor {
    public var draft: SidebarSettings {
        didSet {
            store.preview(font: draft.font == store.settings.font ? nil : draft.font)
            store.preview(background: draft.background == store.settings.background ? nil : draft.background)
        }
    }

    /// Problems to show in the window's status line: why the last Save did not save, else load failures,
    /// which show as soon as the file changes.
    public var status: String? {
        if let problem {
            return problem
        }
        if let loadError = store.loadError, loadError == replacedLoadError {
            return "config.toml is invalid (\(loadError)). Save again to replace it with these settings, or Cancel to fix it by hand."
        }
        return Self.loadStatus(store)
    }

    /// Why the last Save did not save, until a save succeeds or the draft is reverted.
    private var problem: String?
    /// The load error of an invalid `config.toml` that Save warned about, so that saving again replaces the
    /// file. Once the file loads again, the warning is gone.
    private var replacedLoadError: String?
    @ObservationIgnored private let store: SettingsStore
    /// The settings `draft` started from: a group that differs from it holds edits, and the others follow the
    /// store.
    @ObservationIgnored private var start: SidebarSettings

    public init(store: SettingsStore) {
        self.store = store
        draft = store.settings
        start = store.settings
        store.observe { [weak self] settings in self?.follow(settings) }
    }

    /// Whether the draft holds edits that are not saved.
    public var isDirty: Bool { draft != start }

    /// `appsLeftToMacOS` as comma-separated text.
    public var appsLeftToMacOSText: String {
        get { draft.notifications.appsLeftToMacOS.joined(separator: ", ") }
        set {
            draft.notifications.appsLeftToMacOS = newValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    public func revert() {
        start = store.settings
        draft = store.settings
        problem = nil
        replacedLoadError = nil
    }

    /// Validates the draft and writes its edits over the current settings. Returns false and sets `status`
    /// when it cannot, or when a Save again is needed to replace changes to the file.
    @discardableResult
    public func save() -> Bool {
        if let invalid = invalidValue() {
            problem = invalid
            return false
        }
        let fontName = draft.font.name.trimmingCharacters(in: .whitespaces)
        if !fontName.isEmpty {
            guard let family = Typography.installedFamily(named: fontName) else {
                problem = "No installed font family is named “\(fontName)”."
                return false
            }
            draft.font.name = family
        } else {
            draft.font.name = ""
        }
        var updated = store.settings
        var changedInFile: [SettingsGroup] = []
        for group in Self.groups where !group.isEqual(draft, start) {
            if !group.isEqual(updated, start), !group.isEqual(updated, draft) {
                // Appearance holds two tables: the font and the background.
                if !changedInFile.contains(group.settingsGroup) {
                    changedInFile.append(group.settingsGroup)
                }
                // The warning names the file's version; saving again replaces it.
                group.copy(updated, &start)
            }
            group.copy(draft, &updated)
        }
        if !changedInFile.isEmpty {
            problem = "\(changedInFile.map(\.title).formatted(.list(type: .and))) settings changed in config.toml while you edited them. Save again to replace those changes, or Cancel to keep them."
            return false
        }
        if let loadError = store.loadError, loadError != replacedLoadError {
            replacedLoadError = loadError
            problem = nil
            return false
        }
        store.update { $0 = updated }
        if let error = store.saveError {
            problem = "Couldn't save settings: \(error)"
            return false
        }
        store.preview(font: nil)
        store.preview(background: nil)
        start = store.settings
        problem = nil
        replacedLoadError = nil
        return true
    }

    /// Why a value in the draft cannot be saved; nil when every value can.
    private func invalidValue() -> String? {
        if !SidebarSettings.Sidebar.widthRange.contains(draft.sidebar.width) {
            return "Width must be between \(SidebarSettings.Sidebar.widthRange.lowerBound) and \(SidebarSettings.Sidebar.widthRange.upperBound) points."
        }
        let history = draft.history
        if !SidebarSettings.History.retentionRange.contains(history.retentionHours) {
            return "Keep for must be between \(SidebarSettings.History.retentionRange.lowerBound) and \(SidebarSettings.History.retentionRange.upperBound) hours."
        }
        if !SidebarSettings.History.maxCountRange.contains(history.maxCount) {
            return "Keep at most must be between \(SidebarSettings.History.maxCountRange.lowerBound) and \(SidebarSettings.History.maxCountRange.upperBound) notifications."
        }
        if !SidebarSettings.Font.sizeRange.contains(draft.font.size) {
            return "Size must be between \(SidebarSettings.Font.sizeRange.lowerBound.formatted()) and \(SidebarSettings.Font.sizeRange.upperBound.formatted()) points."
        }
        if let (index, problem) = draft.rules.enumerated().lazy.compactMap({ index, rule in rule.problem.map { (index, $0) } }).first {
            return "Rule \(index + 1) \(problem)."
        }
        return nil
    }

    /// Takes `settings`, as the file changed, into every group of the draft that holds no edits.
    private func follow(_ settings: SidebarSettings) {
        var followed = draft
        for group in Self.groups where group.isEqual(followed, start) {
            group.copy(settings, &followed)
            group.copy(settings, &start)
        }
        if followed != draft {
            draft = followed
        }
    }

    /// A part of the settings that one Settings group edits. Edits and changes to the file are told apart
    /// group by group.
    private struct Group {
        let settingsGroup: SettingsGroup
        let isEqual: (SidebarSettings, SidebarSettings) -> Bool
        /// Copies the group from the first settings into the second.
        let copy: (SidebarSettings, inout SidebarSettings) -> Void

        init<Value: Equatable>(_ keyPath: WritableKeyPath<SidebarSettings, Value>, _ settingsGroup: SettingsGroup) {
            self.settingsGroup = settingsGroup
            isEqual = { $0[keyPath: keyPath] == $1[keyPath: keyPath] }
            copy = { $1[keyPath: keyPath] = $0[keyPath: keyPath] }
        }
    }

    private static let groups = [
        Group(\.font, .appearance),
        Group(\.background, .appearance),
        Group(\.sidebar, .sidebar),
        Group(\.notifications, .notifications),
        Group(\.rules, .rules),
        Group(\.history, .history),
    ]

    private static func loadStatus(_ store: SettingsStore) -> String? {
        let fontName = store.settings.font.name
        let problems = [
            store.loadProblem,
            !fontName.isEmpty && Typography.installedFamily(named: fontName) == nil
                ? "Font “\(fontName)” is not installed, so the system font is used." : nil,
        ].compactMap { $0 }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }
}
