import AppKit
import SwiftUI

/// Uses the same nonactivating panel and card as the sidebar, covering its main display until answered.
@MainActor
final class AnnoyancePanel {
    /// How much larger than in the sidebar the card is laid out. The card is laid out at this size, never scaled:
    /// AppKit hit tests and tracks the pointer by view frames, which a SwiftUI scale leaves at their unscaled size,
    /// so a scaled card's controls would take no clicks where they are drawn.
    static let magnification: CGFloat = 1.5
    /// The backdrop's least opacity: WindowServer passes clicks through fully transparent pixels to the windows
    /// below, which the backdrop has to block.
    static let minimumBackdropOpacity = 0.01
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
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = SidebarHostingView(rootView: AnnoyanceContent(model: model, settings: settings)
            .environment(\.requestKeyboard, { [weak panel] in panel?.takeKeyboard() }))
        model.annoyanceChanged = { [weak self] in self?.refresh() }
        settings.observeBackground { [weak self] in self?.showBackdrop($0) }
        showBackdrop(settings.background)
        refresh()
    }

    /// Fills the backdrop like the sidebar's strip, in `[background]`'s color and opacity.
    private func showBackdrop(_ background: SidebarSettings.Background) {
        panel.backgroundColor = background.color.nsColor.withAlphaComponent(max(background.opacity, Self.minimumBackdropOpacity))
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
    /// Space around the card, inside the scroll view.
    static let margin: CGFloat = 16

    let model: SidebarModel
    let settings: SettingsStore
    @State private var hovered = false

    var body: some View {
        GeometryReader { geometry in
            if let notification = model.notifications.first(where: { $0.id == model.annoyance.active?.id }), model.annoyance.blocking {
                ScrollView {
                    NotificationCard(notification: notification, model: model, isHovered: hovered, hover: { hovered = $0 })
                        .padding(Self.margin)
                }
                .defaultScrollAnchor(.center)
                .frame(width: min(CGFloat(settings.settings.sidebar.width) * AnnoyancePanel.magnification, geometry.size.width),
                       height: geometry.size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .typography(settings, magnification: AnnoyancePanel.magnification)
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
