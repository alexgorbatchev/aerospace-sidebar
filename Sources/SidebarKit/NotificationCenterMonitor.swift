import AppKit
import ApplicationServices

/// The system services `NotificationCenterMonitor` needs; `SystemAccessibility` is the real one.
@MainActor
public protocol AccessibilityPlatform {
    /// Whether the app has the Accessibility permission. It never prompts: macOS's prompt opens System
    /// Settings without PermissionFlow's drag panel, which the sidebar's Set Up… and Settings › Permissions
    /// offer instead.
    func isTrusted() -> Bool
    func notificationCenterPID() -> pid_t?
    func application(ofProcess pid: pid_t) -> (any AccessibilityElement)?
    func windows(ofProcess pid: pid_t) -> [any AccessibilityElement]
    /// Calls `handler` with each element NotificationCenter reports as created or changed.
    /// Returns a token that keeps the observation alive, or nil when it cannot be set up.
    func observe(process pid: pid_t, handler: @escaping @MainActor (any AccessibilityElement) -> Void) -> AnyObject?
    /// Calls `handler` once the process exits. Returns a token that keeps watching while alive, or nil
    /// when the process cannot be watched.
    func watchExit(of pid: pid_t, handler: @escaping @MainActor () -> Void) -> AnyObject?
    /// The menu bar clock, whose press opens and closes Notification Center's history panel.
    func menuBarClock() -> (any AccessibilityElement)?
}

/// Keeps a `SystemNotificationInterceptor` attached to the NotificationCenter process:
/// waits for the Accessibility permission and re-attaches when NotificationCenter relaunches.
///
/// The permission can be granted or taken away at any time, in System Settings or through Settings ›
/// Permissions, so it is checked every `permissionPollInterval` while the monitor runs: the monitor attaches
/// once it is granted and lets go of NotificationCenter once it is gone.
///
/// NotificationCenter's exit is watched directly, because launch notifications alone missed its
/// relaunches (SignalLadder); after an exit the monitor retries attaching with a doubling delay, and
/// it attaches again after the Mac wakes (NotificationNanny).
///
/// Each event NotificationCenter reports starts a sweep of its windows, repeated every `sweepInterval`
/// while notifications are still closing or stacks expanding, and for `settleDuration` after the last
/// event. A banner reports a single layout change as it starts sliding in, and its close action only
/// works once the slide-in ends, so the repeats are what close it (NotificationNanny re-sweeps the same
/// way). Sweeping stops `maxSweepDuration` after the last event even if a notification never closes.
///
/// While `NotificationHistoryOpener` opens a notification from the history, its steps replace the sweeps,
/// which would otherwise move the panel's window back on screen, and run every `historyStepInterval`, so
/// that the panel is off-screen before it is seen; sweeping resumes once the panel is closed.
@MainActor
public final class NotificationCenterMonitor {
    nonisolated public static let notificationCenterBundleID = "com.apple.notificationcenterui"
    static let sweepInterval: TimeInterval = 0.25
    static let settleDuration: TimeInterval = 1.5
    static let maxSweepDuration: TimeInterval = 10
    static let maxReattachDelay: TimeInterval = 30
    static let historyStepInterval: TimeInterval = 0.02

    private let platform: any AccessibilityPlatform
    private let interceptor: SystemNotificationInterceptor
    private let historyOpener: NotificationHistoryOpener
    private let onStatus: @MainActor (InterceptionStatus) -> Void
    private let workspaceCenter: NotificationCenter
    private let permissionPollInterval: TimeInterval
    private let initialReattachDelay: TimeInterval
    private let now: () -> Date
    private var observation: AnyObject?
    private var attachedPID: pid_t?
    private var permissionTimer: Timer?
    /// Set while the Accessibility permission is missing; `checkPermission()` attaches once it arrives.
    private(set) var isWaitingForPermission = false
    private var sweepTimer: Timer?
    private var historyTimer: Timer?
    private var lastEvent: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var exitWatch: AnyObject?
    private var reattachTimer: Timer?
    private var reattachDelay: TimeInterval
    public private(set) var isRunning = false

    /// - Parameters:
    ///   - permissionPollInterval: How often to check whether the Accessibility permission was granted or
    ///     taken away.
    ///   - initialReattachDelay: How long to wait before the first attempt to attach again after
    ///     NotificationCenter exits or cannot be attached to; the delay doubles up to `maxReattachDelay`.
    public init(
        platform: any AccessibilityPlatform = SystemAccessibility(),
        interceptor: SystemNotificationInterceptor,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        permissionPollInterval: TimeInterval = 2,
        initialReattachDelay: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init,
        onStatus: @escaping @MainActor (InterceptionStatus) -> Void
    ) {
        self.platform = platform
        self.interceptor = interceptor
        self.historyOpener = NotificationHistoryOpener(now: now)
        self.workspaceCenter = workspaceCenter
        self.permissionPollInterval = permissionPollInterval
        self.initialReattachDelay = initialReattachDelay
        self.reattachDelay = initialReattachDelay
        self.now = now
        self.onStatus = onStatus
    }

    isolated deinit {
        sweepTimer?.invalidate()
        historyTimer?.invalidate()
        permissionTimer?.invalidate()
        reattachTimer?.invalidate()
    }

    /// Attaches, or waits for the Accessibility permission when it is missing.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        workspaceObservers = [
            workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.notificationCenterBundleID else { return }
                MainActor.assumeIsolated { self?.attachUnlessWaitingForPermission() }
            },
            // NotificationCenter can take many seconds to answer after a wake (NotificationNanny), and
            // its windows may have been rebuilt meanwhile.
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachUnlessWaitingForPermission() }
            },
        ]
        permissionTimer = Timer.scheduledTimer(withTimeInterval: permissionPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermission() }
        }
        attach()
    }

    /// Attaches once the Accessibility permission has been granted, and lets go of NotificationCenter once
    /// it has been taken away.
    public func checkPermission() {
        guard isRunning else { return }
        if platform.isTrusted() {
            guard isWaitingForPermission else { return }
            isWaitingForPermission = false
            attach()
        } else if !isWaitingForPermission {
            SystemNotificationInterceptor.logger.notice("The Accessibility permission was taken away")
            waitForPermission()
        }
    }

    /// Stops observing and moves any hidden NotificationCenter window back on-screen.
    public func stop() {
        isRunning = false
        isWaitingForPermission = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers = []
        observation = nil
        exitWatch = nil
        reattachTimer?.invalidate()
        reattachTimer = nil
        stopSweeping()
        stopOpeningHistory()
        if let attachedPID {
            interceptor.restore(platform.windows(ofProcess: attachedPID))
        }
        attachedPID = nil
        interceptor.detach()
    }

    /// Sweeps again after a change outside NotificationCenter that moves where its windows belong, such
    /// as the sidebar changing side or width.
    public func refresh() {
        guard attachedPID != nil else { return }
        notificationCenterChanged()
    }

    /// Sweeps now and keeps sweeping until NotificationCenter settles; while a notification is being opened
    /// from the history, advances that instead.
    func notificationCenterChanged() {
        if historyOpener.isOpening {
            stepHistory()
            return
        }
        lastEvent = now()
        sweep()
        guard sweepTimer == nil else { return }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepAgain() }
        }
    }

    /// A repeated sweep; stops once NotificationCenter has been quiet long enough.
    func sweepAgain() {
        let outcome = sweep()
        let quiet = lastEvent.map { now().timeIntervalSince($0) } ?? .infinity
        if quiet >= Self.maxSweepDuration {
            if outcome == .pending {
                SystemNotificationInterceptor.logger.notice("Notifications still closing after \(Self.maxSweepDuration, privacy: .public) s")
            }
            stopSweeping()
        } else if outcome == .settled, quiet >= Self.settleDuration {
            stopSweeping()
        }
    }

    var isSweeping: Bool { sweepTimer != nil }

    @discardableResult
    private func sweep() -> SystemNotificationInterceptor.Outcome {
        guard let attachedPID else { return .settled }
        return interceptor.sweep(windows: platform.windows(ofProcess: attachedPID), application: platform.application(ofProcess: attachedPID))
    }

    private func stopSweeping() {
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// Whether an attempt to attach again is scheduled.
    var isWaitingToReattach: Bool { reattachTimer != nil }

    /// Stops observing the NotificationCenter process that exited and tries to attach to its successor.
    func notificationCenterExited(pid: pid_t) {
        guard pid == attachedPID else { return }
        SystemNotificationInterceptor.logger.notice("NotificationCenter (pid \(pid, privacy: .public)) exited")
        detach()
        onStatus(.notificationCenterUnavailable)
        scheduleReattach()
    }

    /// Stops observing NotificationCenter, leaving its windows where they are.
    private func detach() {
        observation = nil
        exitWatch = nil
        attachedPID = nil
        stopSweeping()
        stopOpeningHistory()
        interceptor.detach()
    }

    /// Lets go of NotificationCenter, whose windows can no longer be read or moved, until
    /// `checkPermission()` finds the Accessibility permission granted.
    private func waitForPermission() {
        detach()
        reattachTimer?.invalidate()
        reattachTimer = nil
        isWaitingForPermission = true
        onStatus(.needsAccessibility)
    }

    private func scheduleReattach() {
        guard isRunning, reattachTimer == nil else { return }
        let delay = reattachDelay
        reattachDelay = min(delay * 2, Self.maxReattachDelay)
        reattachTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reattachTimer = nil
                self?.attach()
            }
        }
    }

    /// Until the Accessibility permission arrives, `checkPermission()` attaches and the status says so.
    private func attachUnlessWaitingForPermission() {
        guard !isWaitingForPermission else { return }
        attach()
    }

    private func attach() {
        guard platform.isTrusted() else { return waitForPermission() }
        guard let pid = platform.notificationCenterPID() else {
            SystemNotificationInterceptor.logger.error("NotificationCenter is not running")
            onStatus(.notificationCenterUnavailable)
            scheduleReattach()
            return
        }
        observation = platform.observe(process: pid) { [weak self] _ in
            self?.notificationCenterChanged()
        }
        guard observation != nil else {
            SystemNotificationInterceptor.logger.error("Cannot observe NotificationCenter (pid \(pid, privacy: .public))")
            onStatus(.notificationCenterUnavailable)
            scheduleReattach()
            return
        }
        exitWatch = platform.watchExit(of: pid) { [weak self] in
            self?.notificationCenterExited(pid: pid)
        }
        reattachTimer?.invalidate()
        reattachTimer = nil
        reattachDelay = initialReattachDelay
        SystemNotificationInterceptor.logger.info("Attached to NotificationCenter (pid \(pid, privacy: .public))")
        attachedPID = pid
        let language = platform.application(ofProcess: pid)?.string("AXPreferredLanguage")
        interceptor.labels = NotificationCenterLabels.load(language: language)
        historyOpener.labels = interceptor.labels
        interceptor.restore(platform.windows(ofProcess: pid))
        notificationCenterChanged()
        onStatus(.active)
    }
}

extension NotificationCenterMonitor: NativeNotificationControlling {
    @discardableResult
    public func perform(_ action: AlertAction, onAlert identifier: String) -> Bool {
        guard let attachedPID else { return false }
        return interceptor.perform(action, onAlert: identifier, in: platform.windows(ofProcess: attachedPID))
    }

    /// Presses the notification where NotificationCenter shows or hides it, else opens it from the history
    /// (`NotificationHistoryOpener`). One history request runs at a time; another fails meanwhile.
    public func open(_ identifiers: [String], from source: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let attachedPID else { return completion(false) }
        if interceptor.open(identifiers, in: platform.windows(ofProcess: attachedPID)) {
            return completion(true)
        }
        guard historyOpener.start(identifiers, from: source, completion: completion) else { return completion(false) }
        stopSweeping()
        stepHistory()
        guard historyOpener.isOpening, historyTimer == nil else { return }
        historyTimer = Timer.scheduledTimer(withTimeInterval: Self.historyStepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepHistory() }
        }
    }

    /// Sweeps, which closes the hidden notifications that no card stands for any more.
    public func notificationsReleased() {
        guard attachedPID != nil else { return }
        notificationCenterChanged()
    }

    var isOpeningHistory: Bool { historyOpener.isOpening }

    /// Advances the history request; once it is done, sweeping resumes.
    func stepHistory() {
        guard let attachedPID else { return stopOpeningHistory() }
        let working = historyOpener.step(
            windows: platform.windows(ofProcess: attachedPID),
            application: platform.application(ofProcess: attachedPID),
            clock: platform.menuBarClock()
        )
        guard !working else { return }
        stopOpeningHistory()
        notificationCenterChanged()
    }

    /// Stops stepping, and abandons a request that is still running.
    private func stopOpeningHistory() {
        historyTimer?.invalidate()
        historyTimer = nil
        historyOpener.cancel()
    }
}

/// `AccessibilityPlatform` backed by the macOS Accessibility API.
@MainActor
public struct SystemAccessibility: AccessibilityPlatform {
    public init() {}

    public func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func notificationCenterPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: NotificationCenterMonitor.notificationCenterBundleID)
            .first?.processIdentifier
    }

    public func application(ofProcess pid: pid_t) -> (any AccessibilityElement)? {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public func windows(ofProcess pid: pid_t) -> [any AccessibilityElement] {
        let windows = AXElement(AXUIElementCreateApplication(pid)).attribute(kAXWindowsAttribute) as? [AXUIElement]
        return windows?.map(AXElement.init) ?? []
    }

    public func observe(
        process pid: pid_t,
        handler: @escaping @MainActor (any AccessibilityElement) -> Void
    ) -> AnyObject? {
        // NotificationCenter can take about 15 s to answer after a wake (NotificationNanny); every
        // accessibility call runs on the main thread, so a shorter timeout keeps the sidebar responsive.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
        return AXNotificationObservation(pid: pid, handler: handler)
    }

    public func watchExit(of pid: pid_t, handler: @escaping @MainActor () -> Void) -> AnyObject? {
        ProcessExitWatch(pid: pid, handler: handler)
    }

    /// Control Center hosts the clock on macOS 26; later versions moved it to the menu bar agent, under a
    /// group without actions (OmniWM, dwarvesf/hidden), so it is looked for one level down too.
    public func menuBarClock() -> (any AccessibilityElement)? {
        for bundleIdentifier in Self.menuExtraHosts {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                let host = AXElement(AXUIElementCreateApplication(app.processIdentifier))
                guard let bar = host.attribute(kAXExtrasMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { continue }
                let items = AXElement(bar as! AXUIElement).children
                let candidates = items + items.flatMap { $0.children }
                if let clock = candidates.first(where: { $0.string(kAXIdentifierAttribute) == Self.clockIdentifier }) {
                    return clock
                }
            }
        }
        return nil
    }

    static let menuExtraHosts = ["com.apple.controlcenter", "com.apple.MenuBarAgent"]
    static let clockIdentifier = "com.apple.menuextra.clock"

    static let messagingTimeout: Float = 1
}

/// Owns a dispatch source that reports a process's exit.
@MainActor
final class ProcessExitWatch {
    private let source: any DispatchSourceProcess

    init?(pid: pid_t, handler: @escaping @MainActor () -> Void) {
        // kill(pid, 0) only checks that the process exists; a source for a missing one would never fire.
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return nil }
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.resume()
    }

    isolated deinit {
        source.cancel()
    }
}

/// Owns an `AXObserver` on an application element and its run loop source.
@MainActor
final class AXNotificationObservation {
    /// Every banner and alert reports a layout change; `kAXFocusedWindowChanged` reports the history panel
    /// opening and closing (vorssaint-utils).
    private static let notifications = [
        kAXWindowCreatedNotification,
        kAXValueChangedNotification,
        kAXLayoutChangedNotification,
        kAXFocusedWindowChangedNotification,
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
        // The common modes keep events flowing while a menu or another modal loop runs (SignalLadder).
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    isolated deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
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

    func bool(_ attribute: String) -> Bool? {
        self.attribute(attribute) as? Bool
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
