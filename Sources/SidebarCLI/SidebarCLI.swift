import ArgumentParser
import Foundation
import SidebarProtocol

/// Entry point shared by the `aerospace-sidebar` executable and tests.
public enum SidebarCLI {
    static let agentAlert = "ALERT: Agents must read `AGENT=1 aerospace-sidebar skill` before using this tool.\n"

    /// Runs the `aerospace-sidebar` process and returns its exit status.
    ///
    /// Output to a pipe whose reader is gone, such as a consumer that already exited, fails with EPIPE instead of
    /// killing the process with SIGPIPE, so it is reported and exits with EX_IOERR like any failed write. A signal's
    /// disposition belongs to the whole process, so `main(arguments:context:)`, which tests run in their own process,
    /// leaves it alone: ignoring SIGPIPE there would keep the app's tests from noticing a socket without
    /// `SO_NOSIGPIPE`, which kills the app when its peer disconnects early.
    public static func runProcess(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()), context: CLIContext = CLIContext()
    ) async -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        return await main(arguments: arguments, context: context)
    }

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
            return (agent ? "ERR: \(agentDescription(error, context))\n" : "[ERROR] \(humanDescription(error, context))\n", error.exitStatus)
        case let error as OutputWriteError:
            return (agent ? "ERR: output_write_failed: \(error.underlying)\n" : "[ERROR] Cannot write output: \(error.underlying)\n", EX_IOERR)
        case let error as SidebarRequestError:
            return (agent ? "ERR: invalid: \(error)\n" : "[ERROR] \(error)\n", 1)
        default:
            let status = RootCommand.exitCode(for: error).rawValue
            // Agents get failures as one `ERR: <code>: <detail>` line, without the usage block people get.
            if agent, status != 0 {
                let code = status == ExitCode.validationFailure.rawValue ? "usage" : "failed"
                return ("ERR: \(code): \(RootCommand.message(for: error))\n", status)
            }
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
        case .launchFailed(let reason):
            "Cannot launch the sidebar app: \(reason)"
        case .noReply(let reason):
            "The sidebar app did not confirm the notification (\(reason)). It may still show it, so sending it again could list it twice."
        case .askNotConfirmed(let reason):
            "The sidebar app did not confirm the question (\(reason)). It removes a question whose command stopped waiting, so you can ask again."
        case .rejected(let message):
            "The sidebar refused the notification: \(message)."
        case .tooLarge(let size):
            "The notification is too large to send: \(size) bytes encoded, at most \(UnixSocket.maxMessageSize)."
        case .unreachable(_, let reason):
            "Cannot reach the sidebar app: \(reason)."
        case .dismissed:
            "The notification was dismissed without an answer."
        case .timedOut:
            "No answer came in time, so the notification was withdrawn."
        case .noAnswer(let reason):
            "The sidebar app stopped waiting for an answer (\(reason))."
        }
    }

    private static func agentDescription(_ error: CLIError, _ context: CLIContext) -> String {
        switch error {
        case .appNotInstalled:
            "app_not_installed: no app registered for bundle id com.alexgorbatchev.aerospace-sidebar"
        case .appDidNotStart(let path):
            "app_did_not_start: no listener on \(context.displayPath(path)) after launch"
        case .launchFailed(let reason):
            "launch_failed: \(reason)"
        case .noReply(let reason):
            "no_reply: sent but not confirmed (\(reason)); it may still show, do not send it again"
        case .askNotConfirmed(let reason):
            "no_reply: sent but not confirmed (\(reason)); the connection is closed, so no card stays, ask again"
        case .rejected(let message):
            "rejected: \(message)"
        case .tooLarge(let size):
            "too_large: request is \(size) bytes encoded, the socket takes at most \(UnixSocket.maxMessageSize)"
        case .unreachable(let path, let reason):
            "unreachable: \(context.displayPath(path)): \(reason)"
        case .dismissed:
            "dismissed: the card went without an answer"
        case .timedOut:
            "timeout: no answer within --timeout; the card was withdrawn"
        case .noAnswer(let reason):
            "no_answer: the connection ended without an answer (\(reason))"
        }
    }
}
