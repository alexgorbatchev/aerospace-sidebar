import Foundation
import Observation

/// The Settings window's working copy. Edits stay in `draft` until `save()` writes `config.toml`;
/// `revert()` discards them. While nothing is edited, external changes to the file replace the draft.
/// The draft font is previewed right away, so font edits show before they are saved.
@MainActor
@Observable
public final class SettingsEditor {
    public var draft: SidebarSettings {
        didSet { store.preview(font: draft.font == store.settings.font ? nil : draft.font) }
    }
    /// Problems to show in the window's status line: invalid values, save or load failures.
    public private(set) var status: String?

    @ObservationIgnored private let store: SettingsStore
    /// The settings `draft` started from; the store has already changed when it notifies observers.
    @ObservationIgnored private var baseline: SidebarSettings

    public init(store: SettingsStore) {
        self.store = store
        draft = store.settings
        baseline = store.settings
        status = Self.loadStatus(store)
        store.observe { [weak self] settings in
            guard let self else { return }
            if !self.isDirty {
                self.draft = settings
            }
            self.baseline = settings
        }
    }

    public var isDirty: Bool { draft != baseline }

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
        baseline = store.settings
        draft = store.settings
        status = Self.loadStatus(store)
    }

    /// Validates and writes the draft. Returns false and sets `status` when it cannot.
    @discardableResult
    public func save() -> Bool {
        if !SidebarSettings.Sidebar.widthRange.contains(draft.sidebar.width) {
            status = "Width must be between \(SidebarSettings.Sidebar.widthRange.lowerBound) and \(SidebarSettings.Sidebar.widthRange.upperBound) points."
            return false
        }
        let history = draft.history
        if !SidebarSettings.History.retentionRange.contains(history.retentionHours) {
            status = "Keep for must be between \(SidebarSettings.History.retentionRange.lowerBound) and \(SidebarSettings.History.retentionRange.upperBound) hours."
            return false
        }
        if !SidebarSettings.History.maxCountRange.contains(history.maxCount) {
            status = "Keep at most must be between \(SidebarSettings.History.maxCountRange.lowerBound) and \(SidebarSettings.History.maxCountRange.upperBound) notifications."
            return false
        }
        let font = draft.font
        if !SidebarSettings.Font.sizeRange.contains(font.size) {
            status = "Size must be between \(SidebarSettings.Font.sizeRange.lowerBound.formatted()) and \(SidebarSettings.Font.sizeRange.upperBound.formatted()) points."
            return false
        }
        if let (index, problem) = draft.rules.enumerated().lazy.compactMap({ index, rule in rule.problem.map { (index, $0) } }).first {
            status = "Rule \(index + 1) \(problem)."
            return false
        }
        let fontName = font.name.trimmingCharacters(in: .whitespaces)
        if !fontName.isEmpty {
            guard let family = Typography.installedFamily(named: fontName) else {
                status = "No installed font family is named “\(fontName)”."
                return false
            }
            draft.font.name = family
        } else {
            draft.font.name = ""
        }
        let draft = draft
        store.update { $0 = draft }
        if let error = store.saveError {
            status = "Couldn't save settings: \(error)"
            return false
        }
        store.preview(font: nil)
        status = nil
        return true
    }

    private static func loadStatus(_ store: SettingsStore) -> String? {
        let fontName = store.settings.font.name
        let problems = [
            store.loadError.map { "config.toml is invalid, so the previous settings stay in effect: \($0)" },
            !fontName.isEmpty && Typography.installedFamily(named: fontName) == nil
                ? "Font “\(fontName)” is not installed, so the system font is used." : nil,
        ].compactMap { $0 }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }
}
