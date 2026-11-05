import Foundation

/// One card owns the cycle. Repeated arrivals on that card preserve its place and deadline.
struct NotificationAnnoyance: Equatable {
    struct Entry: Equatable {
        let id: SidebarNotification.ID
        let receivedAt: Date
        let display: SidebarSettings.Rule.Display
        let interval: TimeInterval
    }

    private(set) var queue: [Entry] = []
    private(set) var deadline: Date?
    private(set) var blocking = false
    private(set) var jiggle = 0
    var active: Entry? { queue.first }

    mutating func reconcile(_ notifications: [SidebarNotification], rules: NotificationRules, now: Date) {
        let previous = active
        let entries = notifications.compactMap { notification -> Entry? in
            guard let rule = rules.firstMatch(for: notification), rule.action != .hide, rule.display != .sidebar else { return nil }
            let age = queue.first { $0.id == notification.id }?.receivedAt ?? notification.receivedAt
            return Entry(id: notification.id, receivedAt: age, display: rule.display, interval: Double(rule.intervalMinutes) * 60)
        }.sorted {
            if $0.receivedAt == $1.receivedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.receivedAt < $1.receivedAt
        }
        queue = entries
        // Even a late database arrival older than the owner cannot interrupt its cycle.
        if let previous, let index = queue.firstIndex(where: { $0.id == previous.id }) {
            queue.insert(queue.remove(at: index), at: 0)
        }
        if active != previous {
            blocking = false
            deadline = active.map { now.addingTimeInterval($0.interval) }
        }
    }

    mutating func advance(at now: Date) {
        guard let active, let deadline, now >= deadline else { return }
        switch active.display {
        case .blackout:
            blocking = true
            self.deadline = nil
        case .jiggle:
            jiggle += 1
            self.deadline = now.addingTimeInterval(active.interval)
        case .sidebar: break
        }
    }
}
