import Foundation

/// User settings stored in `config.toml`.
///
/// ```toml
/// [notifications]
/// replace_system = true
/// apps_left_to_macos = ["Zoom"]
///
/// [history]
/// retention_hours = 24
/// max_count = 200
/// ```
public struct SidebarSettings: Codable, Equatable, Sendable {
    public struct Notifications: Codable, Equatable, Sendable {
        /// Hide native banners and list them in the sidebar.
        public var replaceSystem = true
        /// Apps whose notifications macOS keeps presenting; matched case-insensitively by app name.
        public var appsLeftToMacOS: [String] = []

        enum CodingKeys: String, CodingKey {
            case replaceSystem = "replace_system"
            case appsLeftToMacOS = "apps_left_to_macos"
        }

        public init(replaceSystem: Bool = true, appsLeftToMacOS: [String] = []) {
            self.replaceSystem = replaceSystem
            self.appsLeftToMacOS = appsLeftToMacOS
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            replaceSystem = try container.decodeIfPresent(Bool.self, forKey: .replaceSystem) ?? true
            appsLeftToMacOS = try container.decodeIfPresent([String].self, forKey: .appsLeftToMacOS) ?? []
        }

        /// Whether notifications from `appName` stay native.
        public func leavesToMacOS(_ appName: String) -> Bool {
            appsLeftToMacOS.contains { $0.caseInsensitiveCompare(appName) == .orderedSame }
        }
    }

    public struct History: Codable, Equatable, Sendable {
        public static let retentionRange = 1...720
        public static let maxCountRange = 10...2000

        public var retentionHours = 24
        public var maxCount = 200

        enum CodingKeys: String, CodingKey {
            case retentionHours = "retention_hours"
            case maxCount = "max_count"
        }

        public init(retentionHours: Int = 24, maxCount: Int = 200) {
            self.retentionHours = retentionHours
            self.maxCount = maxCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            retentionHours = try container.decodeIfPresent(Int.self, forKey: .retentionHours) ?? 24
            maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount) ?? 200
            guard Self.retentionRange.contains(retentionHours) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .retentionHours, in: container,
                    debugDescription: "retention_hours must be between \(Self.retentionRange.lowerBound) and \(Self.retentionRange.upperBound)"
                )
            }
            guard Self.maxCountRange.contains(maxCount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .maxCount, in: container,
                    debugDescription: "max_count must be between \(Self.maxCountRange.lowerBound) and \(Self.maxCountRange.upperBound)"
                )
            }
        }

        public var retention: TimeInterval { TimeInterval(retentionHours) * 3600 }
    }

    public var notifications = Notifications()
    public var history = History()

    public init(notifications: Notifications = Notifications(), history: History = History()) {
        self.notifications = notifications
        self.history = history
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try container.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        history = try container.decodeIfPresent(History.self, forKey: .history) ?? History()
    }
}
