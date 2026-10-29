import AppKit
import SidebarProtocol

public enum CLIError: Error, Equatable {
    case appNotInstalled
    case appDidNotStart(socketPath: String)
    case launchFailed(String)
    /// The request was sent in full but not confirmed, so the sidebar may still show it.
    case noReply(String)
    case rejected(String)
    /// The encoded request is larger than the control socket accepts.
    case tooLarge(size: Int)
    case unreachable(socketPath: String, reason: String)
}

/// Pushes notifications over the control socket, launching the app when it is not running.
///
/// A request is sent again only while nothing listens on the socket. Once it has been sent in full the app may
/// have it, so a missing reply is reported (`CLIError.noReply`) rather than retried, which could list it twice.
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
        let request = ControlRequest.pushNotification(payload)
        let response: ControlResponse
        do {
            do {
                response = try await UnixSocket.exchange(request, path: socketPath, timeout: timeout)
            } catch let error as ExchangeError where error.meansNoListener {
                try await launch()
                response = try await exchangeOnceListening(request)
            }
        } catch let error as ExchangeError {
            throw cliError(for: error)
        }
        if let message = response.error {
            throw CLIError.rejected(message)
        }
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
    private func exchangeOnceListening(_ request: ControlRequest) async throws -> ControlResponse {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: launchTimeout)
        repeat {
            try await Task.sleep(for: retryDelay)
            do {
                return try await UnixSocket.exchange(request, path: socketPath, timeout: timeout)
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
