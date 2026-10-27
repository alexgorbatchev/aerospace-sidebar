import Foundation

/// The words NotificationCenter uses on its notifications, in the language it runs in.
///
/// Action names such as Close are localized, so matching them in English misjudges every notification on
/// another system language. NotificationCenter's own string table holds every translation (AnyDoor,
/// MeetingMute, NotificationNanny read it the same way); its "%@, %@, stacked" entry also gives the
/// separator between the parts of a notification's description, which is "、" in Japanese, for example.
public struct NotificationCenterLabels: Equatable, Sendable {
    public static let tableURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/NotificationCenter.app/Contents/Resources/Localizable.loctable"
    )
    public static let english = NotificationCenterLabels(
        close: "Close", show: "Show", showDetails: "Show Details", separator: ", ", stackedSuffix: ", stacked"
    )

    public var close: String
    public var show: String
    public var showDetails: String
    /// Joins the parts of a notification's description, such as ", ".
    public var separator: String
    /// Ends the description of a collapsed stack, such as ", stacked".
    public var stackedSuffix: String

    /// Labels for `language`, NotificationCenter's `AXPreferredLanguage`, read from its string table. Missing
    /// entries, an unknown language and an unreadable table fall back to English.
    public static func load(language: String?, table url: URL = tableURL) -> NotificationCenterLabels {
        guard let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return english }
        let localizations = table.keys.filter { $0 != "LocProvenance" }
        // With no localization in the preferred language, Foundation still returns one, possibly in another
        // language, so the match has to share the language code.
        guard let language,
              let match = Bundle.preferredLocalizations(from: localizations, forPreferences: [language]).first,
              Locale(identifier: match).language.languageCode == Locale(identifier: language).language.languageCode,
              // Plural entries are dictionaries, so the values are not all strings.
              let strings = table[match] as? [String: Any]
        else { return english }
        var labels = english
        labels.close = strings["Close"] as? String ?? labels.close
        labels.show = strings["Show"] as? String ?? labels.show
        labels.showDetails = strings["Show Details"] as? String ?? labels.showDetails
        // "%@, %@, stacked" splits into "", ", " and ", stacked".
        let stacked = (strings["%@, %@, stacked"] as? String)?.components(separatedBy: "%@") ?? []
        if stacked.count == 3, !stacked[1].isEmpty, !stacked[2].isEmpty {
            labels.separator = stacked[1]
            labels.stackedSuffix = stacked[2]
        }
        return labels
    }
}
