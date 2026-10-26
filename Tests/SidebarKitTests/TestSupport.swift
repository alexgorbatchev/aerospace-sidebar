import AppKit
import ApplicationServices
import Foundation
@testable import SidebarKit

/// In-memory accessibility element.
@MainActor
final class FakeElement: AccessibilityElement {
    var attributes: [String: String]
    var childElements: [FakeElement]
    var actions: [String]
    var actionSucceeds = true
    var performed: [String] = []
    var position: CGPoint?
    var moves: [CGPoint] = []

    init(
        _ attributes: [String: String] = [:],
        children: [FakeElement] = [],
        actions: [String] = [],
        position: CGPoint? = nil
    ) {
        self.attributes = attributes
        self.childElements = children
        self.actions = actions
        self.position = position
    }

    func string(_ attribute: String) -> String? { attributes[attribute] }
    var children: [any AccessibilityElement] { childElements }
    var actionNames: [String] { actions }

    func perform(_ action: String) -> Bool {
        performed.append(action)
        return actionSucceeds
    }

    func setPosition(_ point: CGPoint) -> Bool {
        position = point
        moves.append(point)
        return true
    }

    /// A banner as NotificationCenter exposes it on macOS 26.
    static func banner(id: String? = "banner-1", app: String = "Mail", title: String = "Subject", body: String = "Text") -> FakeElement {
        var attributes = [kAXSubroleAttribute: "AXNotificationCenterBanner", kAXDescriptionAttribute: "\(app), \(title), \(body)"]
        attributes[kAXIdentifierAttribute] = id
        return FakeElement(attributes, children: [
            FakeElement([kAXValueAttribute: title, kAXIdentifierAttribute: "title"]),
            FakeElement([kAXValueAttribute: body, kAXIdentifierAttribute: "body"]),
        ], actions: ["AXPress", "Name:Close\nTarget:0x0\nSelector:(null)"])
    }

    static func window(_ banners: FakeElement..., position: CGPoint = .zero) -> FakeElement {
        FakeElement([kAXRoleAttribute: kAXWindowRole], children: [FakeElement(children: banners)], position: position)
    }
}

@MainActor
final class RecordingPerformer: NotificationActionPerforming {
    var actions: [SidebarNotification.ClickAction] = []

    func perform(_ action: SidebarNotification.ClickAction) {
        actions.append(action)
    }
}

@MainActor
final class FakePlatform: AccessibilityPlatform {
    var trusted = true
    var promptRequests: [Bool] = []
    var pid: pid_t? = 42
    var windowsByPID: [pid_t: [FakeElement]] = [:]
    var observeSucceeds = true
    var observedPIDs: [pid_t] = []
    var handler: (@MainActor (any AccessibilityElement) -> Void)?

    func isTrusted(prompt: Bool) -> Bool {
        promptRequests.append(prompt)
        return trusted
    }

    func notificationCenterPID() -> pid_t? { pid }

    func windows(ofProcess pid: pid_t) -> [any AccessibilityElement] { windowsByPID[pid] ?? [] }

    func observe(process pid: pid_t, handler: @escaping @MainActor (any AccessibilityElement) -> Void) -> AnyObject? {
        observedPIDs.append(pid)
        self.handler = handler
        return observeSucceeds ? NSObject() : nil
    }
}

@MainActor
final class InMemoryStore: NotificationStore {
    var stored: [SidebarNotification]
    var saves = 0

    init(_ stored: [SidebarNotification] = []) {
        self.stored = stored
    }

    func load() -> [SidebarNotification] { stored }

    func save(_ notifications: [SidebarNotification]) {
        stored = notifications
        saves += 1
    }
}
