import SidebarProtocol
import SwiftUI

/// Root content of the sidebar panel.
struct SidebarView: View {
    let model: SidebarModel
    let openSettings: () -> Void
    let quit: () -> Void

    static let margin: CGFloat = 16

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollMetrics = ScrollMetrics()
    @State private var isScrolling = false

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
            .padding(.horizontal, Self.margin)
            if let message = statusMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.interception == .needsAccessibility {
                        Button("Set Up…", action: openSettings)
                    }
                }
                .padding(.horizontal, Self.margin)
            }
            // The list spans the full width so the scroll indicator sits in the trailing margin.
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
                .padding(.horizontal, Self.margin)
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { scrollMetrics = $1 }
            .onScrollPhaseChange { isScrolling = $1.isScrolling }
            .overlay(alignment: .trailing) {
                if scrollMetrics.isScrollable {
                    ScrollIndicator(metrics: scrollMetrics, isScrolling: isScrolling) { scrollPosition.scrollTo(y: $0) }
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
            .padding(.horizontal, Self.margin)
        }
        .padding(.vertical, Self.margin)
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

    static let cornerRadius: CGFloat = 10
    /// How far each layer under a stacked card shows, and how much narrower it is per side.
    static let stackLayerHeight: CGFloat = 5
    static let stackLayerInset: CGFloat = 8
    static let maxStackLayers = 2

    var body: some View {
        VStack(spacing: 0) {
            card
            ForEach(1..<stackLayers + 1, id: \.self) { layer in
                UnevenRoundedRectangle(bottomLeadingRadius: Self.stackLayerHeight, bottomTrailingRadius: Self.stackLayerHeight)
                    .fill(background)
                    .opacity(0.8 - 0.25 * Double(layer))
                    .frame(height: Self.stackLayerHeight)
                    .padding(.horizontal, Self.stackLayerInset * CGFloat(layer))
            }
        }
    }

    /// Layers drawn under the card for notifications received more than once.
    private var stackLayers: Int { min(notification.occurrences - 1, Self.maxStackLayers) }

    private var card: some View {
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
                        if notification.occurrences > 1 {
                            Text("×\(notification.occurrences)")
                                .monospacedDigit()
                                .padding(.horizontal, 5)
                                .background(.quaternary, in: Capsule())
                                .accessibilityLabel("Received \(notification.occurrences) times")
                        }
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
                .background(background, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
                .overlay {
                    if let accent {
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .strokeBorder(accent, lineWidth: notification.severity == .critical ? 2 : 1)
                    }
                }
                .opacity(notification.severity == .low ? 0.6 : 1)
                .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
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
