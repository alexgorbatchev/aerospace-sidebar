import Foundation
@testable import SidebarCLI
import SidebarProtocol
import Testing

struct SocketNotificationSenderTests {
    static func socketPath() -> String { "/tmp/as-cli-\(UUID().uuidString.prefix(8)).sock" }

    /// Answers one request on `path` with `response`, returning the request it received.
    static func serveOnce(at path: String, response: ControlResponse) throws -> Task<ControlRequest, any Error> {
        let listener = try UnixSocket.listen(on: path)
        return Task {
            try await onBlockingQueue {
                defer { close(listener); unlink(path) }
                let connection = accept(listener, nil, nil)
                defer { close(connection) }
                let request = try JSONDecoder().decode(ControlRequest.self, from: UnixSocket.readAll(from: connection))
                try UnixSocket.writeAll(JSONEncoder().encode(response), to: connection)
                return request
            }
        }
    }

    @Test func deliversToRunningApp() async throws {
        let path = Self.socketPath()
        let server = try Self.serveOnce(at: path, response: ControlResponse(error: nil))
        let payload = try NotificationPayload(title: "hi")

        try await SocketNotificationSender(socketPath: path, launchApp: { Issue.record("launched") }).push(payload)

        #expect(try await server.value == .pushNotification(payload))
    }

    @Test func launchesAppWhenNothingListens() async throws {
        let path = Self.socketPath()
        let launched = LockedBox<Task<ControlRequest, any Error>?>(nil)
        let sender = SocketNotificationSender(socketPath: path, launchApp: {
            launched.value = try Self.serveOnce(at: path, response: ControlResponse(error: nil))
        }, retryDelay: .milliseconds(10))

        try await sender.push(NotificationPayload(title: "wake"))

        #expect(try await launched.value?.value == .pushNotification(NotificationPayload(title: "wake")))
    }

    @Test func reportsAppThatNeverListens() async throws {
        let path = Self.socketPath()
        let sender = SocketNotificationSender(socketPath: path, launchApp: {}, retryDelay: .milliseconds(1), attempts: 3)

        await #expect(throws: CLIError.appDidNotStart(socketPath: path)) {
            try await sender.push(NotificationPayload(title: "t"))
        }
    }

    @Test func reportsRejection() async throws {
        let path = Self.socketPath()
        _ = try Self.serveOnce(at: path, response: ControlResponse(error: "nope"))

        await #expect(throws: CLIError.rejected("nope")) {
            try await SocketNotificationSender(socketPath: path, launchApp: {}).push(NotificationPayload(title: "t"))
        }
    }

    @Test func reportsOtherSocketFailures() async throws {
        let path = "/tmp/" + String(repeating: "x", count: 200)

        await #expect(throws: CLIError.unreachable(socketPath: path, reason: "socket path failed: File name too long")) {
            try await SocketNotificationSender(socketPath: path, launchApp: {}).push(NotificationPayload(title: "t"))
        }
    }

    @Test func propagatesLaunchFailure() async throws {
        await #expect(throws: CLIError.appNotInstalled) {
            try await SocketNotificationSender(socketPath: Self.socketPath(), launchApp: { throw CLIError.appNotInstalled })
                .push(NotificationPayload(title: "t"))
        }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
