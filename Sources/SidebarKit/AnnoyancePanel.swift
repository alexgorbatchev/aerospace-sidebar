import AppKit
import os
import SwiftUI

/// Whether Escape dismisses the blackout card, for the hint under it.
@MainActor
@Observable
final class BlackoutEscape {
    enum State: Equatable {
        /// Not held: no blackout shows, or a reply typed on the card has Escape.
        case released
        /// Held for the blackout card.
        case held
        /// The system refused it, as when another app holds it.
        case refused
    }

    fileprivate(set) var state = State.released

    /// What the blackout says about Escape under the card.
    var hint: String? {
        switch state {
        case .released: nil
        case .held: "Press Esc to dismiss"
        case .refused: "Another app holds Esc"
        }
    }
}

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
    private let escapeKey: EscapeKey
    private(set) var timer: Timer?
    /// Holds Escape while the blackout shows, so the card can be dismissed from the keyboard whatever happens to
    /// the panel's own mouse and keyboard handling. Released while a reply is typed on the card, whose field
    /// closes on Escape.
    private var escapeRegistration: AnyObject?
    let escape = BlackoutEscape()
    private let logger = Logger(category: "annoyance")

    init(model: SidebarModel, settings: SettingsStore, panelType: SidebarPanel.Type,
         screenFrame: @escaping @MainActor () -> CGRect?, escapeKey: EscapeKey) {
        self.model = model
        self.screenFrame = screenFrame
        self.escapeKey = escapeKey
        panel = panelType.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = SidebarHostingView(rootView: AnnoyanceContent(model: model, settings: settings, escape: escape)
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
            holdEscape(!model.isComposingOnAnnoyance)
        } else {
            panel.orderOut(nil)
            holdEscape(false)
        }
    }

    /// Registers Escape for the blackout card, or releases it. A refused registration is tried again at the next
    /// refresh, since the app holding the key may let it go, and logged once until the key is released.
    private func holdEscape(_ hold: Bool) {
        guard hold else {
            escapeRegistration = nil
            escape.state = .released
            return
        }
        guard escapeRegistration == nil else { return }
        escapeRegistration = escapeKey.register { [weak self] in self?.dismissOnEscape() }
        if escapeRegistration != nil {
            escape.state = .held
        } else if escape.state != .refused {
            escape.state = .refused
            logger.error("Escape is held by another app, so only the blackout card's dismiss button dismisses it")
        }
    }

    /// Dismisses the card the blackout shows, like its dismiss button.
    private func dismissOnEscape() {
        guard model.annoyance.blocking, let id = model.annoyance.active?.id else { return }
        model.dismiss(id)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        holdEscape(false)
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
    let escape: BlackoutEscape
    @State private var hovered = false
    @Environment(\.typography) private var typography

    var body: some View {
        GeometryReader { geometry in
            if let notification = model.notifications.first(where: { $0.id == model.annoyance.active?.id }), model.annoyance.blocking {
                ScrollView {
                    VStack(spacing: 0) {
                        NotificationCard(notification: notification, model: model, isHovered: hovered, hover: { hovered = $0 })
                        if let hint = escape.hint {
                            Text(hint)
                                .font(typography.font(.callout))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, Self.margin)
                        }
                    }
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
