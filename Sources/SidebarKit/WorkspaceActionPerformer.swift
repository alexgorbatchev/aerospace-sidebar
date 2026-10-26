import AppKit
import os

/// Performs click actions with LaunchServices and the user's login shell.
@MainActor
public struct WorkspaceActionPerformer: NotificationActionPerforming {
    nonisolated private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "actions")

    public init() {}

    public func perform(_ action: SidebarNotification.ClickAction) {
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
            NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.activate()
        }
    }

    /// Starts `command` with the user's login shell, which loads the PATH a terminal would have.
    /// Output is discarded; the exit status is logged.
    @discardableResult
    public static func run(_ command: String, in workingDirectory: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                logger.error("Click command exited with status \(process.terminationStatus)")
            }
        }
        try process.run()
        return process
    }

    static var loginShell: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    }
}
