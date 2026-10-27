import AppKit
import ApplicationServices

/// The system services `NotificationCenterMonitor` needs; `SystemAccessibility` is the real one.
@MainActor
public protocol AccessibilityPlatform {
    func isTrusted(prompt: Bool) -> Bool
    func notificationCenterPID() -> pid_t?
    func windows(ofProcess pid: pid_t) -> [any AccessibilityElement]
    /// Calls `handler` with each element NotificationCenter reports as created or changed.
    /// Returns a token that keeps the observation alive, or nil when it cannot be set up.
    func observe(process pid: pid_t, handler: @escaping @MainActor (any AccessibilityElement) -> Void) -> AnyObject?
}

/// Keeps a `SystemNotificationInterceptor` attached to the NotificationCenter process:
/// waits for the Accessibility permission and re-attaches when NotificationCenter relaunches.
@MainActor
public final class NotificationCenterMonitor {
    nonisolated public static let notificationCenterBundleID = "com.apple.notificationcenterui"

    private let platform: any AccessibilityPlatform
    private let interceptor: SystemNotificationInterceptor
    private let onStatus: @MainActor (InterceptionStatus) -> Void
    private let workspaceCenter: NotificationCenter
    private let permissionPollInterval: TimeInterval
    private var observation: AnyObject?
    private var attachedPID: pid_t?
    private var permissionTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    public private(set) var isRunning = false

    /// - Parameter permissionPollInterval: How often to check whether the Accessibility permission was granted.
    public init(
        platform: any AccessibilityPlatform = SystemAccessibility(),
        interceptor: SystemNotificationInterceptor,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        permissionPollInterval: TimeInterval = 2,
        onStatus: @escaping @MainActor (InterceptionStatus) -> Void
    ) {
        self.platform = platform
        self.interceptor = interceptor
        self.workspaceCenter = workspaceCenter
        self.permissionPollInterval = permissionPollInterval
        self.onStatus = onStatus
    }

    /// Prompts for the Accessibility permission when missing, then attaches once it is granted.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        launchObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.notificationCenterBundleID else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
        if platform.isTrusted(prompt: true) {
            attach()
        } else {
            onStatus(.needsAccessibility)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: permissionPollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPermission() }
            }
        }
    }

    /// Attaches once the Accessibility permission has been granted.
    func checkPermission() {
        guard platform.isTrusted(prompt: false) else { return }
        permissionTimer?.invalidate()
        permissionTimer = nil
        attach()
    }

    /// Stops observing and moves any hidden NotificationCenter window back on-screen.
    public func stop() {
        isRunning = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let launchObserver {
            workspaceCenter.removeObserver(launchObserver)
        }
        launchObserver = nil
        observation = nil
        if let attachedPID {
            interceptor.restore(platform.windows(ofProcess: attachedPID))
        }
        attachedPID = nil
    }

    private func attach() {
        guard platform.isTrusted(prompt: false), let pid = platform.notificationCenterPID() else {
            SystemNotificationInterceptor.logger.error("NotificationCenter is not running or not accessible")
            onStatus(.notificationCenterUnavailable)
            return
        }
        observation = platform.observe(process: pid) { [weak self] element in
            self?.interceptor.process(window: element)
        }
        guard observation != nil else {
            SystemNotificationInterceptor.logger.error("Cannot observe NotificationCenter (pid \(pid, privacy: .public))")
            onStatus(.notificationCenterUnavailable)
            return
        }
        SystemNotificationInterceptor.logger.info("Attached to NotificationCenter (pid \(pid, privacy: .public))")
        attachedPID = pid
        let windows = platform.windows(ofProcess: pid)
        interceptor.restore(windows)
        windows.forEach(interceptor.process(window:))
        onStatus(.active)
    }
}

/// `AccessibilityPlatform` backed by the macOS Accessibility API.
@MainActor
public struct SystemAccessibility: AccessibilityPlatform {
    public init() {}

    public func isTrusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    public func notificationCenterPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID)
            .first?.processIdentifier
    }

    public func windows(ofProcess pid: pid_t) -> [any AccessibilityElement] {
        let windows = AXElement(AXUIElementCreateApplication(pid)).attribute(kAXWindowsAttribute) as? [AXUIElement]
        return windows?.map(AXElement.init) ?? []
    }

    public func observe(
        process pid: pid_t,
        handler: @escaping @MainActor (any AccessibilityElement) -> Void
    ) -> AnyObject? {
        AXNotificationObservation(pid: pid, handler: handler)
    }
}

/// Owns an `AXObserver` on an application element and its run loop source.
@MainActor
final class AXNotificationObservation {
    private static let notifications = [
        kAXWindowCreatedNotification,
        kAXValueChangedNotification,
        kAXLayoutChangedNotification,
    ]

    private let observer: AXObserver
    private let handler: @MainActor (any AccessibilityElement) -> Void

    init?(pid: pid_t, handler: @escaping @MainActor (any AccessibilityElement) -> Void) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, context in
            guard let context else { return }
            let observation = Unmanaged<AXNotificationObservation>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observation.handler(AXElement(element)) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return nil }
        self.observer = observer
        self.handler = handler
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.notifications {
            AXObserverAddNotification(observer, application, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    isolated deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// `AccessibilityElement` over an `AXUIElement`.
@MainActor
struct AXElement: AccessibilityElement {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? {
        self.attribute(attribute) as? String
    }

    var children: [any AccessibilityElement] {
        (attribute(kAXChildrenAttribute) as? [AXUIElement])?.map(AXElement.init) ?? []
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    var position: CGPoint? {
        guard let value = attribute(kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }
}
