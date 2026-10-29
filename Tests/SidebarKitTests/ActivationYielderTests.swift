import AppKit
@testable import SidebarKit
import Testing

@MainActor
@Suite(.leavesDesktopAlone)
struct ActivationYielderTests {
    let workspaceCenter = NotificationCenter()
    let handedOver = HandedOver()

    /// Apps other than the test process; they are only named, never activated.
    let regularApp: NSRunningApplication
    let accessoryApp: NSRunningApplication

    init() throws {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() }
        regularApp = try #require(apps.first { $0.activationPolicy == .regular })
        accessoryApp = try #require(apps.first { $0.activationPolicy == .accessory })
    }

    func makeYielder(
        frontmostApp: NSRunningApplication?, pointerOverFontPanel: Bool = false, activationAllowed: Bool = true
    ) -> ActivationYielder {
        ActivationYielder(
            workspaceCenter: workspaceCenter,
            frontmostApp: frontmostApp,
            isPointerOverFontPanel: { pointerOverFontPanel },
            handOver: { [handedOver] in
                handedOver.apps.append($0.processIdentifier)
                return activationAllowed
            },
            deactivate: { [handedOver] in handedOver.deactivations += 1 }
        )
    }

    func activate(_ app: NSRunningApplication) {
        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: app])
    }

    /// Opening a URL or launching activates this app; the app in front before gets activation back.
    @Test func handsActivationBackToTheAppInFrontBefore() {
        let yielder = makeYielder(frontmostApp: regularApp)

        activate(.current)
        yielder.appDidBecomeActive()

        #expect(handedOver.apps == [regularApp.processIdentifier])
        #expect(handedOver.deactivations == 0)
    }

    @Test func followsTheAppsTheUserSwitchesTo() {
        let yielder = makeYielder(frontmostApp: nil)

        activate(regularApp)
        activate(.current)
        yielder.appDidBecomeActive()

        #expect(yielder.previousApp?.processIdentifier == regularApp.processIdentifier)
        #expect(handedOver.apps == [regularApp.processIdentifier])
    }

    /// A launcher that opened the URL closes its window as it does; activating it would leave no key window.
    @Test func passesOverAccessoryApps() {
        let launchedFrom = makeYielder(frontmostApp: accessoryApp)
        let switchedThrough = makeYielder(frontmostApp: regularApp)

        activate(accessoryApp)
        launchedFrom.appDidBecomeActive()
        switchedThrough.appDidBecomeActive()

        #expect(launchedFrom.previousApp == nil)
        #expect(handedOver.apps == [regularApp.processIdentifier])
        #expect(handedOver.deactivations == 1)
    }

    /// A click on the font panel activates the app so that its fields take the keyboard.
    @Test func leavesActivationByAClickOnTheFontPanelAlone() {
        let yielder = makeYielder(frontmostApp: regularApp, pointerOverFontPanel: true)

        yielder.appDidBecomeActive()

        #expect(handedOver.apps.isEmpty)
        #expect(handedOver.deactivations == 0)
    }

    /// The system picks the next app, rather than this one staying active without a key window.
    @Test func deactivatesWithoutAnotherAppToHandItTo() {
        let yielder = makeYielder(frontmostApp: .current)

        yielder.appDidBecomeActive()

        #expect(yielder.previousApp == nil)
        #expect(handedOver.apps.isEmpty)
        #expect(handedOver.deactivations == 1)
    }

    /// An app that has quit since it was in front cannot take activation.
    @Test func deactivatesWhenTheSystemRefusesTheHandOver() {
        let yielder = makeYielder(frontmostApp: regularApp, activationAllowed: false)

        yielder.appDidBecomeActive()

        #expect(handedOver.apps == [regularApp.processIdentifier])
        #expect(handedOver.deactivations == 1)
    }

    /// A hidden font panel keeps its frame, but a click there lands on whatever is below it.
    @Test func countsOnlyPointsOverAWindowThatShows() {
        let panel = TestPanel(contentRect: NSRect(x: 100, y: 200, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: true)
        let inside = NSPoint(x: 250, y: 400)

        #expect(!ActivationYielder.isPoint(inside, over: panel))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        #expect(ActivationYielder.isPoint(inside, over: panel))
        #expect(!ActivationYielder.isPoint(NSPoint(x: 50, y: 400), over: panel))
        #expect(!ActivationYielder.isPoint(inside, over: nil))
    }
}

@MainActor
final class HandedOver {
    var apps: [pid_t] = []
    var deactivations = 0
}
