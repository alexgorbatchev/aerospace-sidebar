import Foundation

/// User settings stored in `config.toml`.
///
/// ```toml
/// [notifications]
/// replace_system = true
/// actionable_left_to_macos = true
/// apps_left_to_macos = ["Zoom"]
///
/// [history]
/// retention_hours = 24
/// max_count = 200
///
/// [font]
/// name = "Menlo"
/// size = 13
/// ```
public struct SidebarSettings: Codable, Equatable, Sendable {
    public struct Notifications: Codable, Equatable, Sendable {
        /// Hide native banners and list them in the sidebar.
        public var replaceSystem = true
        /// Leave notifications with buttons, a reply field or other actions to macOS. Otherwise they are
        /// listed like the others, without those actions.
        public var actionableLeftToMacOS = true
        /// Apps whose notifications macOS keeps presenting; matched case-insensitively by app name.
        public var appsLeftToMacOS: [String] = []

        enum CodingKeys: String, CodingKey {
            case replaceSystem = "replace_system"
            case actionableLeftToMacOS = "actionable_left_to_macos"
            case appsLeftToMacOS = "apps_left_to_macos"
        }

        public init(replaceSystem: Bool = true, actionableLeftToMacOS: Bool = true, appsLeftToMacOS: [String] = []) {
            self.replaceSystem = replaceSystem
            self.actionableLeftToMacOS = actionableLeftToMacOS
            self.appsLeftToMacOS = appsLeftToMacOS
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            replaceSystem = try container.decodeIfPresent(Bool.self, forKey: .replaceSystem) ?? true
            actionableLeftToMacOS = try container.decodeIfPresent(Bool.self, forKey: .actionableLeftToMacOS) ?? true
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

    /// The font of every text in the sidebar and Settings.
    public struct Font: Codable, Equatable, Sendable {
        public static let sizeRange: ClosedRange<Double> = 8...32
        /// macOS's body text size.
        public static let defaultSize: Double = 13

        /// Font family as Font Book lists it; empty means the system font.
        public var name = ""
        /// Body text size in points; every other text size scales with it.
        public var size = defaultSize

        public init(name: String = "", size: Double = defaultSize) {
            self.name = name
            self.size = size
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            size = try container.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaultSize
            guard Self.sizeRange.contains(size) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .size, in: container,
                    debugDescription: "size must be between \(Self.sizeRange.lowerBound.formatted()) and \(Self.sizeRange.upperBound.formatted())"
                )
            }
        }
    }

    public var notifications = Notifications()
    public var history = History()
    public var font = Font()

    public init(notifications: Notifications = Notifications(), history: History = History(), font: Font = Font()) {
        self.notifications = notifications
        self.history = history
        self.font = font
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try container.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        history = try container.decodeIfPresent(History.self, forKey: .history) ?? History()
        font = try container.decodeIfPresent(Font.self, forKey: .font) ?? Font()
    }
}
