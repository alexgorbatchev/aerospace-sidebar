import ArgumentParser
import Foundation
import SidebarProtocol

/// Entry point shared by the `aerospace-sidebar` executable and tests.
public enum SidebarCLI {
    static let agentAlert = "ALERT: Agents must read `AGENT=1 aerospace-sidebar skill` before using this tool.\n"

    /// Runs one invocation and returns its exit status.
    public static func main(arguments: [String], context: CLIContext = CLIContext()) async -> Int32 {
        await CLIContext.$current.withValue(context) {
            do {
                var command = try RootCommand.parseAsRoot(arguments)
                if var asyncCommand = command as? any AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
                return 0
            } catch {
                return report(error, arguments: arguments, context: context)
            }
        }
    }

    private static func report(_ error: Error, arguments: [String], context: CLIContext) -> Int32 {
        let (message, status) = describe(error, arguments: arguments, context: context)
        do {
            if status == 0 {
                try context.output.write(message)
            } else {
                try context.errorOutput.write(message)
            }
            return status
        } catch {
            return EX_IOERR
        }
    }

    private static func describe(_ error: Error, arguments: [String], context: CLIContext) -> (String, Int32) {
        let agent = context.isAgent
        switch error {
        case let error as CLIError:
            return (agent ? "ERR: \(agentDescription(error, context))\n" : "[ERROR] \(humanDescription(error, context))\n", 1)
        case let error as OutputWriteError:
            return (agent ? "ERR: output_write_failed: \(error.underlying)\n" : "[ERROR] Cannot write output: \(error.underlying)\n", EX_IOERR)
        case let error as SidebarRequestError:
            return (agent ? "ERR: \(error)\n" : "[ERROR] \(error)\n", 1)
        default:
            let status = RootCommand.exitCode(for: error).rawValue
            // Agent help is never wrapped; human help wraps at the width the command tree is trimmed to.
            var message = RootCommand.fullMessage(for: error, columns: agent ? Int(Int32.max) : context.helpWidth)
            if !message.hasSuffix("\n") { message += "\n" }
            // Help screens are the only successful parser exits besides ArgumentParser's JSON dump,
            // which must stay valid JSON.
            if status == 0, agent, !arguments.contains("--experimental-dump-help") {
                message = agentAlert + message
            }
            return (message, status)
        }
    }

    private static func humanDescription(_ error: CLIError, _ context: CLIContext) -> String {
        switch error {
        case .appNotInstalled:
            "The sidebar app is not installed. Build and launch it once with `just run`."
        case .appDidNotStart:
            "The sidebar app did not start in time. Launch it and try again."
        case .rejected(let message):
            "The sidebar refused the notification: \(message)."
        case .unreachable(_, let reason):
            "Cannot reach the sidebar app: \(reason)."
        }
    }

    private static func agentDescription(_ error: CLIError, _ context: CLIContext) -> String {
        switch error {
        case .appNotInstalled:
            "app_not_installed: no app registered for bundle id com.alexgorbatchev.aerospace-sidebar"
        case .appDidNotStart(let path):
            "app_did_not_start: no listener on \(context.displayPath(path)) after launch"
        case .rejected(let message):
            "rejected: \(message)"
        case .unreachable(let path, let reason):
            "unreachable: \(context.displayPath(path)): \(reason)"
        }
    }
}
