/// The UUIDs of native notifications already listed. NotificationCenter shows each notification's UUID
/// as its `AXIdentifier`, and the notification database records the same UUID (OmniWM), so both sources
/// share this record and neither lists a notification the other already did.
@MainActor
public final class NotificationIdentities {
    static let capacity = 2000

    private var order: [String] = []
    private var members: Set<String> = []

    public init() {}

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
        return true
    }
}
