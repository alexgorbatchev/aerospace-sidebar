import AppKit
import SidebarProtocol

public enum CLIError: Error, Equatable {
    case appNotInstalled
    case appDidNotStart(socketPath: String)
    case rejected(String)
    case unreachable(socketPath: String, reason: String)
}

/// Pushes notifications over the control socket, launching the app when it is not running.
public struct SocketNotificationSender: NotificationSending {
    let socketPath: String
    let launchApp: @Sendable () async throws -> Void
    let retryDelay: Duration
    let attempts: Int

    public init(
        socketPath: String = SidebarApp.controlSocketPath,
        launchApp: @escaping @Sendable () async throws -> Void = SocketNotificationSender.launchSidebarApp,
        retryDelay: Duration = .milliseconds(100),
        attempts: Int = 50
    ) {
        self.socketPath = socketPath
        self.launchApp = launchApp
        self.retryDelay = retryDelay
        self.attempts = attempts
    }

    public func push(_ payload: NotificationPayload) async throws {
        let request = ControlRequest.pushNotification(payload)
        var response: ControlResponse
        do {
            response = try await UnixSocket.exchange(request, path: socketPath)
        } catch let error as SocketError where [ENOENT, ECONNREFUSED].contains(error.code) {
            try await launchApp()
            response = try await exchangeOnceListening(request)
        } catch {
            throw CLIError.unreachable(socketPath: socketPath, reason: String(describing: error))
        }
        if let message = response.error {
            throw CLIError.rejected(message)
        }
    }

    private func exchangeOnceListening(_ request: ControlRequest) async throws -> ControlResponse {
        for _ in 0..<attempts {
            try await Task.sleep(for: retryDelay)
            if let response = try? await UnixSocket.exchange(request, path: socketPath) {
                return response
            }
        }
        throw CLIError.appDidNotStart(socketPath: socketPath)
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
