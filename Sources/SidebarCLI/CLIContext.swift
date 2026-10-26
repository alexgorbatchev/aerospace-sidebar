import Foundation
import SidebarProtocol

/// A destination for command output; writes fail loudly so callers can report them.
public protocol TextOutput: Sendable {
    func write(_ text: String) throws
}

/// Writes to a file handle such as standard output.
public struct FileHandleOutput: TextOutput {
    private let handle: FileHandle

    public init(_ handle: FileHandle) {
        self.handle = handle
    }

    public func write(_ text: String) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}

public struct OutputWriteError: Error, Equatable {
    public let underlying: String
}

/// Delivers notifications to the sidebar app.
public protocol NotificationSending: Sendable {
    func push(_ payload: NotificationPayload) async throws
}

/// Process-level inputs for one CLI invocation.
public struct CLIContext: Sendable {
    @TaskLocal public static var current = CLIContext()

    public var environment: [String: String]
    public var output: any TextOutput
    public var errorOutput: any TextOutput
    public var sender: any NotificationSending
    public var workingDirectory: String
    public var homeDirectory: String
    /// Columns available for help text; nil when standard output is not a terminal.
    public var terminalWidth: Int?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: any TextOutput = FileHandleOutput(.standardOutput),
        errorOutput: any TextOutput = FileHandleOutput(.standardError),
        sender: any NotificationSending = SocketNotificationSender(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        terminalWidth: Int? = CLIContext.standardOutputWidth()
    ) {
        self.environment = environment
        self.output = output
        self.errorOutput = errorOutput
        self.sender = sender
        self.workingDirectory = workingDirectory
        self.homeDirectory = homeDirectory
        self.terminalWidth = terminalWidth
    }

    /// Writes command output; failures surface as `OutputWriteError` so the CLI exits with `EX_IOERR`.
    func emit(_ text: String) throws(OutputWriteError) {
        do {
            try output.write(text)
        } catch {
            throw OutputWriteError(underlying: String(describing: error))
        }
    }

    /// `AGENT=1`, `true` or `yes` selects token-conservative agent output.
    public var isAgent: Bool {
        ["1", "true", "yes"].contains(environment["AGENT"]?.lowercased() ?? "")
    }

    /// Width of human help screens, resolved like ArgumentParser does: `COLUMNS`, else the terminal, else 80.
    var helpWidth: Int {
        environment["COLUMNS"].flatMap(Int.init) ?? terminalWidth ?? 80
    }

    /// Shows paths under the home directory as `~/…`, matching whole path segments only.
    public func displayPath(_ path: String) -> String {
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func standardOutputWidth() -> Int? {
        var size = winsize()
        guard isatty(STDOUT_FILENO) != 0, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return nil
        }
        return Int(size.ws_col)
    }
}
