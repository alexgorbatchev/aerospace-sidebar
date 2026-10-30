import AppKit
import SidebarProtocol

public enum CLIError: Error, Equatable {
    case appNotInstalled
    case appDidNotStart(socketPath: String)
    case launchFailed(String)
    /// The request was sent in full but not confirmed, so the sidebar may still show it.
    case noReply(String)
    /// An ask was sent in full but not confirmed. Its connection is closed, so the sidebar withdrew its card if it
    /// showed one, and it can be asked again.
    case askNotConfirmed(String)
    case rejected(String)
    /// The encoded request is larger than the control socket accepts.
    case tooLarge(size: Int)
    case unreachable(socketPath: String, reason: String)
    /// An asked notification went without an answer.
    case dismissed
    /// No answer came within `--timeout`; the notification was withdrawn.
    case timedOut
    /// The connection ended before an answer, such as when the app quit.
    case noAnswer(String)

    /// The process exit status: 2 for an ask that got no answer from the user, 1 for every other failure.
    var exitStatus: Int32 {
        switch self {
        case .dismissed, .timedOut: 2
        default: 1
        }
    }
}

/// Pushes notifications over the control socket, launching the app when it is not running.
///
/// A request is sent again only while nothing listens on the socket. Once it has been sent in full the app may
/// have it, so a missing reply is reported (`CLIError.noReply`) rather than retried, which could list it twice.
/// An ask keeps the connection open for the answer; closing it, as a timeout or the process ending does,
/// withdraws the notification.
public struct SocketNotificationSender: NotificationSending {
    let socketPath: String
    let launchApp: @Sendable () async throws -> Void
    let retryDelay: Duration
    /// How long a launched app has to start listening.
    let launchTimeout: Duration
    /// How long sending the request and waiting for its reply may each take.
    let timeout: timeval

    public init(
        socketPath: String = SidebarApp.controlSocketPath,
        launchApp: @escaping @Sendable () async throws -> Void = SocketNotificationSender.launchSidebarApp,
        retryDelay: Duration = .milliseconds(100),
        launchTimeout: Duration = .seconds(5),
        timeout: timeval = UnixSocket.clientTimeout
    ) {
        self.socketPath = socketPath
        self.launchApp = launchApp
        self.retryDelay = retryDelay
        self.launchTimeout = launchTimeout
        self.timeout = timeout
    }

    public func push(_ payload: NotificationPayload) async throws {
        _ = try await send(.pushNotification(payload))
    }

    public func ask(_ payload: NotificationPayload, timeout answerTimeout: Duration?) async throws -> AskAnswer {
        let connection = try await send(.askNotification(payload))
        do {
            return try await connection.answer(within: answerTimeout)
        } catch AnswerError.timedOut {
            throw CLIError.timedOut
        } catch AnswerError.noAnswer(let reason) {
            throw CLIError.noAnswer(reason)
        }
    }

    /// Sends `request`, launching the app first when nothing listens, and returns the connection it was confirmed on.
    private func send(_ request: ControlRequest) async throws -> ControlConnection {
        let connection: ControlConnection
        do {
            do {
                connection = try await UnixSocket.send(request, path: socketPath, timeout: timeout)
            } catch let error as ExchangeError where error.meansNoListener {
                try await launch()
                connection = try await sendOnceListening(request)
            }
        } catch let error as ExchangeError {
            if case .askNotification = request, case .noReply(let reason) = error {
                throw CLIError.askNotConfirmed(reason)
            }
            throw cliError(for: error)
        }
        if let message = connection.response.error {
            throw CLIError.rejected(message)
        }
        return connection
    }

    private func launch() async throws {
        do {
            try await launchApp()
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.launchFailed(error.localizedDescription)
        }
    }

    /// Sends `request` once the launched app listens, trying again only while nothing does.
    private func sendOnceListening(_ request: ControlRequest) async throws -> ControlConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchTimeout)
        repeat {
            try await Task.sleep(for: retryDelay)
            do {
                return try await UnixSocket.send(request, path: socketPath, timeout: timeout)
            } catch let error as ExchangeError where error.meansNoListener {
                continue
            }
        } while clock.now < deadline
        throw CLIError.appDidNotStart(socketPath: socketPath)
    }

    private func cliError(for error: ExchangeError) -> CLIError {
        switch error {
        case .tooLarge(let size): .tooLarge(size: size)
        case .notConnected(let error), .notSent(let error): .unreachable(socketPath: socketPath, reason: error.description)
        case .noReply(let reason): .noReply(reason)
        }
    }

    /// Launches the installed sidebar app in the background.
    @Sendable
    public static func launchSidebarApp() async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SidebarApp.bundleIdentifier) else {
            throw CLIError.appNotInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
