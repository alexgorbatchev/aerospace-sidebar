import AppKit
import CoreGraphics

/// How long ago the user last clicked, pressed a key or scrolled anywhere but in this app, and whether the pointer
/// is in a menu bar: what tells a Notification Center history panel the user opened from the one a history request
/// asked the clock for (`NotificationHistoryOpener`). `system` reads the window server's record of the session's
/// input, which needs no permission, unlike an event tap, and leaves out input this app received itself
/// (`ReceivedInput`): the Return that sends a card's reply, or a scroll through the cards, comes with a request
/// and opens no panel.
public struct RecentUserInput {
    enum Kind: CaseIterable {
        /// A press of the left mouse button.
        case mouseDown
        case keyDown
        /// A scroll, or a trackpad gesture the Dock handles.
        case scroll
    }

    /// The two clocks `secondsSince(_:uptime:sessionAge:receivedAt:)` compares agree to well within this: the
    /// window server's ages, read against `systemUptime`, place an event to within 0.1 ms (measured on macOS 26.6).
    static let clockTolerance: TimeInterval = 0.01

    /// Seconds since the user's last input of a kind that this app did not receive.
    let secondsSince: @MainActor (Kind) -> TimeInterval
    /// Whether the pointer is in the menu bar of the screen it is on.
    let isPointerInMenuBar: @MainActor () -> Bool

    /// The window server's record of the session's input less this app's, and the pointer on the current screens.
    /// Each value records the input this app receives from when it is made.
    @MainActor public static var system: RecentUserInput {
        let received = ReceivedInput()
        return RecentUserInput(
            secondsSince: { kind in
                secondsSince(
                    kind,
                    uptime: ProcessInfo.processInfo.systemUptime,
                    sessionAge: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) },
                    receivedAt: received.latest(_:)
                )
            },
            isPointerInMenuBar: {
                isInMenuBar(
                    NSEvent.mouseLocation,
                    screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) },
                    menuBarThickness: NSStatusBar.system.thickness
                )
            }
        )
    }

    /// Seconds since the session's last input of `kind` that this app did not receive: the least of its event
    /// types' `sessionAge`s, leaving out each type whose last event happened, on the `uptime` clock, no later than
    /// this app received one of that type (`receivedAt`). The window server records an event before the app it goes
    /// to receives it, so that event was this app's. Input of that type before it may have gone elsewhere, but the
    /// window server keeps only the last, so the type then tells nothing.
    static func secondsSince(
        _ kind: Kind,
        uptime: TimeInterval,
        sessionAge: (CGEventType) -> TimeInterval,
        receivedAt: (CGEventType) -> TimeInterval?
    ) -> TimeInterval {
        kind.eventTypes.reduce(.infinity) { least, type in
            let age = sessionAge(type)
            if let received = receivedAt(type), uptime - age <= received + clockTolerance { return least }
            return min(least, age)
        }
    }

    /// Whether `point`, in screen coordinates, is in the menu bar at the top of one of `screens`. macOS 26 draws
    /// the menu bar 30 pt tall, 32 pt on a display with a camera housing, while `NSStatusBar.system.thickness`
    /// reports 22 pt (measured on macOS 26.6), so a screen's bar is the strip its visible frame leaves out at the
    /// top, where the Dock never sits. A menu bar that hides itself leaves nothing out, and the thickness stands
    /// in for it. `NSMouseInRect` counts a strip's top edge, where the pointer stops, and not its bottom edge.
    static func isInMenuBar(
        _ point: NSPoint,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        menuBarThickness: CGFloat
    ) -> Bool {
        screens.contains { screen in
            let height = max(menuBarThickness, screen.frame.maxY - screen.visibleFrame.maxY)
            let bar = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            return NSMouseInRect(point, bar, false)
        }
    }
}

extension RecentUserInput.Kind {
    /// The Dock's swipes, such as the one between Spaces, reach it as dock control events (InstantSpaceSwitcher,
    /// lockpaw), a type `CGEventType` does not name.
    static let dockControl = CGEventType(rawValue: 30)!

    /// The window server's event types for the kind. A trackpad gesture event (`NSEvent.EventType.gesture`) is not
    /// one: the trackpad driver sends one for any touch that makes no specific gesture, resting fingers included
    /// (Apple's "Handling Trackpad Events", lockpaw), so a click on a card made on a trackpad would count. Whether
    /// the swipe in from the screen's right edge that opens Notification Center is a dock control event or a
    /// scroll has not been measured.
    var eventTypes: [CGEventType] {
        switch self {
        case .mouseDown: [.leftMouseDown]
        case .keyDown: [.keyDown]
        case .scroll: [.scrollWheel, Self.dockControl]
        }
    }
}

/// When this app last received the input `RecentUserInput` reads, by event type, on the `systemUptime` clock. A
/// local event monitor sees the events this app dispatches (`NSApplication.sendEvent(_:)`), and needs no
/// permission. It records when the event arrived, which follows the window server's record of it, rather than the
/// event's timestamp, whose clock nothing checks against the window server's.
@MainActor
final class ReceivedInput {
    private var received: [CGEventType.RawValue: TimeInterval] = [:]
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event, at: ProcessInfo.processInfo.systemUptime) }
            return event
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func record(_ event: NSEvent, at uptime: TimeInterval) {
        received[CGEventType.RawValue(event.type.rawValue)] = uptime
    }

    /// When this app last received an event of `type`, or nil when it has received none since this was made.
    func latest(_ type: CGEventType) -> TimeInterval? {
        received[type.rawValue]
    }
}
