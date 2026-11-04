import AppKit
@testable import SidebarKit
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite(.leavesDesktopAlone)
struct SidebarPanelControllerTests {
    let directory: TemporaryDirectory
    let settings: SettingsStore

    init() throws {
        _ = NSApplication.shared
        directory = try TemporaryDirectory()
        settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
    }

    @Test func pinShowsPanelOnConfiguredStrip() {
        settings.update { $0.sidebar.width = 240 }
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )

        controller.pin()

        #expect(controller.panel.frame == CGRect(x: 1200, y: 40, width: 240, height: 860))
        #expect(controller.panel.isVisible)
    }

    /// SwiftUI's first layout happens at the panel's initial size; a layout at zero width would grow every
    /// card out of nothing as soon as the sidebar animates any change.
    @Test func panelStartsOnTheStripBeforeItIsShown() throws {
        settings.update { $0.sidebar.width = 240 }
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )
        let contentView = try #require(controller.panel.contentView)

        #expect(controller.panel.frame == CGRect(x: 1200, y: 40, width: 240, height: 860))
        #expect(contentView.frame.size == CGSize(width: 240, height: 860))
        #expect(!controller.panel.isVisible)
    }

    /// The sidebar steps behind System Settings, which AeroSpace floats and so may sit under the strip, while
    /// the user grants a permission there.
    @Test func stepsBehindSystemSettings() {
        let workspaceCenter = NotificationCenter()
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            workspaceCenter: workspaceCenter
        )
        defer { controller.panel.orderOut(nil) }

        controller.follower.follow(frontmostApp: SystemSettingsFollower.systemSettingsBundleID)
        controller.pin()
        #expect(controller.panel.level == .normal)
        #expect(controller.panel.isVisible)

        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(controller.panel.level == SidebarPanelController.level)
        #expect(controller.panel.isVisible)
    }

    @Test func repinsWhenSideOrWidthChanges() {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        #expect(controller.panel.frame == CGRect(x: 1140, y: 40, width: 300, height: 860))

        settings.update { $0.sidebar = SidebarSettings.Sidebar(side: .left, width: 400) }

        #expect(controller.panel.frame == CGRect(x: 0, y: 40, width: 400, height: 860))
    }

    @Test func otherSettingsLeaveTheHiddenPanelAlone() {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 860) },
            notificationCenter: NotificationCenter()
        )

        settings.update { $0.history.maxCount = 50 }

        #expect(!controller.panel.isVisible)
    }

    /// The background fills the strip from the top of the screen to the bottom while it has any opacity, follows
    /// the settings and Settings' preview, and goes with the screen.
    @Test func showsTheBackgroundOnTheStripsFullHeight() {
        let visibleFrame = Mutable<CGRect?>(CGRect(x: 0, y: 40, width: 1440, height: 830))
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame.value },
            targetScreenFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        let window = controller.background.window
        controller.pin()
        #expect(!window.isVisible)

        let teal = SidebarSettings.RGBColor(red: 0, green: 128, blue: 128)
        settings.update { $0.background = SidebarSettings.Background(color: teal, opacity: 0.5) }
        #expect(window.isVisible)
        #expect(window.frame == CGRect(x: 1140, y: 0, width: 300, height: 900))
        #expect(window.backgroundColor == teal.nsColor.withAlphaComponent(0.5))
        // Above other apps' windows, below the Dock and the menu bar.
        #expect(window.level == SidebarBackground.level && window.level > .floating)
        #expect(window.level.rawValue < Int(CGWindowLevelForKey(.dockWindow)) && window.level < .mainMenu)
        #expect(window.ignoresMouseEvents)

        settings.update { $0.sidebar = .init(side: .left, width: 200) }
        #expect(window.frame == CGRect(x: 0, y: 0, width: 200, height: 900))

        settings.preview(background: SidebarSettings.Background(color: teal, opacity: 0))
        #expect(!window.isVisible)
        settings.preview(background: nil)
        #expect(window.isVisible)

        visibleFrame.value = nil
        controller.pin()
        #expect(!window.isVisible)
        window.close()
    }

    /// Behind System Settings the background goes with the panel, just below it, so it covers neither System
    /// Settings nor the cards, and comes back above other windows with it.
    @Test func backgroundStepsBehindSystemSettingsUnderThePanel() throws {
        let workspaceCenter = NotificationCenter()
        settings.update { $0.background.opacity = 0.5 }
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 40, width: 1440, height: 830) },
            targetScreenFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            workspaceCenter: workspaceCenter
        )
        let background = controller.background.window
        defer {
            controller.panel.orderOut(nil)
            background.orderOut(nil)
        }
        controller.pin()

        controller.follower.follow(frontmostApp: SystemSettingsFollower.systemSettingsBundleID)
        #expect(background.level == .normal)
        let order = NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
        let panelIndex = try #require(order.firstIndex(of: controller.panel.windowNumber))
        let backgroundIndex = try #require(order.firstIndex(of: background.windowNumber))
        // Front to back: the panel, then the background right under it.
        #expect(backgroundIndex == panelIndex + 1)

        workspaceCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                             userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(background.level == SidebarBackground.level)
        #expect(background.isVisible)
    }

    @Test func pinHidesPanelWhenTargetScreenIsGone() {
        let visibleFrame = Mutable<CGRect?>(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame.value },
            notificationCenter: NotificationCenter()
        )
        controller.pin()

        visibleFrame.value = nil
        controller.pin()

        #expect(!controller.panel.isVisible)
    }

    @Test func repinsWhenScreenParametersChange() {
        let notificationCenter = NotificationCenter()
        let visibleFrame = Mutable(CGRect(x: 0, y: 0, width: 1440, height: 900))
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { visibleFrame.value },
            notificationCenter: notificationCenter
        )
        controller.pin()

        visibleFrame.value = CGRect(x: 0, y: 80, width: 2560, height: 1300)
        notificationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(controller.panel.frame == CGRect(x: 2260, y: 80, width: 300, height: 1300))
    }

    @Test(.enabled(if: !NSScreen.screens.isEmpty, "requires a display"))
    func defaultControllerPinsToPrimaryScreen() throws {
        let primary = try #require(NSScreen.screens.first)
        let controller = SidebarPanelController.forTesting(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter())

        controller.pin()

        #expect(controller.panel.frame.maxX == primary.visibleFrame.maxX)
        #expect(controller.panel.frame.height == primary.visibleFrame.height)
    }

    /// AeroSpace treats windows of accessory apps without a close button as popups,
    /// which keeps the sidebar out of tiling and workspace hiding.
    @Test func panelStaysOutOfAeroSpaceManagement() {
        let panel = SidebarPanelController.forTesting(model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()), settings: settings, notificationCenter: NotificationCenter()).panel

        #expect(panel.standardWindowButton(.closeButton) == nil)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.hidesOnDeactivate)
    }

    /// Borderless windows refuse key status unless the panel overrides it; the panel accepts it only for a
    /// click on it, so launching or closing Settings leaves keyboard focus with the frontmost app. Making
    /// the panel key to assert `isKeyWindow` would take the user's keyboard focus from the frontmost app.
    @Test func panelTakesKeyboardFocusOnlyWhenClicked() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let panel = try #require(controller.panel as? SidebarPanel)
        func event(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        let other = TestPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.orderFrontRegardless()
        defer { other.orderOut(nil) }

        #expect(panel.styleMask.contains(.nonactivatingPanel))
        // Launching: AppKit makes a window key with no event to handle.
        #expect(!panel.canBecomeKey)
        #expect(!panel.acceptsKeyStatus(during: nil))
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            #expect(panel.acceptsKeyStatus(during: event(type, in: panel)))
        }
        #expect(!panel.acceptsKeyStatus(during: event(.leftMouseUp, in: panel)))
        // Closing Settings with a click: AppKit looks for the next key window.
        #expect(!panel.acceptsKeyStatus(during: event(.leftMouseDown, in: other)))
    }

    /// A click makes the panel key only on the view it hits answering `needsPanelToBecomeKey`
    /// (`becomesKeyOnlyIfNeeded`). `NSHostingView` answers yes everywhere, so a click on a card took the keyboard
    /// from the app the user was typing in; the sidebar's host answers no, and SwiftUI's text fields still answer yes.
    @Test func onlyAClickOnAFieldMakesThePanelKey() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        let panel = try #require(controller.panel as? NSPanel)
        #expect(panel.becomesKeyOnlyIfNeeded)
        #expect(panel.contentView is SidebarHostingView<SidebarPanelContent>)

        struct Card: View {
            @State var reply = ""
            var body: some View {
                ScrollView {
                    VStack(spacing: 0) {
                        Button("Card") {}.frame(width: 200, height: 50)
                        TextField("Reply", text: $reply).frame(width: 200, height: 30)
                    }
                }
                .frame(width: 200, height: 80)
            }
        }
        let host = SidebarHostingView(rootView: Card())
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 80)
        let window = TestPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func clickNeedsKey(atY y: CGFloat) throws -> Bool {
            try #require(host.hitTest(CGPoint(x: 100, y: y))).needsPanelToBecomeKey
        }

        // SwiftUI promises no flipping, so locate the field and click the button's half on the other side of it.
        func textField(in view: NSView) -> NSTextField? {
            view as? NSTextField ?? view.subviews.lazy.compactMap(textField(in:)).first
        }
        let field = try #require(textField(in: host))
        // hitTest takes a point in the superview's coordinates, which are the window's here.
        let fieldY = field.convert(field.bounds, to: nil).midY
        #expect(!(try clickNeedsKey(atY: fieldY < 40 ? 55 : 25)))
        #expect(try clickNeedsKey(atY: fieldY))
        #expect(!host.needsPanelToBecomeKey)
    }

    /// Opening a field to type into makes the panel key, which VoiceOver does without a click: the content asks
    /// through `requestKeyboard`, and the panel grants itself key status for that one call only.
    @Test func panelTakesTheKeyboardWhenAFieldOpens() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        let panel = try #require(controller.panel as? SidebarPanel)
        var granted: [Bool] = []
        panel.becomeKey = { window in granted.append((window as? SidebarPanel)?.acceptsKeyStatus(during: nil) == true) }
        let content = try #require(panel.contentView as? NSHostingView<SidebarPanelContent>)

        content.rootView.requestKeyboard()

        #expect(granted == [true])
        #expect(!panel.acceptsKeyStatus(during: nil))
    }

    /// The content asks the panel whether the pointer is on it before an arriving notification scrolls the list
    /// (`pointerIsOnSidebar`): over it, or dragging from a press on it wherever the pointer goes.
    @Test func contentAsksThePanelWhetherThePointerIsOnIt() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        let panel = try #require(controller.panel as? SidebarPanel)
        let content = try #require(panel.contentView as? NSHostingView<SidebarPanelContent>)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }

        // Off screen no click reaches the panel, even with the pointer inside its frame.
        panel.pointerLocation = { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }
        #expect(!panel.isVisible)
        #expect(!content.rootView.pointerIsOn())
        panel.track(try event(.leftMouseDown))
        #expect(content.rootView.pointerIsOn())
        panel.track(try event(.leftMouseDragged))
        #expect(content.rootView.pointerIsOn())
        // The panel notes the release of a press as AppKit sends it.
        panel.sendEvent(try event(.leftMouseUp))
        #expect(!content.rootView.pointerIsOn())
        panel.track(try event(.rightMouseDown))
        panel.track(try event(.rightMouseUp))
        #expect(!content.rootView.pointerIsOn())
    }

    @Test func rendersContentInsidePanel() throws {
        let controller = SidebarPanelController.forTesting(
            model: SidebarModel(performer: RecordingPerformer(), store: InMemoryStore()),
            settings: settings,
            targetVisibleFrame: { CGRect(x: 0, y: 0, width: 1440, height: 900) },
            notificationCenter: NotificationCenter()
        )
        controller.pin()
        let contentView = try #require(controller.panel.contentView)

        contentView.layoutSubtreeIfNeeded()

        // The SwiftUI content fills the panel directly.
        #expect(contentView is NSHostingView<SidebarPanelContent>)
        #expect(contentView.frame.size == controller.panel.frame.size)
    }

    /// Where the panel receives clicks is also where the pointer is on the sidebar, and arriving notifications
    /// leave the list alone (`SidebarPanel.hasPointer`); a window above the strip takes both.
    @Test(.showsWindowsOnScreen)
    func transparentListAreaRetainsMouseEvents() async throws {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore())
        model.add(SidebarNotification(source: "test", title: "One card"))
        // Not `forTesting`: the window server skips transparent windows, so this panel shows on screen
        // briefly. Borderless and never made key, it leaves the user's keyboard focus alone.
        let controller = SidebarPanelController(model: model, settings: settings, notificationCenter: NotificationCenter())
        let panel = try #require(controller.panel as? SidebarPanel)
        panel.identifier = .windowServerProbe
        let screen = try #require(NSScreen.screens.first)
        panel.setFrame(CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY, width: 300, height: 600), display: true)
        panel.level = .popUpMenu
        panel.orderFrontRegardless()
        defer { panel.close() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        // Sample the entire lower list, including both gutters and empty space below the card.
        // These must stay interactive even where there are no cards.
        for x in [CGFloat(2), 150, 298] {
            for y in stride(from: CGFloat(200), through: 500, by: 50) {
                let point = CGPoint(x: x, y: content.isFlipped ? y : 600 - y)
                #expect(content.hitTest(point) != nil, "List lost mouse events at \(point)")
                let screenPoint = panel.convertPoint(toScreen: content.convert(point, to: nil))
                #expect(NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == panel.windowNumber,
                        "Window server passed through the list at \(point)")
                #expect(panel.receivesClicks(at: screenPoint))
            }
        }
        let sidebar = try #require(content as? NSHostingView<SidebarPanelContent>)
        panel.pointerLocation = { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }
        #expect(sidebar.rootView.pointerIsOn())
        panel.pointerLocation = { CGPoint(x: panel.frame.minX - 1, y: panel.frame.midY) }
        #expect(!sidebar.rootView.pointerIsOn())

        // A window over the strip's upper half, with a backing as faint as the sidebar's, takes the clicks there.
        let cover = NSPanel(
            contentRect: CGRect(x: panel.frame.minX, y: panel.frame.midY, width: 300, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        cover.identifier = .windowServerProbe
        cover.isReleasedWhenClosed = false
        cover.isOpaque = false
        cover.backgroundColor = NSColor.black.withAlphaComponent(0.01)
        cover.hasShadow = false
        cover.level = .screenSaver
        cover.orderFrontRegardless()
        defer { cover.orderOut(nil) }
        cover.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let covered = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 100)
        #expect(NSWindow.windowNumber(at: covered, belowWindowWithWindowNumber: 0) == cover.windowNumber)
        panel.pointerLocation = { covered }
        #expect(!sidebar.rootView.pointerIsOn())
        panel.pointerLocation = { CGPoint(x: panel.frame.midX, y: panel.frame.minY + 100) }
        #expect(sidebar.rootView.pointerIsOn())
    }
}
