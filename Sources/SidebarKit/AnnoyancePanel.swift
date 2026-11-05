import AppKit
import SwiftUI

/// Uses the same nonactivating panel and card as the sidebar, covering its main display until answered.
@MainActor
final class AnnoyancePanel {
    let panel: SidebarPanel
    private let model: SidebarModel
    private let screenFrame: @MainActor () -> CGRect?
    private(set) var timer: Timer?

    init(model: SidebarModel, settings: SettingsStore, panelType: SidebarPanel.Type,
         screenFrame: @escaping @MainActor () -> CGRect?) {
        self.model = model
        self.screenFrame = screenFrame
        panel = panelType.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = SidebarHostingView(rootView: AnnoyanceContent(model: model, settings: settings)
            .environment(\.requestKeyboard, { [weak panel] in panel?.takeKeyboard() }))
        model.annoyanceChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        timer?.invalidate()
        timer = nil
        if let deadline = model.annoyance.deadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.advanceAnnoyance() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if model.annoyance.blocking, let frame = screenFrame() {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    isolated deinit {
        timer?.invalidate()
        panel.orderOut(nil)
    }
}

struct AnnoyanceContent: View {
    let model: SidebarModel
    let settings: SettingsStore
    @State private var hovered = false

    var body: some View {
        GeometryReader { geometry in
            if let notification = model.notifications.first(where: { $0.id == model.annoyance.active?.id }), model.annoyance.blocking {
                ScrollView {
                    NotificationCard(notification: notification, model: model, isHovered: hovered, hover: { hovered = $0 })
                        .padding(16)
                }
                .defaultScrollAnchor(.center)
                .frame(width: min(CGFloat(settings.settings.sidebar.width), geometry.size.width / 1.5), height: geometry.size.height / 1.5)
                .scaleEffect(1.5)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .typography(settings)
        .sidebarTooltips()
    }
}

extension NotificationCard {
    init(notification: SidebarNotification, model: SidebarModel, isHovered: Bool, hover: @escaping (Bool) -> Void) {
        self.init(
            notification: notification,
            choices: model.cardChoices(of: notification),
            isAnswering: model.answering.contains(notification.id),
            clickDescription: model.clickDescription(of: notification),
            isHovered: isHovered, hover: hover,
            activate: { model.activate(notification.id) },
            choose: { model.choose($0, for: notification.id) },
            reply: { model.reply($0, text: $1, for: notification.id) },
            openLink: { model.openLink($0) },
            dismiss: { model.dismiss(notification.id) },
            composingChanged: { model.setComposing($0, on: notification.id) },
            allowAppNotifications: model.appNotificationsAreOff(for: notification) ? { model.allowAppNotifications(for: notification.id) } : nil,
            isAllowingAppNotifications: model.allowingAppNotifications != nil,
            hasLostChoices: model.hasLostChoices(notification)
        )
    }
}
