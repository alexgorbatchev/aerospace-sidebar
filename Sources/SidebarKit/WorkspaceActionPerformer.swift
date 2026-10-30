import AppKit
import os

/// Performs click actions with LaunchServices and the user's login shell.
@MainActor
public struct WorkspaceActionPerformer: NotificationActionPerforming {
    nonisolated private static let logger = Logger(category: "actions")

    private let applicationURL: @MainActor (String) -> URL?
    private let runningApplications: @MainActor () -> [(name: String?, bundleIdentifier: String?, url: URL?)]
    private let openApplication: @MainActor (URL) async throws -> Void

    public init() {
        self.init(applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
    }

    /// - Parameters:
    ///   - applicationURL: Where the app with a bundle identifier is installed.
    ///   - runningApplications: The running apps' names, bundle identifiers and locations.
    ///   - openApplication: Brings the app at a location forward, launching it when it is not running.
    init(
        applicationURL: @escaping @MainActor (String) -> URL?,
        runningApplications: @escaping @MainActor () -> [(name: String?, bundleIdentifier: String?, url: URL?)] = {
            NSWorkspace.shared.runningApplications.map { ($0.localizedName, $0.bundleIdentifier, $0.bundleURL) }
        },
        openApplication: @escaping @MainActor (URL) async throws -> Void = {
            _ = try await NSWorkspace.shared.openApplication(at: $0, configuration: NSWorkspace.OpenConfiguration())
        }
    ) {
        self.applicationURL = applicationURL
        self.runningApplications = runningApplications
        self.openApplication = openApplication
    }

    public func perform(_ action: SidebarNotification.ClickAction, bundleIdentifier: String?) {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .run(let command, let workingDirectory):
            do {
                try Self.run(command, in: workingDirectory)
            } catch {
                Self.logger.error("Cannot run click command: \(String(describing: error), privacy: .public)")
            }
        case .activateApp(let name):
            activateApp(named: name, bundleIdentifier: bundleIdentifier)
        }
    }

    public func run(_ command: String, in workingDirectory: String, environment: [String: String]) {
        do {
            try Self.run(command, in: workingDirectory, environment: environment)
        } catch {
            Self.logger.error("Cannot run choice command: \(String(describing: error), privacy: .public)")
        }
    }

    /// Brings the app that posted a notification forward, launching it when it is not running, as a click on
    /// the notification in macOS would. The app is the one with `bundleIdentifier`, a running copy before the
    /// one LaunchServices prefers (Xcode and Xcode-beta share theirs), else the running app called `name`; a
    /// helper without a user interface stands for the app around it (`app(standingFor:)`). LaunchServices
    /// activates it on the sidebar's behalf: the sidebar never becomes the active app, and since macOS 14 a
    /// background app's `NSRunningApplication.activate()` is only a request the system may decline. The
    /// returned task finishes once the app is open; nil when no app was found.
    @discardableResult
    func activateApp(named name: String, bundleIdentifier: String?) -> Task<Void, Never>? {
        let found = if let bundleIdentifier {
            runningApplications().first { $0.bundleIdentifier == bundleIdentifier }?.url ?? applicationURL(bundleIdentifier)
        } else {
            runningApplications().first { $0.name == name }?.url
        }
        guard let found else {
            Self.logger.error("Cannot find the app \(name, privacy: .public) (\(bundleIdentifier ?? "no bundle identifier", privacy: .public))")
            return nil
        }
        let url = Self.app(standingFor: found)
        let openApplication = openApplication
        return Task {
            do {
                try await openApplication(url)
            } catch {
                Self.logger.error("Cannot open \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The app to bring forward for the app at `url`: the app itself, unless it is an agent or background-only
    /// helper inside another app, which then stands for it. Chromium browsers post their alerts from such a
    /// helper (Google Chrome Helper (Alerts), which usernoted lists as an app of its own), and opening the
    /// helper would leave the browser where it is. An app with a user interface inside another one, such as
    /// Simulator inside Xcode, is opened as it is.
    static func app(standingFor url: URL) -> URL {
        guard !hasUserInterface(url) else { return url }
        var container = url
        while container.pathComponents.count > 1 {
            container.deleteLastPathComponent()
            if container.pathExtension == "app", hasUserInterface(container) { return container }
        }
        return url
    }

    /// Whether the app at `url` shows a user interface of its own: its Info.plist marks it neither an agent
    /// (`LSUIElement`) nor background-only (`LSBackgroundOnly`). Chromium's helpers write the flag as a string.
    private static func hasUserInterface(_ url: URL) -> Bool {
        guard let info = Bundle(url: url)?.infoDictionary else { return true }
        return !["LSUIElement", "LSBackgroundOnly"].contains { key in
            switch info[key] {
            case let flag as Bool: flag
            case let flag as String: NSString(string: flag).boolValue
            default: false
            }
        }
    }

    /// Starts `command` with the user's login shell, which loads the PATH a terminal would have, with
    /// `environment` added to the sidebar's own. Values reach the command only through its environment, never
    /// its text. Output is discarded; the exit status is logged.
    /// - Throws: `CocoaError(.fileReadInvalidFileName)` for a NUL character in the command, the directory or an added
    ///   variable, which `Process` would raise as an Objective-C exception and abort the app with; and whatever
    ///   starting the process throws, such as for a missing directory.
    @discardableResult
    public static func run(_ command: String, in workingDirectory: String, environment: [String: String] = [:]) throws -> Process {
        let values = [command, workingDirectory] + environment.flatMap { [$0.key, $0.value] }
        guard !values.contains(where: { $0.utf8.contains(0) }) else { throw CocoaError(.fileReadInvalidFileName) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-lc", command]
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, added in added }
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                logger.error("Command exited with status \(process.terminationStatus)")
            }
        }
        try process.run()
        return process
    }

    static var loginShell: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    }
}
