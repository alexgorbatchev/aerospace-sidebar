import AppKit
import ApplicationServices
import Foundation
import PermissionFlow
@testable import SidebarKit

/// In-memory accessibility element.
@MainActor
final class FakeElement: AccessibilityElement {
    var attributes: [String: String]
    var flags: [String: Bool] = [:]
    var childElements: [FakeElement]
    var actions: [String]
    var actionSucceeds = true
    /// Runs when an action is performed, before its result returns, like Reply opening a text field.
    var onPerform: ((FakeElement) -> Void)?
    var performed: [String] = []
    var position: CGPoint?
    var moves: [CGPoint] = []
    /// Whether `setPosition` changes `position`; NotificationCenter may keep a window where it is.
    var keepsMoves = true

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
    func bool(_ attribute: String) -> Bool? { flags[attribute] }
    var children: [any AccessibilityElement] { childElements }
    var actionNames: [String] { actions }

    func perform(_ action: String) -> Bool {
        performed.append(action)
        onPerform?(self)
        return actionSucceeds
    }

    func setPosition(_ point: CGPoint) -> Bool {
        if keepsMoves {
            position = point
        }
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

    /// A collapsed stack of alerts: only the newest alert's text, and a description ending in ", stacked".
    static func alertStack(id: String = "stack-1", app: String = "Self Service", title: String = "Slack", body: String = "Update complete.") -> FakeElement {
        let stack = banner(id: id, app: app, title: title, body: body)
        stack.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlertStack"
        stack.attributes[kAXDescriptionAttribute] = "\(app), \(title), \(body), stacked"
        stack.actions = ["AXPress", "Name:Show Details\nTarget:0x0\nSelector:(null)", "Name:Clear All\nTarget:0x0\nSelector:(null)"]
        return stack
    }

    /// An alert whose choices are named actions, like macOS's "Privacy & Security" alert with Allow….
    static func alert(id: String = "alert-1", app: String = "Calendar", title: String = "Standup", choices: [String] = ["Allow…"]) -> FakeElement {
        let alert = banner(id: id, app: app, title: title)
        alert.attributes[kAXSubroleAttribute] = "AXNotificationCenterAlert"
        alert.actions = ["AXPress", "Show Details"] + choices + ["Close"]
        alert.actions = alert.actions.map { $0 == "AXPress" ? $0 : "Name:\($0)\nTarget:0x0\nSelector:(null)" }
        return alert
    }

    /// NotificationCenter's "Notification Center" window as macOS 26 lays it out.
    static func window(_ banners: FakeElement..., position: CGPoint = .zero) -> FakeElement {
        FakeElement(
            [kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: "AXSystemDialog", kAXTitleAttribute: "Notification Center"],
            children: [FakeElement([kAXIdentifierAttribute: "AXNotificationListItems"], children: banners)],
            position: position
        )
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
final class RecordingAlerts: NativeAlertControlling {
    var performed: [String] = []
    var succeeds = true
    var releases = 0

    func perform(_ action: AlertAction, onAlert identifier: String) -> Bool {
        switch action {
        case .open: performed.append("open \(identifier)")
        case .choice(let name): performed.append("\(name) \(identifier)")
        }
        return succeeds
    }

    func alertsReleased() {
        releases += 1
    }
}

@MainActor
final class FakePlatform: AccessibilityPlatform {
    var trusted = true
    var promptRequests: [Bool] = []
    var pid: pid_t? = 42
    var windowsByPID: [pid_t: [FakeElement]] = [:]
    var applicationsByPID: [pid_t: FakeElement] = [:]
    var observeSucceeds = true
    var observedPIDs: [pid_t] = []
    var handler: (@MainActor (any AccessibilityElement) -> Void)?
    var exitHandlers: [pid_t: @MainActor () -> Void] = [:]

    func isTrusted(prompt: Bool) -> Bool {
        promptRequests.append(prompt)
        return trusted
    }

    func notificationCenterPID() -> pid_t? { pid }

    func application(ofProcess pid: pid_t) -> (any AccessibilityElement)? { applicationsByPID[pid] }

    func windows(ofProcess pid: pid_t) -> [any AccessibilityElement] { windowsByPID[pid] ?? [] }

    func observe(process pid: pid_t, handler: @escaping @MainActor (any AccessibilityElement) -> Void) -> AnyObject? {
        observedPIDs.append(pid)
        self.handler = handler
        return observeSucceeds ? NSObject() : nil
    }

    func watchExit(of pid: pid_t, handler: @escaping @MainActor () -> Void) -> AnyObject? {
        exitHandlers[pid] = handler
        return NSObject()
    }
}

/// A value a test changes after handing a closure that reads it to the code under test. A captured local
/// `var` changed later would be shared mutable state between the test and that `@MainActor` closure.
@MainActor
final class Mutable<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
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

@MainActor
final class FakeLoginItems: LoginItemService {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var error: (any Error)?
    var openedSettings = 0

    init(status: LoginItemStatus = .disabled) {
        self.status = status
    }

    func register() throws {
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        if let error { throw error }
        status = .disabled
    }

    func openSystemSettings() {
        openedSettings += 1
    }
}

final class FakeAeroSpaceCLI: AeroSpaceCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    let results: [String: CommandResult]

    /// Results keyed by the first argument after `reload-config`, e.g. `--dry-run`; default success.
    init(results: [String: CommandResult] = [:]) {
        self.results = results
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String]) async -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        return results[arguments.dropFirst().first ?? ""] ?? CommandResult(status: 0, output: "")
    }
}

/// Holds every `aerospace` call until `resumeAll()`, so a test can act while an update is in flight.
final class SuspendingAeroSpaceCLI: AeroSpaceCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var callObservers: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func run(_ arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                callObservers.forEach { $0.resume() }
                callObservers = []
                if !isReleased { held.append(continuation) }
                return isReleased
            }
            if resumeNow { continuation.resume() }
        }
        return CommandResult(status: 0, output: "")
    }

    /// Returns once a call is being held.
    func waitForCall() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if held.isEmpty { callObservers.append(continuation) } else { continuation.resume() }
            }
        }
    }

    /// Lets held and later calls finish.
    func resumeAll() {
        let released = lock.withLock {
            isReleased = true
            defer { held = [] }
            return held
        }
        released.forEach { $0.resume() }
    }
}

extension AeroSpaceSetup {
    /// Reports AeroSpace as running unless told otherwise, so tests take the same path on machines with
    /// and without AeroSpace.
    static func forTesting(
        home: URL,
        environment: [String: String],
        cli: any AeroSpaceCommandRunning,
        isAeroSpaceRunning: Bool = true
    ) -> AeroSpaceSetup {
        AeroSpaceSetup(home: home, environment: environment, cli: cli, isAeroSpaceRunning: { isAeroSpaceRunning })
    }
}

/// Permissions whose state a test sets; `authorize` and `reset` record the pane instead of opening System
/// Settings or running `tccutil`, and `reset` revokes it.
@MainActor
final class FakePermissions: PermissionGuiding {
    var states: [PermissionFlowPane: PermissionAuthorizationState] = [:]
    var authorized: [PermissionFlowPane] = []
    var resets: [PermissionFlowPane] = []
    var resetResult = CommandResult(status: 0, output: "")

    func state(of pane: PermissionFlowPane) -> PermissionAuthorizationState { states[pane] ?? .notGranted }

    func authorize(_ pane: PermissionFlowPane) {
        authorized.append(pane)
    }

    func reset(_ pane: PermissionFlowPane) async -> CommandResult {
        resets.append(pane)
        if resetResult.status == 0 {
            states[pane] = nil
        }
        return resetResult
    }
}

extension OnboardingModel {
    static func fake() -> OnboardingModel {
        OnboardingModel(permissions: FakePermissions(), loginItems: FakeLoginItems())
    }
}

extension AeroSpaceSync {
    /// Syncs `store`'s sidebar with a config under `home`, never the real AeroSpace config.
    static func fake(store: SettingsStore, home: URL, cli: any AeroSpaceCommandRunning = FakeAeroSpaceCLI()) -> AeroSpaceSync {
        AeroSpaceSync(
            setup: .forTesting(home: home, environment: [:], cli: cli),
            sidebar: { store.settings.sidebar },
            copy: { _ in }
        )
    }
}
