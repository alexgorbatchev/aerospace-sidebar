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
        /// Written, with AeroSpace asked to reload it, while AeroSpace reports `problems` the config already had.
        case updatedWithExistingProblems(backup: URL, problems: String)
        /// Written, but the `aerospace` CLI was unavailable to validate and reload it.
        case updatedWithoutReload(backup: URL)
        /// Written while AeroSpace was not running; it reads the config when it starts.
        case updatedWhileStopped(backup: URL)
    }

    public enum SetupError: Error, Equatable {
        case notFound
        case unsupported(String)
        /// AeroSpace reports problems the edit added; `original`, the config before it, was restored.
        case rejected(String, original: String)
        /// AeroSpace reports problems the edit added, but the config was saved again while AeroSpace checked
        /// it; that version was kept.
        case rejectedAndReplaced(String)
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

    /// The files to watch for changes: every place AeroSpace looks for its config, so a config created or
    /// moved there is seen, and the target of each symlinked one. A watcher on the symlink follows the target
    /// file, but not its directory: a target removed and created again later, which leaves the symlink's
    /// directory as it was, is seen only by a watcher on the target's.
    public func configsToWatch() -> [URL] {
        let candidates = AeroSpaceConfig.candidates(home: home, environment: environment)
        return candidates + candidates.compactMap(Self.symlinkTarget(of:))
    }

    /// The file the symlink at `url` points to, through any further symlinks; nil when `url` is not a
    /// symlink. Unlike `resolvingSymlinksInPath()`, which leaves a symlink to a missing file as it is, it
    /// names a missing target too, so that its return is watched.
    static func symlinkTarget(of url: URL) -> URL? {
        var target = url
        var links = 0
        while links < MAXSYMLINKS, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).absoluteURL.standardizedFileURL
            links += 1
        }
        return links == 0 ? nil : target
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

    /// Edits the config to reserve `sidebar`'s strip, checks it with `aerospace reload-config --dry-run` before
    /// and after the edit, restores the original when AeroSpace reports problems the edit added, and reloads
    /// AeroSpace. While AeroSpace is not running the edit is kept without either step. The previous config is
    /// kept next to it as `aerospace.toml.bak`, replacing an older backup. Symlinked configs are edited at their
    /// target.
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
        // A config the editor cannot change is refused before AeroSpace is asked about it.
        _ = try edit(url, sidebar: sidebar, rewritingBlock: rewritingBlock)
        // AeroSpace reports some problems and still loads the config, such as a key the running version does
        // not know; problems the config already has do not count against the edit.
        let before = isAeroSpaceRunning() ? await cli.run(Self.check) : nil
        // Read again, so that a version saved during the check is the one edited.
        let (original, edited) = try edit(url, sidebar: sidebar, rewritingBlock: rewritingBlock)

        let backup = url.appendingPathExtension("bak")
        do {
            try original.write(to: backup, atomically: true, encoding: .utf8)
            try edited.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw .io(String(describing: error))
        }

        guard let before else { return .updatedWhileStopped(backup: backup) }
        guard before.status != 127 else { return .updatedWithoutReload(backup: backup) }
        let validation = await cli.run(Self.check)
        if let added = Self.problems(addedBy: validation, to: before) {
            // Restoring would overwrite a version saved while AeroSpace checked the edit.
            guard (try? String(contentsOf: url, encoding: .utf8)) == edited else { throw .rejectedAndReplaced(added) }
            try? original.write(to: url, atomically: true, encoding: .utf8)
            throw .rejected(added, original: original)
        }
        _ = await cli.run(["reload-config", "--no-gui"])
        if validation.status == 0 {
            return .updated(backup: backup)
        }
        return .updatedWithExistingProblems(backup: backup, problems: validation.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let check = ["reload-config", "--dry-run", "--no-gui"]

    /// The config at `url` and its edited version.
    private func edit(_ url: URL, sidebar: SidebarSettings.Sidebar, rewritingBlock: Bool) throws(SetupError) -> (original: String, edited: String) {
        let original: String
        do {
            original = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw .io(String(describing: error))
        }
        do {
            return (original, try AeroSpaceConfigEditor.apply(to: original, sidebar: sidebar, rewritingBlock: rewritingBlock))
        } catch let AeroSpaceConfigEditor.EditError.unsupported(reason) {
            throw .unsupported(reason)
        } catch {
            throw .unsupported(String(describing: error))
        }
    }

    /// The problems `validation` of the edited config reports that `before`, the check of the original, did
    /// not; nil when the edited config passes or reports only problems the original had. AeroSpace separates
    /// the problems it reports with blank lines and names array elements by index (`gaps.outer.right[1]`).
    /// The edit inserts and drops gap entries, which moves the problems of the entries after them to other
    /// indices, so problems are compared without their indices, each one matching one problem of the original.
    static func problems(addedBy validation: CommandResult, to before: CommandResult) -> String? {
        guard validation.status != 0 else { return nil }
        guard before.status != 0 else { return validation.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        func problems(in output: String) -> [String] {
            output.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func withoutIndices(_ problem: String) -> String {
            problem.replacing(/\[\d+\]/, with: "[]")
        }
        var existing = problems(in: before.output).map(withoutIndices)
        let added = problems(in: validation.output).filter { problem in
            guard let match = existing.firstIndex(of: withoutIndices(problem)) else { return true }
            existing.remove(at: match)
            return false
        }
        return added.isEmpty ? nil : added.joined(separator: "\n\n")
    }
}
