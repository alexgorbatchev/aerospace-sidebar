import AppKit
import SidebarProtocol

/// Output of an `aerospace` CLI invocation.
public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs the `aerospace` CLI; `LoginShellAeroSpaceCLI` is the real implementation.
public protocol AeroSpaceCommandRunning: Sendable {
    func run(_ arguments: [String]) async -> CommandResult
}

/// Runs `aerospace` through the user's login shell, which has the PATH a terminal would have
/// (GUI apps do not see Homebrew's `/opt/homebrew/bin`).
public struct LoginShellAeroSpaceCLI: AeroSpaceCommandRunning {
    public init() {}

    public func run(_ arguments: [String]) async -> CommandResult {
        let shell = await WorkspaceActionPerformer.loginShell
        return await SystemCommand.run(shell, ["-lc", "exec aerospace \"$@\"", "aerospace"] + arguments)
    }
}

/// Reports and applies the AeroSpace configuration the sidebar needs.
public struct AeroSpaceSetup: Sendable {
    public enum State: Equatable, Sendable {
        case ready(AeroSpaceConfigEditor.Analysis, url: URL)
        case notFound
        case unreadable(String)
    }

    public enum Outcome: Equatable, Sendable {
        case updated(backup: URL)
        /// Written, but the `aerospace` CLI was unavailable to validate and reload it.
        case updatedWithoutReload(backup: URL)
        /// Written while AeroSpace was not running; it reads the config when it starts.
        case updatedWhileStopped(backup: URL)
    }

    public enum SetupError: Error, Equatable {
        case notFound
        case unsupported(String)
        /// AeroSpace rejected the edited config; the original was restored.
        case rejected(String)
        case io(String)
    }

    let home: URL
    let environment: [String: String]
    let cli: any AeroSpaceCommandRunning
    let isAeroSpaceRunning: @Sendable () -> Bool

    /// - Parameter isAeroSpaceRunning: The CLI talks to the running AeroSpace app, so it cannot validate
    ///   or reload a config while AeroSpace is stopped.
    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cli: any AeroSpaceCommandRunning = LoginShellAeroSpaceCLI(),
        isAeroSpaceRunning: @escaping @Sendable () -> Bool = AeroSpaceSetup.aeroSpaceAppIsRunning
    ) {
        self.home = home
        self.environment = environment
        self.cli = cli
        self.isAeroSpaceRunning = isAeroSpaceRunning
    }

    public static let aeroSpaceBundleIdentifier = "bobko.aerospace"

    @Sendable public static func aeroSpaceAppIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: aeroSpaceBundleIdentifier).isEmpty
    }

    /// The file to watch for changes: the config AeroSpace loads, or where AeroSpace looks first under
    /// `XDG_CONFIG_HOME` when there is none yet. Symlinks are resolved, since edits land at the target.
    public func configToWatch() -> URL {
        let located = try? AeroSpaceConfig.locate(home: home, environment: environment)
        return (located ?? AeroSpaceConfig.candidates(home: home, environment: environment)[1]).resolvingSymlinksInPath()
    }

    /// The config compared with `sidebar`.
    public func state(for sidebar: SidebarSettings.Sidebar) -> State {
        do {
            let url = try AeroSpaceConfig.locate(home: home, environment: environment)
            return .ready(AeroSpaceConfigEditor.analyze(try String(contentsOf: url, encoding: .utf8), sidebar: sidebar), url: url)
        } catch AeroSpaceConfig.Error.notFound {
            return .notFound
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// Edits the config to reserve `sidebar`'s strip, validates it with `aerospace reload-config --dry-run`,
    /// restores the original when AeroSpace rejects it, and reloads AeroSpace. While AeroSpace is not
    /// running the edit is kept without either step. The previous config is kept next to it as
    /// `aerospace.toml.bak`, replacing an older backup. Symlinked configs are edited at their target.
    /// Generated configs are edited too: the sidebar puts its block back after each regeneration.
    /// - Parameter rewritingBlock: Writes the managed block and reloads even when the config already matches.
    public func apply(sidebar: SidebarSettings.Sidebar, rewritingBlock: Bool = false) async throws(SetupError) -> Outcome {
        let url: URL
        do {
            url = try AeroSpaceConfig.locate(home: home, environment: environment).resolvingSymlinksInPath()
        } catch .notFound {
            throw .notFound
        } catch {
            throw .io(String(describing: error))
        }
        let original: String
        do {
            original = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .io(String(describing: error))
        }
        let edited: String
        do {
            edited = try AeroSpaceConfigEditor.apply(to: original, sidebar: sidebar, rewritingBlock: rewritingBlock)
        } catch let AeroSpaceConfigEditor.EditError.unsupported(reason) {
            throw .unsupported(reason)
        } catch {
            throw .unsupported(String(describing: error))
        }

        let backup = url.appendingPathExtension("bak")
        do {
            try original.write(to: backup, atomically: true, encoding: .utf8)
            try edited.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw .io(String(describing: error))
        }

        guard isAeroSpaceRunning() else { return .updatedWhileStopped(backup: backup) }
        let validation = await cli.run(["reload-config", "--dry-run", "--no-gui"])
        if validation.status == 127 {
            return .updatedWithoutReload(backup: backup)
        }
        guard validation.status == 0 else {
            try? original.write(to: url, atomically: true, encoding: .utf8)
            throw .rejected(validation.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = await cli.run(["reload-config", "--no-gui"])
        return .updated(backup: backup)
    }
}
