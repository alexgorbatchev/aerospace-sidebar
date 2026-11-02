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
            "Close": "Schließen", "Show": "Anzeigen", "Show Details": "Details einblenden", "Hide Details": "Details ausblenden",
            "%@, %@, stacked": "%@, %@, gestapelt",
            "Stacked summary: %@": "Gestapelte Zusammenfassung: %@",
            "Stacked summary: %@, from iPhone": "Gestapelte Zusammenfassung: %@, vom iPhone",
            "%u more notifications": ["NSStringLocalizedFormatKey": "%#@notifications@"],
        ],
        "ja": ["Close": "閉じる", "%@, %@, stacked": "%@、%@、スタック"],
        "pt_BR": ["Close": "Fechar", "%@, %@, stacked": "broken"],
    ]

    @Test func readsTheLanguageNotificationCenterRunsIn() throws {
        let (directory, url) = try Self.writeTable(Self.table)
        defer { _ = directory }
        let noPermissions = directory.url.appendingPathComponent("missing")

        #expect(NotificationCenterLabels.load(language: "de", table: url, permissionTable: noPermissions) == NotificationCenterLabels(
            close: "Schließen", show: "Anzeigen", showDetails: "Details einblenden", hideDetails: "Details ausblenden",
            separator: ", ", stackedSuffix: ", gestapelt",
            stackedSummaries: ["Gestapelte Zusammenfassung: %@, vom iPhone", "Gestapelte Zusammenfassung: %@"]
        ))
        let japanese = NotificationCenterLabels.load(language: "ja", table: url, permissionTable: noPermissions)
        #expect(japanese.close == "閉じる")
        #expect(japanese.show == "Show")
        #expect(japanese.separator == "、")
        #expect(japanese.stackedSuffix == "、スタック")
        let portuguese = NotificationCenterLabels.load(language: "pt-BR", table: url, permissionTable: noPermissions)
        #expect(portuguese.close == "Fechar")
        #expect(portuguese.separator == ", ")
    }

    @Test func fallsBackToEnglish() throws {
        let (directory, url) = try Self.writeTable(Self.table)
        defer { _ = directory }

        let missing = directory.url.appendingPathComponent("missing")
        #expect(NotificationCenterLabels.load(language: "fi", table: url, permissionTable: url) == .english)
        #expect(NotificationCenterLabels.load(language: nil, table: url, permissionTable: url) == .english)
        #expect(NotificationCenterLabels.load(language: "de", table: missing, permissionTable: missing) == .english)
        let (emptyDirectory, empty) = try Self.writeTable(["ko": [:]])
        defer { _ = emptyDirectory }
        #expect(NotificationCenterLabels.load(language: "ko", table: empty, permissionTable: empty) == .english)
    }

    /// The permission request's words come from its own table, in the same language; entries it lacks stay English.
    @Test func readsThePermissionRequestInTheSameLanguage() throws {
        let (directory, url) = try Self.writeTable(Self.table)
        let (permissionDirectory, permissionURL) = try Self.writeTable([
            "en": ["ALLOW_TITLE": "“%@” Notifications"],
            "ja": ["ALLOW_TITLE": "“%@”の通知", "ALLOW_BODY": "テキスト、サウンド、アイコンバッジにより通知されます。"],
        ])
        defer { _ = (directory, permissionDirectory) }

        let japanese = NotificationCenterLabels.load(language: "ja", table: url, permissionTable: permissionURL)

        #expect(japanese.close == "閉じる")
        #expect(japanese.permissionTitles == ["“%@”の通知", NotificationCenterLabels.english.permissionTitles[1]])
        #expect(japanese.permissionBodies == ["テキスト、サウンド、アイコンバッジにより通知されます。", NotificationCenterLabels.english.permissionBodies[1]])
        #expect(NotificationCenterLabels.load(language: "de", table: url, permissionTable: permissionURL).permissionBodies
            == NotificationCenterLabels.english.permissionBodies)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NotificationCenterLabels.tableURL.path)))
    func readsNotificationCentersOwnTable() {
        #expect(NotificationCenterLabels.load(language: "en") == .english)
        #expect(NotificationCenterLabels.load(language: "de").close == "Schließen")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: NotificationCenterLabels.permissionTableURL.path)))
    func readsThePermissionRequestsOwnTable() {
        #expect(NotificationCenterLabels.load(language: "en").permissionBodies == NotificationCenterLabels.english.permissionBodies)
        #expect(NotificationCenterLabels.load(language: "ja").permissionTitles.first == "“%@”の通知")
    }
}
