import Carbon.HIToolbox
import Foundation
import Magnet

/// Escape as a system-wide hot key (`RegisterEventHotKey`, through Magnet): it reaches the app whichever window has
/// the keyboard, needs no permission, and takes the key from every other app while it is registered.
@MainActor
public struct EscapeKey {
    /// Registers `handler` for Escape and returns what holds the registration, which unregisters the key when
    /// released, or nil when the system refuses the key, as when another app holds it.
    let register: @MainActor (_ handler: @escaping @MainActor () -> Void) -> AnyObject?

    public static let system = EscapeKey { handler in
        guard let escape = KeyCombo(QWERTYKeyCode: kVK_Escape, cocoaModifiers: []) else { return nil }
        // Magnet runs the handler on the main queue.
        let hotKey = HotKey(identifier: "escape-\(UUID().uuidString)", keyCombo: escape, actionQueue: .main) { _ in
            MainActor.assumeIsolated(handler)
        }
        return hotKey.register() ? Registration(hotKey) : nil
    }

    /// Magnet's registry keeps a hot key until it is unregistered, so the registration is this owner instead.
    private final class Registration {
        private let hotKey: HotKey

        init(_ hotKey: HotKey) {
            self.hotKey = hotKey
        }

        deinit {
            hotKey.unregister()
        }
    }
}
