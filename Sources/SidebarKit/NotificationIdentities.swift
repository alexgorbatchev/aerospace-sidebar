import Foundation

/// The UUIDs of native notifications already listed. NotificationCenter shows each notification's UUID
/// as its `AXIdentifier`, and the notification database records the same UUID (OmniWM), so both sources
/// share this record and neither lists a notification the other already did.
///
/// With `defaults`, the record survives relaunches: a notification that stays on screen across one, such
/// as one left to macOS, is neither listed again nor counted as a repeat, and a card dismissed before
/// the relaunch does not come back.
@MainActor
public final class NotificationIdentities {
    static let capacity = 2000
    static let defaultsKey = "notificationIdentities"

    private let defaults: UserDefaults?
    private var order: [String]
    private var members: Set<String>

    /// - Parameter defaults: Where the record is kept between launches; nil keeps it in memory only.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        order = Array((defaults?.stringArray(forKey: Self.defaultsKey) ?? []).suffix(Self.capacity))
        members = Set(order)
    }

    public func contains(_ identifier: String) -> Bool {
        members.contains(identifier.uppercased())
    }

    /// Records `identifier`; false when it was already recorded. The oldest are forgotten beyond `capacity`.
    @discardableResult
    public func insert(_ identifier: String) -> Bool {
        let identifier = identifier.uppercased()
        guard members.insert(identifier).inserted else { return false }
        order.append(identifier)
        if order.count > Self.capacity {
            members.remove(order.removeFirst())
        }
        defaults?.set(order, forKey: Self.defaultsKey)
        return true
    }
}
