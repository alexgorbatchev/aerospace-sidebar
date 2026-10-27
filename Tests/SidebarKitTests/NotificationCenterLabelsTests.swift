import Foundation
@testable import SidebarKit
import Testing

struct NotificationCenterLabelsTests {
    /// A string table shaped like NotificationCenter's `Localizable.loctable`.
    static func writeTable(_ table: [String: [String: any Sendable]]) throws -> (TemporaryDirectory, URL) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("Localizable.loctable")
        try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0).write(to: url)
        return (directory, url)
    }

    static let table: [String: [String: any Sendable]] = [
        "LocProvenance": ["de": "x"],
        "en": ["Close": "Close", "Show": "Show", "Show Details": "Show Details", "%@, %@, stacked": "%@, %@, stacked"],
        "de": [
            "Close": "Schließen", "Show": "Anzeigen", "Show Details": "Details einblenden", "%@, %@, stacked": "%@, %@, gestapelt",
            "%u more notifications": ["NSStringLocalizedFormatKey": "%#@notifications@"],
        ],
        "ja": ["Close": "閉じる", "%@, %@, stacked": "%@、%@、スタック"],
        "pt_BR": ["Close": "Fechar", "%@, %@, stacked": "broken"],
    ]

    @Test func readsTheLanguageNotificationCenterRunsIn() throws {
        let (directory, url) = try Self.writeTable(Self.table)
        defer { _ = directory }

        #expect(NotificationCenterLabels.load(language: "de", table: url) == NotificationCenterLabels(
            close: "Schließen", show: "Anzeigen", showDetails: "Details einblenden", separator: ", ", stackedSuffix: ", gestapelt"
        ))
        let japanese = NotificationCenterLabels.load(language: "ja", table: url)
        #expect(japanese.close == "閉じる")
        #expect(japanese.show == "Show")
        #expect(japanese.separator == "、")
        #expect(japanese.stackedSuffix == "、スタック")
        let portuguese = NotificationCenterLabels.load(language: "pt-BR", table: url)
        #expect(portuguese.close == "Fechar")
        #expect(portuguese.separator == ", ")
    }

    @Test func fallsBackToEnglish() throws {
        let (directory, url) = try Self.writeTable(Self.table)
        defer { _ = directory }

        #expect(NotificationCenterLabels.load(language: "fi", table: url) == .english)
        #expect(NotificationCenterLabels.load(language: nil, table: url) == .english)
        #expect(NotificationCenterLabels.load(language: "de", table: directory.url.appendingPathComponent("missing")) == .english)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NotificationCenterLabels.tableURL.path)))
    func readsNotificationCentersOwnTable() {
        #expect(NotificationCenterLabels.load(language: "en") == .english)
        #expect(NotificationCenterLabels.load(language: "de").close == "Schließen")
    }
}
