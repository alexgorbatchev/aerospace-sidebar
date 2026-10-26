import SidebarProtocol
import SwiftUI

/// Root content of the sidebar panel.
struct SidebarView: View {
    let model: SidebarModel
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                if !model.notifications.isEmpty {
                    Button("Clear All", action: model.clear)
                        .buttonStyle(.link)
                }
            }
            if let message = statusMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.interception == .needsAccessibility {
                        Button("Set Up…", action: openSettings)
                    }
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.notifications) { notification in
                        NotificationCard(
                            notification: notification,
                            activate: { model.activate(notification.id) },
                            dismiss: { model.dismiss(notification.id) }
                        )
                    }
                }
            }
            .overlay {
                if model.notifications.isEmpty {
                    Text("No notifications")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("Quit Sidebar", action: quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusMessage: String? {
        switch model.interception {
        case .starting, .active: nil
        case .disabled: "macOS notifications are left to macOS (see Settings)."
        case .needsAccessibility: "Grant Accessibility access to show macOS notifications here."
        case .notificationCenterUnavailable: "macOS notifications cannot be read right now."
        }
    }
}

struct NotificationCard: View {
    let notification: SidebarNotification
    let activate: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: activate) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if let symbol = severitySymbol {
                            Image(systemName: symbol)
                                .foregroundStyle(accent ?? .secondary)
                                .accessibilityLabel(notification.severity.rawValue)
                        }
                        if let symbol = actionSymbol {
                            Image(systemName: symbol)
                        }
                        Text(notification.source.isEmpty ? "Notification" : notification.source)
                        Text(notification.receivedAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !notification.title.isEmpty {
                        Text(notification.title).font(.body.bold())
                    }
                    if !notification.subtitle.isEmpty {
                        Text(notification.subtitle).font(.callout)
                    }
                    if !notification.body.isEmpty {
                        Text(notification.body).font(.callout).lineLimit(8)
                    }
                    if notification.shownByMacOS {
                        Text("Shown by macOS for its buttons")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if let accent {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(accent, lineWidth: notification.severity == .critical ? 2 : 1)
                    }
                }
                .opacity(notification.severity == .low ? 0.6 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(notification.clickDescription)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(8)
            .accessibilityLabel("Dismiss")
        }
    }

    private var accent: Color? {
        switch notification.severity {
        case .low, .normal: nil
        case .high: .orange
        case .critical: .red
        }
    }

    private var background: AnyShapeStyle {
        switch notification.severity {
        case .critical: AnyShapeStyle(Color.red.opacity(0.25))
        case .high: AnyShapeStyle(Color.orange.opacity(0.15))
        case .low, .normal: AnyShapeStyle(.quaternary)
        }
    }

    private var severitySymbol: String? {
        switch notification.severity {
        case .low, .normal: nil
        case .high: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    private var actionSymbol: String? {
        switch notification.action {
        case nil: nil
        case .open: "link"
        case .run: "terminal"
        case .activateApp: nil
        }
    }

}
