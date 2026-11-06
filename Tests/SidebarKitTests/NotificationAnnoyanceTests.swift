import AppKit
@testable import SidebarKit
import SidebarProtocol
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite(.leavesDesktopAlone)
struct NotificationAnnoyanceTests {
    @Test func waitsThenRepeatsWithoutNewArrivalsResettingTheOwner() throws {
        var now = Date()
        let start = now
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(),
                                 rules: [Rule(source: "Slack", display: .jiggle)], now: { now })
        let first = SidebarNotification(source: "Slack", title: "first", receivedAt: now)
        model.add(first)
        now += 299
        model.advanceAnnoyance()
        #expect(model.annoyance.jiggle == 0)
        model.add(SidebarNotification(source: "Slack", title: "first", receivedAt: now))
        model.add(SidebarNotification(source: "Slack", title: "new", receivedAt: now))
        model.add(SidebarNotification(source: "Slack", title: "late database arrival", receivedAt: start - 30))
        #expect(model.annoyance.active?.id == first.id)
        #expect(model.annoyance.deadline == start + 300)
        now += 1
        model.advanceAnnoyance()
        #expect(model.annoyance.jiggle == 1)
        #expect(model.annoyance.deadline == now + 300)
        now += 600
        model.advanceAnnoyance()
        #expect(model.annoyance.jiggle == 2)
        model.dismiss(first.id)
        #expect(model.notifications.first { $0.id == model.annoyance.active?.id }?.title == "late database arrival")
        #expect(model.annoyance.deadline == now + 300)
    }

    @Test func blackoutPersistsAndActionStartsNextFullInterval() throws {
        var now = Date()
        let performer = RecordingPerformer()
        let model = SidebarModel(performer: performer, store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let first = SidebarNotification(source: "Slack", title: "first", action: .activateApp(name: "Slack"), receivedAt: now)
        model.add(first)
        model.add(SidebarNotification(source: "Slack", title: "second", receivedAt: now + 1))
        now += 300
        model.advanceAnnoyance()
        #expect(model.annoyance.blocking)
        #expect(model.annoyance.deadline == nil)
        now += 100_000
        model.advanceAnnoyance()
        model.pruneExpired()
        #expect(model.annoyance.blocking)
        #expect(model.notifications.contains { $0.id == first.id })
        model.add(SidebarNotification(source: "Slack", title: "third", receivedAt: now))
        model.activate(first.id)
        #expect(!model.annoyance.blocking)
        #expect(model.annoyance.deadline == now + 300)
        #expect(model.notifications.first { $0.id == model.annoyance.active?.id }?.title == "third")
        model.clear()
        #expect(model.annoyance.active == nil)
        #expect(model.annoyance.deadline == nil)
    }

    @Test func restoredCardsStartWithOldestAndRuleChangesReschedule() {
        var now = Date()
        let store = InMemoryStore()
        store.stored = [SidebarNotification(source: "Slack", title: "new", receivedAt: now),
                        SidebarNotification(source: "Slack", title: "old", receivedAt: now - 10)]
        let model = SidebarModel(performer: RecordingPerformer(), store: store,
                                 rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        #expect(model.annoyance.active?.id == store.stored.last?.id)
        now += 300
        model.advanceAnnoyance()
        model.apply(rules: [Rule(source: "Slack", display: .jiggle, intervalMinutes: 2)])
        #expect(!model.annoyance.blocking)
        #expect(model.annoyance.deadline == now + 120)
        model.apply(rules: [Rule(source: "Slack")])
        #expect(model.annoyance.active == nil)
        model.apply(rules: [Rule(source: "Slack", action: .hide, display: .blackout)])
        #expect(model.notifications.isEmpty)
    }

    @Test func firstMatchingRuleControlsEligibilityAndSenderFilter() {
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [
            Rule(source: "Slack", title: "Alice", display: .blackout), Rule(source: "Slack", display: .jiggle),
        ])
        model.add(SidebarNotification(source: "Mail", title: "Alice"))
        #expect(model.annoyance.active == nil)
        model.add(SidebarNotification(source: "Slack", title: "Alice"))
        #expect(model.annoyance.active?.display == .blackout)
        model.add(SidebarNotification(source: "Slack", title: "Bob"))
        #expect(model.annoyance.queue.map(\.display) == [.blackout, .jiggle])
    }

    @Test func configRoundTripAndInvalidIntervals() throws {
        let directory = try TemporaryDirectory()
        let file = SettingsFile(url: directory.url.appendingPathComponent("config.toml"))
        let settings = SidebarSettings(rules: [Rule(source: "Slack", title: "Alice", display: .blackout, intervalMinutes: 7)])
        try file.save(settings)
        #expect(try file.load() == settings)
        for value in [0, -1, 1441] {
            try directory.write("[[rules]]\nsource = 'Slack'\naction = 'high'\ndisplay = 'jiggle'\ninterval_minutes = \(value)\n", to: "config.toml")
            #expect(throws: (any Error).self) { try file.load() }
            #expect(Rule(source: "Slack", intervalMinutes: value).problem == .invalidInterval)
        }
    }

    @Test func panelTracksBlackoutDismissalAndScreenChanges() throws {
        var now = Date()
        var frame: CGRect? = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let controller = SidebarPanelController.forTesting(model: model, settings: settings, targetScreenFrame: { frame })
        let panel = controller.annoyancePanel.panel
        defer { controller.annoyancePanel.stop() }
        let notification = SidebarNotification(source: "Slack", title: "Alice", receivedAt: now)
        model.add(notification)
        #expect(!panel.isVisible)
        let timer = try #require(controller.annoyancePanel.timer)
        #expect(timer.fireDate == now + 300)
        now += 300
        timer.fire()
        #expect(panel.isVisible)
        #expect(controller.annoyancePanel.timer == nil)
        #expect(panel.frame == frame)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.backgroundColor == SidebarSettings.RGBColor.black.nsColor.withAlphaComponent(AnnoyancePanel.minimumBackdropOpacity))
        frame = CGRect(x: -1000, y: 0, width: 1000, height: 700)
        controller.annoyancePanel.refresh()
        #expect(panel.frame == frame)
        frame = nil
        controller.annoyancePanel.refresh()
        #expect(!panel.isVisible)
        frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        controller.annoyancePanel.refresh()
        #expect(panel.isVisible)
        let card = NotificationCard(notification: notification, model: model, isHovered: false, hover: { _ in })
        card.dismiss()
        #expect(!panel.isVisible)
        #expect(model.notifications.isEmpty)
    }

    /// The blackout shows the card at the sidebar's width, centered. AppKit hit tests and tracks the pointer by view
    /// frames and ignores SwiftUI's render transforms, so a scaled card would take clicks and hover only where it
    /// would sit unscaled.
    @Test func blackoutCardTakesClicksWhereItIsDrawn() throws {
        var now = Date()
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let controller = SidebarPanelController.forTesting(model: model, settings: settings, targetScreenFrame: { frame })
        let panel = controller.annoyancePanel.panel
        defer { controller.annoyancePanel.stop() }
        model.add(SidebarNotification(source: "Slack", title: "Alice", body: "Are you there?", receivedAt: now))
        now += 300
        try #require(controller.annoyancePanel.timer).fire()
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()

        let scrollViews = content.descendants(of: NSScrollView.self)
        try #require(scrollViews.count == 1)
        let card = try #require(scrollViews[0].documentView)
        let drawn = card.convert(card.bounds, to: nil)
        // The same card as in the sidebar: its list lays its cards out in a document as wide as the strip.
        let sidebarContent = try #require(controller.panel.contentView)
        sidebarContent.layoutSubtreeIfNeeded()
        let sidebarList = try #require(sidebarContent.descendants(of: NSScrollView.self).first?.documentView)
        let width = CGFloat(settings.settings.sidebar.width)
        #expect(sidebarList.frame.width == width)
        #expect(drawn.width == width)
        #expect(drawn.midX == frame.midX)
        // `NSView.hitTest(_:)` and tracking areas use frames: the card's own frame must span what is drawn, and no
        // view between it and the panel's content may draw through a layer transform.
        #expect(card.frame.width == width)
        var view = card
        while view !== content, let superview = view.superview {
            #expect(view.layer.map { CATransform3DIsIdentity($0.transform) } ?? true, "\(type(of: view)) draws through a transform")
            view = superview
        }
    }

    @Test func escapeDismissesTheBlackoutCardOnlyWhileItShows() throws {
        var now = Date()
        @MainActor final class Screen {
            var frame: CGRect? = CGRect(x: 0, y: 0, width: 1000, height: 800)
        }
        let screen = Screen()
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let escape = FakeEscapeKey()
        let controller = SidebarPanelController.forTesting(model: model, settings: settings, targetScreenFrame: { screen.frame }, escapeKey: escape)
        let panel = controller.annoyancePanel.panel
        defer { controller.annoyancePanel.stop() }
        let first = SidebarNotification(source: "Slack", title: "first", receivedAt: now)
        let second = SidebarNotification(source: "Slack", title: "second", receivedAt: now + 1)
        model.add(first)
        model.add(second)
        #expect(!escape.isRegistered)
        escape.press()
        #expect(model.notifications.count == 2)

        now += 300
        try #require(controller.annoyancePanel.timer).fire()
        #expect(panel.isVisible)
        #expect(escape.isRegistered)
        #expect(controller.annoyancePanel.escape.hint == "Press Esc to dismiss")
        // Refreshing while it shows keeps the one registration.
        controller.annoyancePanel.refresh()
        #expect(escape.registrations == 1)
        screen.frame = nil
        controller.annoyancePanel.refresh()
        #expect(!escape.isRegistered)
        screen.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        controller.annoyancePanel.refresh()
        #expect(escape.isRegistered)

        escape.press()
        #expect(model.notifications.map(\.id) == [second.id])
        #expect(!panel.isVisible)
        #expect(!escape.isRegistered)
        #expect(controller.annoyancePanel.escape.hint == nil)
        #expect(model.annoyance.active?.id == second.id)
    }

    @Test func escapeHeldByAnotherAppIsSaidAndTriedAgain() throws {
        var now = Date()
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let escape = FakeEscapeKey()
        escape.refuses = true
        let controller = SidebarPanelController.forTesting(
            model: model, settings: settings, targetScreenFrame: { CGRect(x: 0, y: 0, width: 1000, height: 800) }, escapeKey: escape
        )
        let blackout = controller.annoyancePanel
        defer { blackout.stop() }
        let card = SidebarNotification(source: "Slack", title: "Alice", receivedAt: now)
        model.add(card)
        now += 300
        try #require(blackout.timer).fire()
        #expect(blackout.panel.isVisible)
        #expect(blackout.escape.state == .refused)
        #expect(blackout.escape.hint == "Another app holds Esc")
        escape.press()
        #expect(model.notifications.map(\.id) == [card.id])

        // The other app let go of it.
        escape.refuses = false
        blackout.refresh()
        #expect(blackout.escape.state == .held)
        escape.press()
        #expect(model.notifications.isEmpty)
        #expect(blackout.escape.state == .released)
    }

    @Test func replyTypedOnTheBlackoutCardKeepsEscape() throws {
        var now = Date()
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let escape = FakeEscapeKey()
        let controller = SidebarPanelController.forTesting(
            model: model, settings: settings, targetScreenFrame: { CGRect(x: 0, y: 0, width: 1000, height: 800) }, escapeKey: escape
        )
        defer { controller.annoyancePanel.stop() }
        let card = SidebarNotification(source: "Slack", title: "Alice", receivedAt: now)
        let other = SidebarNotification(source: "Mail", title: "Bob", receivedAt: now)
        model.add(card)
        model.add(other)
        now += 300
        try #require(controller.annoyancePanel.timer).fire()
        #expect(escape.isRegistered)

        model.setComposing(true, on: other.id)
        #expect(escape.isRegistered)
        model.setComposing(true, on: card.id)
        #expect(!escape.isRegistered)
        #expect(controller.annoyancePanel.escape.hint == nil)
        escape.press()
        #expect(model.notifications.contains { $0.id == card.id })
        model.setComposing(false, on: card.id)
        #expect(escape.isRegistered)
        controller.annoyancePanel.stop()
        #expect(!escape.isRegistered)
    }

    @Test func blackoutBackdropFollowsTheSidebarBackground() throws {
        var now = Date()
        let directory = try TemporaryDirectory()
        let settings = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        settings.update { $0.background = .init(color: .init(red: 10, green: 20, blue: 30), opacity: 0.6) }
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(), rules: [Rule(source: "Slack", display: .blackout)], now: { now })
        let controller = SidebarPanelController.forTesting(model: model, settings: settings, targetScreenFrame: { CGRect(x: 0, y: 0, width: 1000, height: 800) })
        let panel = controller.annoyancePanel.panel
        defer { controller.annoyancePanel.stop() }
        model.add(SidebarNotification(source: "Slack", title: "Alice", receivedAt: now))
        now += 300
        try #require(controller.annoyancePanel.timer).fire()
        #expect(!panel.isOpaque)
        #expect(panel.backgroundColor == SidebarSettings.RGBColor(red: 10, green: 20, blue: 30).nsColor.withAlphaComponent(0.6))
        settings.preview(background: .init(color: .black, opacity: 0))
        // Fully transparent pixels let clicks through to the windows below, so the backdrop keeps a trace.
        #expect(panel.backgroundColor == SidebarSettings.RGBColor.black.nsColor.withAlphaComponent(AnnoyancePanel.minimumBackdropOpacity))
    }

    @Test func blackoutSurvivesCapacityEviction() {
        var now = Date()
        let model = SidebarModel(performer: RecordingPerformer(), store: InMemoryStore(),
                                 rules: [Rule(source: "Slack", action: .severity(.low), display: .blackout)], now: { now })
        let first = SidebarNotification(source: "Slack", title: "first", receivedAt: now)
        model.add(first)
        now += 300
        model.advanceAnnoyance()
        for index in 0...model.history.maxCount {
            model.add(SidebarNotification(source: "other", title: "\(index)", severity: .critical, receivedAt: now))
        }
        #expect(model.notifications.count == model.history.maxCount)
        #expect(model.notifications.contains { $0.id == first.id })
        #expect(model.annoyance.blocking)
    }

    @Test func editorChangesDisplayAndIntervalWithoutChangingPatterns() throws {
        let directory = try TemporaryDirectory()
        let store = SettingsStore(file: SettingsFile(url: directory.url.appendingPathComponent("config.toml")))
        store.update { $0.rules = [Rule(source: "Slack", title: "Alice")] }
        let editor = SettingsEditor(store: store)
        let pane = RulesPane(editor: editor, history: { [] }, close: {}, selection: 0)
        pane.display.wrappedValue = .blackout
        pane.intervalMinutes.wrappedValue = 8
        #expect(editor.draft.rules[0].display == .blackout)
        #expect(editor.draft.rules[0].intervalMinutes == 8)
        #expect(editor.draft.rules[0].title == "Alice")
        #expect(RulesPane.summary(of: editor.draft.rules[0]).contains("Block screen (8 min)"))
    }
}

private extension NSView {
    /// Every view of `type` under this one, depth first.
    func descendants<Descendant: NSView>(of type: Descendant.Type) -> [Descendant] {
        subviews.flatMap { subview -> [Descendant] in
            let own: [Descendant] = (subview as? Descendant).map { [$0] } ?? []
            return own + subview.descendants(of: type)
        }
    }
}
