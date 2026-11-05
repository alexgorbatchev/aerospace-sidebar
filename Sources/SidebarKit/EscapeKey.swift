import HotKey

/// Escape as a system-wide hot key (`RegisterEventHotKey`, through HotKey): it reaches the app whichever window
/// has the keyboard, needs no permission, and takes the key from every other app while it is registered.
@MainActor
struct EscapeKey {
    /// Registers `handler` for Escape and returns what holds the registration; releasing it unregisters the key.
    let register: @MainActor (_ handler: @escaping @MainActor () -> Void) -> AnyObject

    static let system = EscapeKey { handler in
        // Carbon delivers hot keys on the main thread, from the application's event dispatcher.
        HotKey(key: .escape, modifiers: [], keyDownHandler: { MainActor.assumeIsolated(handler) })
    }
}
