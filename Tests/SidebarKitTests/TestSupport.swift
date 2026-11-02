import AppKit
import ApplicationServices
import Foundation
import PermissionFlow
@testable import SidebarKit
import SidebarProtocol

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
    /// Whether `setValue` changes `kAXValueAttribute`.
    var acceptsValues = true

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

    func setValue(_ text: String) -> Bool {
        guard acceptsValues else { return false }
        attributes[kAXValueAttribute] = text
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

    /// A stack in the history panel as macOS 26.6 shows one, carrying its newest entry's identifier: a banner stack
    /// whose texts are the summary macOS wrote for it, titled with the app's name, described as "Stacked summary: ",
    /// the app and a longer summary than the texts hold.
    static func historyStack(id: String, app: String, summary: String = "Invitations and replies") -> FakeElement {
        let stack = banner(id: id, app: app, title: app, body: summary)
        stack.attributes[kAXSubroleAttribute] = "AXNotificationCenterBannerStack"
        stack.attributes[kAXDescriptionAttribute] = "Stacked summary: \(app), \(app), \(summary) from 3 people"
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

    /// A banner whose app declared a choice that asks for text, as NotificationCenter shows it on macOS 26.6.
    /// Performing the choice reports failure but opens a text area and an action named `send` (Show Details
    /// becomes Hide Details), Hide Details closes them again, and the send action delivers the text, kept as
    /// the banner's `sent` attribute, and removes the banner. Every action reports failure, as Reply does.
    static func replyBanner(id: String = "reply-1", app: String = "Notif Probe", choice: String = "Reply", send: String = "Send") -> FakeElement {
        func named(_ name: String) -> String { "Name:\(name)\nTarget:0x0\nSelector:(null)" }
        let banner = banner(id: id, app: app, title: "Question", body: "Answer me")
        let texts = banner.childElements
        let closed = ["AXPress", named("Show Details"), named(choice), named("Close")]
        let field = FakeElement([kAXRoleAttribute: kAXTextAreaRole])
        banner.actions = closed
        banner.actionSucceeds = false
        banner.onPerform = { banner in
            switch banner.performed.last {
            case named(choice):
                banner.actions = ["AXPress", named("Hide Details"), named(send), named("Close")]
                banner.childElements = texts + [
                    FakeElement([kAXRoleAttribute: kAXMenuButtonRole, kAXDescriptionAttribute: "More Actions…"]),
                    FakeElement([kAXRoleAttribute: kAXScrollAreaRole], children: [field]),
                    FakeElement([kAXRoleAttribute: kAXButtonRole, kAXTitleAttribute: send]),
                ]
            case named("Hide Details"):
                banner.actions = closed
                banner.childElements = texts
            case named(send):
                banner.attributes["sent"] = field.string(kAXValueAttribute)
                banner.actions = []
            default: break
            }
        }
        return banner
    }

    /// NotificationCenter's "Notification Center" window as macOS 26 lays it out.
    static func window(_ banners: FakeElement..., position: CGPoint = .zero) -> FakeElement {
        FakeElement(
            [kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: "AXSystemDialog", kAXTitleAttribute: "Notification Center"],
            children: [FakeElement([kAXIdentifierAttribute: "AXNotificationListItems"], children: banners)],
            position: position
        )
    }

    /// Another window of NotificationCenter's, such as one of the desktop widgets, which may sit on another
    /// display.
    static func widgetWindow(position: CGPoint) -> FakeElement {
        FakeElement([kAXRoleAttribute: kAXWindowRole, kAXSubroleAttribute: kAXStandardWindowSubrole], position: position)
    }
}

@MainActor
final class RecordingPerformer: NotificationActionPerforming {
    var actions: [SidebarNotification.ClickAction] = []
    /// The bundle identifier passed with each of `actions`.
    var bundleIdentifiers: [String?] = []

    /// The pushed choices' commands run, with their directories and added environments.
    var runs: [Run] = []

    struct Run: Equatable {
        let command: String
        let workingDirectory: String
        let environment: [String: String]
    }

    func perform(_ action: SidebarNotification.ClickAction, bundleIdentifier: String?) {
        actions.append(action)
        bundleIdentifiers.append(bundleIdentifier)
    }

    func run(_ command: String, in workingDirectory: String, environment: [String: String]) {
        runs.append(Run(command: command, workingDirectory: workingDirectory, environment: environment))
    }
}

/// Stands in for the client of an ask; `hangUp()` acts as if it stopped waiting.
final class RecordingAsker: NotificationAsking, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AskAnswer] = []
    private var hangUpHandler: (@MainActor @Sendable () -> Void)?

    var answers: [AskAnswer] { lock.withLock { recorded } }

    func answer(_ answer: AskAnswer) {
        lock.withLock { recorded.append(answer) }
    }

    func onHangUp(_ handler: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { hangUpHandler = handler }
    }

    @MainActor
    func hangUp() {
        lock.withLock { hangUpHandler }?()
    }
}

@MainActor
final class RecordingNativeNotifications: NativeNotificationControlling {
    var performed: [String] = []
    var succeeds = true
    var releases = 0
    /// Completions of `perform` calls, held back instead of called while set.
    var heldCompletions: [@MainActor (Bool) -> Void]?

    func perform(_ action: NativeAction, on identifiers: [String], from source: String, completion: @escaping @MainActor (Bool) -> Void) {
        let notifications = identifiers.joined(separator: " ")
        switch action {
        case .open: performed.append("open \(notifications) from \(source)")
        case .choice(let name): performed.append("\(name) \(notifications)")
        case .reply(let choice, let text, let send): performed.append("\(choice) \(notifications): \(text) [\(send)]")
        }
        if heldCompletions != nil {
            heldCompletions?.append(completion)
        } else {
            completion(succeeds)
        }
    }

    func notificationsReleased() {
        releases += 1
    }
}

@MainActor
final class FakePlatform: AccessibilityPlatform {
    var trusted = true
    var pid: pid_t? = 42
    var windowsByPID: [pid_t: [FakeElement]] = [:]
    var applicationsByPID: [pid_t: FakeElement] = [:]
    var observeSucceeds = true
    var observedPIDs: [pid_t] = []
    var handler: (@MainActor (any AccessibilityElement) -> Void)?
    var exitHandlers: [pid_t: @MainActor () -> Void] = [:]
    /// The menu bar clock; nil when none can be found.
    var clock: FakeElement?

    func isTrusted() -> Bool { trusted }

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

    func menuBarClock() -> (any AccessibilityElement)? { clock }
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
    /// The frame each `authorize` call started from.
    var sourceFrames: [CGRect?] = []
    var resets: [PermissionFlowPane] = []
    var resetResult = CommandResult(status: 0, output: "")
    /// Runs while `tccutil` would, before `reset` returns.
    var whileResetting: @MainActor (PermissionFlowPane) -> Void = { _ in }

    func state(of pane: PermissionFlowPane) -> PermissionAuthorizationState { states[pane] ?? .notGranted }

    func authorize(_ pane: PermissionFlowPane, from sourceFrame: CGRect?) {
        authorized.append(pane)
        sourceFrames.append(sourceFrame)
    }

    func reset(_ pane: PermissionFlowPane) async -> CommandResult {
        resets.append(pane)
        whileResetting(pane)
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

/// Records which apps it was asked to switch on, never touching System Settings, and answers `result`.
@MainActor
final class FakeAppNotificationSwitch: AppNotificationSwitching {
    var result = AppNotificationSwitchResult.switchedOn
    var requests: [(bundleIdentifier: String, name: String)] = []
    /// Runs while the request is in flight, before it returns.
    var whileSwitching: @MainActor () async -> Void = {}

    func allowNotifications(bundleIdentifier: String, name: String) async -> AppNotificationSwitchResult {
        requests.append((bundleIdentifier, name))
        await whileSwitching()
        return result
    }
}

extension AppNotificationsModel {
    /// Reads settings that do not exist, so no app counts as switched off, and switches nothing on.
    static func fake(received: @escaping @MainActor () -> [SidebarNotification] = { [] }) -> AppNotificationsModel {
        AppNotificationsModel(
            preferences: NotificationPreferences(url: URL(fileURLWithPath: "/nonexistent/group.com.apple.usernoted.plist")),
            switcher: FakeAppNotificationSwitch(),
            received: received
        )
    }
}

/// A choice without text input written as its title, as fixtures list an alert's choices.
extension NativeChoice: ExpressibleByStringLiteral {
    public init(stringLiteral title: String) {
        self.init(title: title)
    }
}

extension DeclaredChoices {
    /// Apps whose categories cannot be read, as without Full Disk Access, for tests whose notifications offer no
    /// declared choices: nothing is known about what they declared.
    static var none: DeclaredChoices { DeclaredChoices { _ in nil } }
}
