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

extension OnboardingModel {
    static func fake() -> OnboardingModel {
        OnboardingModel(accessibility: FakePlatform(), loginItems: FakeLoginItems(), performer: RecordingPerformer())
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
