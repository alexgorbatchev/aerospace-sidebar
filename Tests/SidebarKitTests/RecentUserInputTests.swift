import AppKit
@testable import SidebarKit
import Testing

/// The user's recent input as a test sets it: none until a test says how long ago some was given.
@MainActor
final class FakeUserInput {
    var secondsSince: [RecentUserInput.Kind: TimeInterval] = [:]
    var pointerInMenuBar = false

    var reader: RecentUserInput {
        RecentUserInput(
            secondsSince: { self.secondsSince[$0] ?? .infinity },
            isPointerInMenuBar: { self.pointerInMenuBar }
        )
    }
}

@MainActor
struct RecentUserInputTests {
    /// Screens as macOS 26.6 lays them out on a desk: a main display with a 30 pt menu bar, a built-in display
    /// whose bar beside the camera housing is 32 pt tall, and one whose menu bar hides itself.
    static let screens: [(frame: NSRect, visibleFrame: NSRect)] = [
        (NSRect(x: 0, y: 0, width: 2560, height: 1440), NSRect(x: 0, y: 0, width: 2560, height: 1410)),
        (NSRect(x: 2560, y: 143, width: 1728, height: 1117), NSRect(x: 2560, y: 143, width: 1728, height: 1085)),
        (NSRect(x: 0, y: 1440, width: 1920, height: 1080), NSRect(x: 0, y: 1440, width: 1920, height: 1080)),
    ]

    func isInMenuBar(_ x: CGFloat, _ y: CGFloat) -> Bool {
        RecentUserInput.isInMenuBar(NSPoint(x: x, y: y), screens: Self.screens, menuBarThickness: 22)
    }

    /// A screen's menu bar is the strip its visible frame leaves out at the top, however much taller than the
    /// reported thickness it is, from its top edge, where the pointer stops, down to just above its bottom edge.
    @Test func findsThePointerInEachScreensMenuBar() {
        #expect(isInMenuBar(100, 1440))
        #expect(isInMenuBar(100, 1415))
        #expect(!isInMenuBar(100, 1410))
        #expect(isInMenuBar(3000, 1229))
        #expect(!isInMenuBar(3000, 1228))
        #expect(!isInMenuBar(3000, 700))
    }

    /// A menu bar that hides itself leaves the visible frame whole, so the reported thickness stands in for it.
    @Test func usesTheThicknessForAMenuBarThatHides() {
        #expect(isInMenuBar(100, 2520))
        #expect(isInMenuBar(100, 2499))
        #expect(!isInMenuBar(100, 2498))
    }

    @Test func findsNoMenuBarOffTheScreens() {
        #expect(!isInMenuBar(-100, 1440))
        #expect(!isInMenuBar(5000, 1260))
        #expect(!RecentUserInput.isInMenuBar(NSPoint(x: 100, y: 1440), screens: [], menuBarThickness: 22))
    }

    /// The session's input as the window server reports it: how long ago each event type last happened, on an
    /// uptime clock at `uptime`, and when this app last received each type.
    struct Session {
        var uptime: TimeInterval = 100
        var ages: [CGEventType.RawValue: TimeInterval] = [:]
        var received: [CGEventType.RawValue: TimeInterval] = [:]

        func secondsSince(_ kind: RecentUserInput.Kind) -> TimeInterval {
            RecentUserInput.secondsSince(
                kind,
                uptime: uptime,
                sessionAge: { ages[$0.rawValue] ?? .infinity },
                receivedAt: { received[$0.rawValue] }
            )
        }
    }

    /// Each kind reads its own input: a click, a key press, and a scroll or a swipe the Dock handles.
    @Test func readsEachKindFromItsOwnInput() {
        var session = Session()
        session.ages[CGEventType.leftMouseDown.rawValue] = 0.1
        session.ages[CGEventType.keyDown.rawValue] = 0.2
        session.ages[CGEventType.scrollWheel.rawValue] = 0.3
        #expect(session.secondsSince(.mouseDown) == 0.1)
        #expect(session.secondsSince(.keyDown) == 0.2)
        #expect(session.secondsSince(.scroll) == 0.3)

        session.ages[RecentUserInput.Kind.dockControl.rawValue] = 0.25
        #expect(session.secondsSince(.scroll) == 0.25)
    }

    /// The trackpad driver sends a gesture event for any touch, the one that clicks a card included, so a gesture
    /// event is no scroll; neither is a mouse movement.
    @Test func ignoresTouchesThatMakeNoDockGesture() {
        var session = Session()
        session.ages[UInt32(NSEvent.EventType.gesture.rawValue)] = 0
        session.ages[CGEventType.mouseMoved.rawValue] = 0
        session.ages[CGEventType.scrollWheel.rawValue] = 30
        #expect(session.secondsSince(.scroll) == 30)
        #expect(session.secondsSince(.mouseDown) == .infinity)
    }

    /// Input whose last event happened no later than this app received one of its type was this app's, the Return
    /// in a card's reply field or a scroll through the cards, and does not count; a later one went elsewhere and
    /// counts. Of a kind's types, only those that were this app's are left out.
    @Test func leavesOutInputThisAppReceived() {
        var session = Session()
        session.ages[CGEventType.keyDown.rawValue] = 0.5
        session.received[CGEventType.keyDown.rawValue] = 99.5
        #expect(session.secondsSince(.keyDown) == .infinity)
        session.received[CGEventType.keyDown.rawValue] = 99.5 - RecentUserInput.clockTolerance / 2
        #expect(session.secondsSince(.keyDown) == .infinity)

        session.received[CGEventType.keyDown.rawValue] = 99.4
        #expect(session.secondsSince(.keyDown) == 0.5)

        session.ages[CGEventType.scrollWheel.rawValue] = 0.1
        session.received[CGEventType.scrollWheel.rawValue] = 99.95
        session.ages[RecentUserInput.Kind.dockControl.rawValue] = 0.7
        #expect(session.secondsSince(.scroll) == 0.7)
    }

    /// The monitor records the clicks and scrolls this app dispatches, when they arrive, and nothing it does not
    /// receive.
    @Test func recordsTheInputThisAppDispatches() throws {
        let app = NSApplication.shared
        let received = ReceivedInput()
        let before = ProcessInfo.processInfo.systemUptime
        app.sendEvent(try Self.windowlessMouseDown())
        app.sendEvent(try Self.scroll())
        let after = ProcessInfo.processInfo.systemUptime

        let click = try #require(received.latest(.leftMouseDown))
        let scroll = try #require(received.latest(.scrollWheel))
        #expect(click >= before && click <= scroll && scroll <= after)
        #expect(received.latest(.keyDown) == nil)

        received.record(try Self.returnKey(), at: 7)
        #expect(received.latest(.keyDown) == 7)
    }

    /// `system` leaves out what this app received: the window server recorded its last click before this app
    /// dispatched one, so no click went elsewhere since. Read-only against the window server.
    @Test func systemLeavesOutInputThisAppReceived() throws {
        let system = RecentUserInput.system
        NSApplication.shared.sendEvent(try Self.windowlessMouseDown())

        #expect(system.secondsSince(.mouseDown) == .infinity)
    }

    /// A click that reaches no window: the app dispatches it, and nothing takes it.
    static func windowlessMouseDown() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// A press of Return, as in a card's reply field; nothing dispatches it.
    static func returnKey() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
    }

    static func scroll() throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }
}
