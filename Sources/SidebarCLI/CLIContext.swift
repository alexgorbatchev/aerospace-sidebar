import AppKit
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
    /// Whether an app with this bundle identifier is installed.
    public var isInstalledApp: @Sendable (String) -> Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        output: any TextOutput = FileHandleOutput(.standardOutput),
        errorOutput: any TextOutput = FileHandleOutput(.standardError),
        sender: any NotificationSending = SocketNotificationSender(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        terminalWidth: Int? = CLIContext.standardOutputWidth(),
        isInstalledApp: @escaping @Sendable (String) -> Bool = CLIContext.isInstalledApp
    ) {
        self.environment = environment
        self.output = output
        self.errorOutput = errorOutput
        self.sender = sender
        self.workingDirectory = workingDirectory
        self.homeDirectory = homeDirectory
        self.terminalWidth = terminalWidth
        self.isInstalledApp = isInstalledApp
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

    /// Terminals by the `TERM_PROGRAM` they set, for shells that did not inherit `__CFBundleIdentifier`.
    static let terminalPrograms = [
        "Apple_Terminal": "com.apple.Terminal",
        "ghostty": "com.mitchellh.ghostty",
        "iTerm.app": "com.googlecode.iterm2",
        "vscode": "com.microsoft.VSCode",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
    ]

    /// The installed app this command runs in, such as its terminal: `__CFBundleIdentifier`, which macOS puts in
    /// an app's environment and its child processes inherit, else the terminal `TERM_PROGRAM` names. The
    /// sidebar is skipped, because commands run from its cards inherit its identifier.
    var hostApp: String? {
        [environment["__CFBundleIdentifier"], environment["TERM_PROGRAM"].flatMap { Self.terminalPrograms[$0] }]
            .compactMap { $0 }
            .first { $0 != SidebarApp.bundleIdentifier && isInstalledApp($0) }
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

    @Sendable
    public static func isInstalledApp(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    public static func standardOutputWidth() -> Int? {
        var size = winsize()
        guard isatty(STDOUT_FILENO) != 0, ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return nil
        }
        return Int(size.ws_col)
    }
}
