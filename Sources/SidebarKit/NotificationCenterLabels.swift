import Foundation

/// The words NotificationCenter uses on its notifications, in the language it runs in.
///
/// Action names such as Close are localized, so matching them in English misjudges every notification on
/// another system language. NotificationCenter's own string table holds every translation (AnyDoor,
/// MeetingMute, NotificationNanny read it the same way); its "%@, %@, stacked" entry also gives the
/// separator between the parts of a notification's description, which is "、" in Japanese, for example.
///
/// macOS asks whether an app may post notifications with a notification of its own, which usernoted builds
/// from the `com.apple.notificationcenter.askpermissions` bundle's string table; its title and body tell
/// such a request apart from the notifications it is about.
public struct NotificationCenterLabels: Equatable, Sendable {
    public static let tableURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/NotificationCenter.app/Contents/Resources/Localizable.loctable"
    )
    public static let permissionTableURL = URL(fileURLWithPath: """
        /System/Library/UserNotifications/Bundles/com.apple.notificationcenter.askpermissions.bundle/Contents/Resources/\
        Localizable.loctable
        """)
    public static let english = NotificationCenterLabels(
        close: "Close", show: "Show", showDetails: "Show Details", separator: ", ", stackedSuffix: ", stacked"
    )

    public var close: String
    public var show: String
    public var showDetails: String
    /// What Show Details becomes while a notification shows its details, such as an open reply field;
    /// performing it closes them again.
    public var hideDetails = "Hide Details"
    /// Joins the parts of a notification's description, such as ", ".
    public var separator: String
    /// Ends the description of a collapsed stack, such as ", stacked".
    public var stackedSuffix: String
    /// Enclose the description of a stack in the history panel, with `%@` for the rest of it: "Stacked summary: %@",
    /// and first, being more specific, the one for notifications mirrored from an iPhone (measured on macOS 26.6).
    public var stackedSummaries = ["Stacked summary: %@, from iPhone", "Stacked summary: %@"]
    /// Titles of macOS's request to let an app post notifications, with `%@` for the app's name: one for
    /// notifications and one for critical alerts.
    public var permissionTitles = ["“%@” Notifications", "“%@” Critical Alerts"]
    /// Bodies of the same requests.
    public var permissionBodies = [
        "Notifications may include alerts, sounds, and icon badges.",
        "Critical alerts always play a sound and appear on the lock screen even if your Mac is muted or Do Not Disturb is on.",
    ]

    /// Labels for `language`, NotificationCenter's `AXPreferredLanguage`, read from its string table and the
    /// permission request's. Missing entries, an unknown language and an unreadable table fall back to English.
    public static func load(
        language: String?,
        table url: URL = tableURL,
        permissionTable permissionURL: URL = permissionTableURL
    ) -> NotificationCenterLabels {
        var labels = english
        if let strings = strings(in: url, language: language) {
            labels.close = strings["Close"] as? String ?? labels.close
            labels.show = strings["Show"] as? String ?? labels.show
            labels.showDetails = strings["Show Details"] as? String ?? labels.showDetails
            labels.hideDetails = strings["Hide Details"] as? String ?? labels.hideDetails
            // "%@, %@, stacked" splits into "", ", " and ", stacked".
            let stacked = (strings["%@, %@, stacked"] as? String)?.components(separatedBy: "%@") ?? []
            if stacked.count == 3, !stacked[1].isEmpty, !stacked[2].isEmpty {
                labels.separator = stacked[1]
                labels.stackedSuffix = stacked[2]
            }
            labels.stackedSummaries = zip(["Stacked summary: %@, from iPhone", "Stacked summary: %@"], labels.stackedSummaries).map {
                strings[$0] as? String ?? $1
            }
        }
        if let strings = strings(in: permissionURL, language: language) {
            labels.permissionTitles = zip(["ALLOW_TITLE", "ALLOW_TITLE_CRITICAL"], labels.permissionTitles).map {
                strings[$0] as? String ?? $1
            }
            labels.permissionBodies = zip(["ALLOW_BODY", "ALLOW_BODY_CRITICAL"], labels.permissionBodies).map {
                strings[$0] as? String ?? $1
            }
        }
        return labels
    }

    /// The strings a `.loctable` holds for `language`; nil for an unreadable table or a language it lacks.
    private static func strings(in url: URL, language: String?) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let localizations = table.keys.filter { $0 != "LocProvenance" }
        // With no localization in the preferred language, Foundation still returns one, possibly in another
        // language, so the match has to share the language code.
        guard let language,
              let match = Bundle.preferredLocalizations(from: localizations, forPreferences: [language]).first,
              Locale(identifier: match).language.languageCode == Locale(identifier: language).language.languageCode
        else { return nil }
        // Plural entries are dictionaries, so the values are not all strings.
        return table[match] as? [String: Any]
    }
}
