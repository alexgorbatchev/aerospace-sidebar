import ApplicationServices
import CoreGraphics
import Foundation

/// Hides native notification banners and reports each one's content once.
///
/// Notifications that need interaction (`NotificationBanners.needsInteraction`) stay visible as
/// macOS presents them and are reported with `shownByMacOS`.
///
/// On macOS 26 NotificationCenter ignores position changes on the banner element, and its close
/// action only takes effect after the slide-in animation (about 1.3 s). Moving the hosting window
/// off-screen hides the banner immediately; NotificationCenter discards that window once the banner
/// is closed. Windows left off-screen are moved back by `restore(_:)`.
@MainActor
public final class SystemNotificationInterceptor {
    static let offScreen = CGPoint(x: -5000, y: -5000)
    static let maxRememberedBanners = 500
    static let duplicateWindow: TimeInterval = 10

    private let onNotification: @MainActor (SidebarNotification) -> Void
    private let leavesToMacOS: @MainActor (String) -> Bool
    private let now: () -> Date
    private var seenIdentifiers: [String] = []
    private var recentContent: [(content: BannerContent, at: Date)] = []

    /// - Parameter leavesToMacOS: Whether an app's notifications stay native, by app name.
    public init(
        now: @escaping () -> Date = Date.init,
        leavesToMacOS: @escaping @MainActor (String) -> Bool = { _ in false },
        onNotification: @escaping @MainActor (SidebarNotification) -> Void
    ) {
        self.now = now
        self.leavesToMacOS = leavesToMacOS
        self.onNotification = onNotification
    }

    /// Hides and closes the plain banners in a NotificationCenter window, reporting new ones. A window
    /// holding an interactive notification, or one from an app left to macOS, stays on-screen and is
    /// moved back if it was hidden.
    public func process(window: any AccessibilityElement) {
        let banners = NotificationBanners.find(in: window).map { banner in
            let content = NotificationBanners.content(of: banner)
            return (banner, content, NotificationBanners.needsInteraction(banner) || leavesToMacOS(content.appName))
        }
        guard !banners.isEmpty else { return }
        if banners.contains(where: \.2) {
            restore([window])
        } else {
            window.setPosition(Self.offScreen)
        }
        for (banner, content, shownByMacOS) in banners {
            let identifier = banner.string(kAXIdentifierAttribute)
            if !shownByMacOS {
                NotificationBanners.dismiss(banner)
            }
            guard isNew(identifier: identifier, content: content) else { continue }
            onNotification(SidebarNotification(
                source: content.appName,
                title: content.title,
                subtitle: content.subtitle,
                body: content.body,
                action: content.appName.isEmpty ? nil : .activateApp(name: content.appName),
                shownByMacOS: shownByMacOS,
                receivedAt: now()
            ))
        }
    }

    /// Moves NotificationCenter windows that an earlier hide left off-screen back to the origin.
    public func restore(_ windows: [any AccessibilityElement]) {
        for window in windows {
            if let position = window.position, position.x <= -1000 || position.y <= -1000 {
                window.setPosition(.zero)
            }
        }
    }

    /// NotificationCenter reports the same banner several times while it animates. Banners are
    /// remembered by `AXIdentifier`, and identical content is ignored for `duplicateWindow` seconds.
    private func isNew(identifier: String?, content: BannerContent) -> Bool {
        guard !content.isEmpty else { return false }
        if let identifier, !identifier.isEmpty {
            if seenIdentifiers.contains(identifier) { return false }
            seenIdentifiers.append(identifier)
            if seenIdentifiers.count > Self.maxRememberedBanners {
                seenIdentifiers.removeFirst()
            }
        }
        let time = now()
        recentContent.removeAll { time.timeIntervalSince($0.at) > Self.duplicateWindow }
        if recentContent.contains(where: { $0.content == content }) { return false }
        recentContent.append((content, time))
        return true
    }
}
