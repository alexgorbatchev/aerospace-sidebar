import Foundation
import Observation

/// The Settings window's working copy. Edits stay in `draft` until `save()` writes `config.toml`;
/// `revert()` discards them. While nothing is edited, external changes to the file replace the draft.
@MainActor
@Observable
public final class SettingsEditor {
    public var draft: SidebarSettings
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
        let history = draft.history
        if !SidebarSettings.History.retentionRange.contains(history.retentionHours) {
            status = "Keep for must be between \(SidebarSettings.History.retentionRange.lowerBound) and \(SidebarSettings.History.retentionRange.upperBound) hours."
            return false
        }
        if !SidebarSettings.History.maxCountRange.contains(history.maxCount) {
            status = "Keep at most must be between \(SidebarSettings.History.maxCountRange.lowerBound) and \(SidebarSettings.History.maxCountRange.upperBound) notifications."
            return false
        }
        let draft = draft
        store.update { $0 = draft }
        if let error = store.saveError {
            status = "Couldn't save settings: \(error)"
            return false
        }
        status = nil
        return true
    }

    private static func loadStatus(_ store: SettingsStore) -> String? {
        store.loadError.map { "config.toml is invalid, so the previous settings stay in effect: \($0)" }
    }
}
