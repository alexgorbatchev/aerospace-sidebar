import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

struct PressSequenceTests {
    @Test func slowClickPressesInThenReleasesAndTriggers() {
        var sut = PressSequence()

        #expect(sut.press() == .pressIn)
        #expect(sut.pressFinished() == .none)
        #expect(sut.phase == .held)
        #expect(sut.release(.primary) == .release(.primary))
        sut.releaseFinished()
        #expect(sut.phase == .idle)
    }

    @Test func quickClickWaitsForThePressInBeforeReleasing() {
        var sut = PressSequence()

        #expect(sut.press() == .pressIn)
        // The mouse goes up while the press-in is still animating.
        #expect(sut.release(.primary) == .none)
        #expect(sut.phase == .pressing)
        #expect(sut.pressFinished() == .release(.primary))
        #expect(sut.phase == .releasing)
    }

    @Test func releaseWithoutAReportedPressPlaysTheWholePress() {
        var sut = PressSequence()

        #expect(sut.release(.primary) == .pressIn)
        #expect(sut.pressFinished() == .release(.primary))
    }

    @Test func releasingOutsideAnimatesBackWithoutTriggering() {
        var sut = PressSequence()
        _ = sut.press()

        #expect(sut.release(.outside) == .none)
        #expect(sut.pressFinished() == .release(.outside))
    }

    @Test func optionClickReleasesWithTheAlternateAction() {
        var sut = PressSequence()

        #expect(sut.press() == .pressIn)
        #expect(sut.release(.alternate) == .none)
        #expect(sut.pressFinished() == .release(.alternate))
        sut.releaseFinished()
        #expect(sut.press() == .pressIn)
        _ = sut.pressFinished()
        #expect(sut.release(.alternate) == .release(.alternate))
    }

    @Test func repeatedEventsDuringAnAnimationAreIgnored() {
        var sut = PressSequence()
        _ = sut.press()

        // The drag gesture reports every pointer move while the mouse is down.
        #expect(sut.press() == .none)
        _ = sut.pressFinished()
        #expect(sut.press() == .none)
        #expect(sut.pressFinished() == .none)
        #expect(sut.release(.primary) == .release(.primary))
        #expect(sut.press() == .none)
        #expect(sut.release(.primary) == .none)
        sut.releaseFinished()
        #expect(sut.press() == .pressIn)
    }
}

/// Clicks a hosted button with real mouse events, so its gesture, state and animation completions run.
@MainActor
@Suite(.leavesDesktopAlone)
struct PressableButtonTests {
    let window = TestPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)

    /// - Parameter modifierFlags: The modifier keys the button sees held down.
    func host(modifierFlags: NSEvent.ModifierFlags = [], alternateAction: (() -> Void)? = nil, action: @escaping () -> Void) {
        let button = Button(action: action) { Color.gray.frame(width: 200, height: 100) }
            .buttonStyle(PressableButtonStyle(alternateAction: alternateAction, modifierFlags: { modifierFlags }))
        window.contentView = NSHostingView(rootView: button)
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Mouse down at `down` and up at `up` in window coordinates, with nothing in between.
    func click(down: NSPoint, up: NSPoint) throws {
        for (type, location) in [(NSEvent.EventType.leftMouseDown, down), (.leftMouseUp, up)] {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
        }
    }

    /// Lets the press animation run, returning once `done` holds or after a second.
    func wait(until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func instantClickTriggersAfterThePressIn() async throws {
        var triggers = 0
        host { triggers += 1 }

        try click(down: NSPoint(x: 100, y: 50), up: NSPoint(x: 100, y: 50))
        #expect(triggers == 0)
        try await wait { triggers > 0 }

        #expect(triggers == 1)
    }

    @Test func optionClickTriggersTheAlternateAction() async throws {
        var triggers = 0
        var alternates = 0
        host(modifierFlags: .option, alternateAction: { alternates += 1 }, action: { triggers += 1 })

        try click(down: NSPoint(x: 100, y: 50), up: NSPoint(x: 100, y: 50))
        try await wait { alternates > 0 }

        #expect(alternates == 1)
        #expect(triggers == 0)
    }

    @Test func optionClickWithoutAnAlternateActionTriggersTheAction() async throws {
        var triggers = 0
        host(modifierFlags: .option) { triggers += 1 }

        try click(down: NSPoint(x: 100, y: 50), up: NSPoint(x: 100, y: 50))
        try await wait { triggers > 0 }

        #expect(triggers == 1)
    }

    @Test func releaseOutsideDoesNotTrigger() async throws {
        var triggers = 0
        host { triggers += 1 }

        try click(down: NSPoint(x: 100, y: 50), up: NSPoint(x: 400, y: 50))
        try await Task.sleep(for: .milliseconds(400))

        #expect(triggers == 0)
    }
}
