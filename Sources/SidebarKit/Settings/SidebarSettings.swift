import Foundation

/// User settings stored in `config.toml`.
///
/// ```toml
/// [sidebar]
/// side = "right"
/// width = 300
///
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
///
/// [background]
/// color = "#1E1E1E"
/// opacity = 0.6
///
/// [[rules]]
/// source = "^Slack$"
/// action = "high"
/// ```
///
/// Missing keys take their defaults; a key or table outside this schema makes the file invalid
/// (`Decoder.strictContainer(keyedBy:)`).
public struct SidebarSettings: Codable, Equatable, Sendable {
    /// The strip the sidebar occupies on the main display. AeroSpace must reserve the same strip with a
    /// `monitor.main` outer gap on `side`; Settings › AeroSpace writes it.
    public struct Sidebar: Codable, Equatable, Sendable {
        public enum Side: String, Codable, CaseIterable, Sendable {
            case left, right

            public var opposite: Side { self == .left ? .right : .left }
        }

        public static let widthRange = 150...1000
        public static let defaultWidth = 300

        public var side = Side.right
        /// Width in points, excluding AeroSpace's regular outer gap between the sidebar and tiled windows.
        public var width = defaultWidth

        enum CodingKeys: String, CodingKey, CaseIterable {
            case side, width
        }

        public init(side: Side = .right, width: Int = defaultWidth) {
            self.side = side
            self.width = width
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
            side = try container.decodeIfPresent(Side.self, forKey: .side) ?? .right
            width = try container.decodeIfPresent(Int.self, forKey: .width) ?? Self.defaultWidth
            guard Self.widthRange.contains(width) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .width, in: container,
                    debugDescription: "width must be between \(Self.widthRange.lowerBound) and \(Self.widthRange.upperBound)"
                )
            }
        }
    }

    public struct Notifications: Codable, Equatable, Sendable {
        /// Hide native banners and list them in the sidebar.
        public var replaceSystem = true
        /// Leave notifications with buttons, a reply field or other actions that their cards cannot offer to
        /// macOS. Otherwise they are listed like the others, without those actions.
        public var actionableLeftToMacOS = true
        /// Apps whose notifications macOS keeps presenting; matched case-insensitively by app name.
        public var appsLeftToMacOS: [String] = []

        enum CodingKeys: String, CodingKey, CaseIterable {
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
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
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

        enum CodingKeys: String, CodingKey, CaseIterable {
            case retentionHours = "retention_hours"
            case maxCount = "max_count"
        }

        public init(retentionHours: Int = 24, maxCount: Int = 200) {
            self.retentionHours = retentionHours
            self.maxCount = maxCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
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

        enum CodingKeys: String, CodingKey, CaseIterable {
            case name, size
        }

        public init(name: String = "", size: Double = defaultSize) {
            self.name = name
            self.size = size
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
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

    /// A color filling the sidebar's strip from the top of the screen to the bottom, behind the cards
    /// (`SidebarBackground`).
    public struct Background: Codable, Equatable, Sendable {
        public static let opacityRange: ClosedRange<Double> = 0...1

        public var color = RGBColor.black
        /// From 0, which shows no background, to 1, which hides the desktop under the strip.
        public var opacity = 0.0

        enum CodingKeys: String, CodingKey, CaseIterable {
            case color, opacity
        }

        public init(color: RGBColor = .black, opacity: Double = 0) {
            self.color = color
            self.opacity = opacity
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
            color = try container.decodeIfPresent(RGBColor.self, forKey: .color) ?? .black
            opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0
            guard Self.opacityRange.contains(opacity) else {
                throw DecodingError.dataCorruptedError(forKey: .opacity, in: container, debugDescription: "opacity must be between 0 and 1")
            }
        }

        /// Whether there is anything to show.
        public var isVisible: Bool { opacity > 0 }
    }

    /// An opaque sRGB color, written `#RRGGBB` in `config.toml`.
    public struct RGBColor: Codable, Equatable, Sendable, CustomStringConvertible {
        public static let black = RGBColor(red: 0, green: 0, blue: 0)

        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// The color `#RRGGBB` names, in either case; nil for any other text.
        public init?(hex: String) {
            guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16),
                  hex.dropFirst().allSatisfy(\.isHexDigit)
            else { return nil }
            self.init(red: UInt8(value >> 16), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
        }

        public var description: String {
            String(format: "#%02X%02X%02X", red, green, blue)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let color = RGBColor(hex: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "color must be written #RRGGBB, not \(text)")
            }
            self = color
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(description)
        }
    }

    public var sidebar = Sidebar()
    public var notifications = Notifications()
    public var history = History()
    public var font = Font()
    public var background = Background()
    /// Applied in order to every notification as it arrives; see `Rule`.
    public var rules: [Rule] = []

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sidebar, notifications, history, font, background, rules
    }

    public init(
        sidebar: Sidebar = Sidebar(),
        notifications: Notifications = Notifications(),
        history: History = History(),
        font: Font = Font(),
        background: Background = Background(),
        rules: [Rule] = []
    ) {
        self.sidebar = sidebar
        self.notifications = notifications
        self.history = history
        self.font = font
        self.background = background
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.strictContainer(keyedBy: CodingKeys.self)
        sidebar = try container.decodeIfPresent(Sidebar.self, forKey: .sidebar) ?? Sidebar()
        notifications = try container.decodeIfPresent(Notifications.self, forKey: .notifications) ?? Notifications()
        history = try container.decodeIfPresent(History.self, forKey: .history) ?? History()
        font = try container.decodeIfPresent(Font.self, forKey: .font) ?? Font()
        background = try container.decodeIfPresent(Background.self, forKey: .background) ?? Background()
        rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    /// Leaves out `rules` while there are none, which would otherwise read `rules = []` above every table.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sidebar, forKey: .sidebar)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(history, forKey: .history)
        try container.encode(font, forKey: .font)
        try container.encode(background, forKey: .background)
        if !rules.isEmpty {
            try container.encode(rules, forKey: .rules)
        }
    }
}

extension Decoder {
    /// A keyed container for a settings table that holds only keys of `Key`. Decoding reads only the keys it
    /// asks for, so a misspelled key would otherwise be ignored: `replace_sytem = false` would leave banners
    /// replaced, and a rule with `titel = "deploy"` would match every notification from its source.
    /// - Throws: `DecodingError.dataCorrupted` at the table's coding path, naming the unknown keys and the
    ///   expected ones.
    func strictContainer<Key: CodingKey & CaseIterable>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let unknown = try container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue).filter { Key(stringValue: $0) == nil }
        guard unknown.isEmpty else {
            let expected = Key.allCases.map(\.stringValue).formatted(.list(type: .or))
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "unknown \(unknown.count == 1 ? "key" : "keys") \(unknown.sorted().formatted(.list(type: .and))); expected \(expected)"
            ))
        }
        return try container(keyedBy: type)
    }
}

/// A key of any name. A container's `allKeys` lists only the keys its key type can be made from, so listing
/// every key a table holds takes a type that accepts every name.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    /// Tables have only string keys.
    init?(intValue: Int) {
        nil
    }
}
