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
                let request = try JSONDecoder().decode(ControlRequest.self, from: readMessage(from: connection))
                try UnixSocket.writeAll(JSONEncoder().encode(response), to: connection)
                return request
            }
        }
    }

    /// Reads one request on `path` and never replies, like an app whose main actor is stuck. The connection stays
    /// open, so the client gives up on its own; the task returns it with the request.
    static func listenWithoutReplying(at path: String) throws -> (listener: Int32, received: Task<(Int32, ControlRequest), any Error>) {
        let listener = try UnixSocket.listen(on: path)
        let received = Task {
            try await onBlockingQueue {
                let connection = accept(listener, nil, nil)
                return (connection, try JSONDecoder().decode(ControlRequest.self, from: readMessage(from: connection)))
            }
        }
        return (listener, received)
    }

    /// Whether a client waits to be accepted on `listener`, such as one sending a request again.
    static func hasPendingConnection(_ listener: Int32) -> Bool {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0
    }

    /// A valid payload whose JSON exceeds `UnixSocket.maxMessageSize`: each control character takes six bytes
    /// escaped (`\u0001`), and combining marks on the last character use the bytes the character count leaves.
    static func oversizedPayload() throws -> NotificationPayload {
        let text = String(repeating: "\u{1}", count: 4095) + "e" + String(repeating: "\u{301}", count: 6000)
        return try NotificationPayload(body: text, action: .run(command: text, workingDirectory: "/"))
    }

    static let shortTimeout = timeval(tv_sec: 0, tv_usec: 200_000)

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
        let sender = SocketNotificationSender(socketPath: path, launchApp: {}, retryDelay: .milliseconds(1), launchTimeout: .milliseconds(30))

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

    /// A socket file nothing listens on, left behind by an app that crashed, means the app is not running.
    @Test func launchesAppBehindAStaleSocketFile() async throws {
        let path = Self.socketPath()
        close(try UnixSocket.listen(on: path))
        let launched = LockedBox<Task<ControlRequest, any Error>?>(nil)
        let sender = SocketNotificationSender(socketPath: path, launchApp: {
            launched.value = try Self.serveOnce(at: path, response: ControlResponse(error: nil))
        }, retryDelay: .milliseconds(10))

        try await sender.push(NotificationPayload(title: "stale"))

        #expect(try await launched.value?.value == .pushNotification(NotificationPayload(title: "stale")))
    }

    @Test func propagatesLaunchFailure() async throws {
        await #expect(throws: CLIError.appNotInstalled) {
            try await SocketNotificationSender(socketPath: Self.socketPath(), launchApp: { throw CLIError.appNotInstalled })
                .push(NotificationPayload(title: "t"))
        }
    }

    /// NSWorkspace's errors, such as an app Gatekeeper refuses, are reported like the CLI's own.
    @Test func reportsWhyTheAppDidNotLaunch() async throws {
        let failure = CocoaError(.fileReadNoSuchFile)

        await #expect(throws: CLIError.launchFailed(failure.localizedDescription)) {
            try await SocketNotificationSender(socketPath: Self.socketPath(), launchApp: { throw failure })
                .push(NotificationPayload(title: "t"))
        }
    }

    /// An app that took the request but did not reply in time may still show it: the request is not sent again,
    /// and the failure says so rather than calling the app unreachable.
    @Test func neverSendsAnUnconfirmedRequestAgain() async throws {
        let path = Self.socketPath()
        let (listener, received) = try Self.listenWithoutReplying(at: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "once")
        let sender = SocketNotificationSender(socketPath: path, launchApp: { Issue.record("launched") }, timeout: Self.shortTimeout)

        await #expect(throws: CLIError.noReply(SocketError("read", code: EAGAIN).description)) {
            try await sender.push(payload)
        }

        let (connection, request) = try await received.value
        close(connection)
        #expect(request == .pushNotification(payload))
        #expect(!Self.hasPendingConnection(listener))
    }

    /// An ask the app did not confirm leaves no card: the CLI closes the connection, which withdraws one the app
    /// shows anyway, so the failure says it can be asked again.
    @Test func reportsUnconfirmedAsksAsSafeToAskAgain() async throws {
        let path = Self.socketPath()
        let (listener, received) = try Self.listenWithoutReplying(at: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "once", choices: [PushedChoice(title: "Yes", action: .answer)])
        let sender = SocketNotificationSender(socketPath: path, launchApp: { Issue.record("launched") }, timeout: Self.shortTimeout)

        await #expect(throws: CLIError.askNotConfirmed(SocketError("read", code: EAGAIN).description)) {
            try await sender.ask(payload, timeout: nil)
        }

        let (connection, request) = try await received.value
        defer { close(connection) }
        #expect(request == .askNotification(payload))
        var byte: UInt8 = 0
        #expect(read(connection, &byte, 1) == 0)
    }

    /// The same holds for an app the CLI launched: only connecting is tried again while it starts.
    @Test func neverSendsAnUnconfirmedRequestAgainAfterLaunching() async throws {
        let path = Self.socketPath()
        let server = LockedBox<(listener: Int32, received: Task<(Int32, ControlRequest), any Error>)?>(nil)
        let payload = try NotificationPayload(title: "once")
        let sender = SocketNotificationSender(socketPath: path, launchApp: {
            server.value = try Self.listenWithoutReplying(at: path)
        }, retryDelay: .milliseconds(10), timeout: Self.shortTimeout)

        await #expect(throws: CLIError.noReply(SocketError("read", code: EAGAIN).description)) {
            try await sender.push(payload)
        }

        let (listener, received) = try #require(server.value)
        defer { close(listener); unlink(path) }
        let (connection, request) = try await received.value
        close(connection)
        #expect(request == .pushNotification(payload))
        #expect(!Self.hasPendingConnection(listener))
    }

    /// Confirms one ask on `path`, then hands its connection to `finish`, which may answer it; returns the request.
    static func serveAsk(at path: String, finish: @escaping @Sendable (Int32) throws -> Void) throws -> Task<ControlRequest, any Error> {
        let listener = try UnixSocket.listen(on: path)
        return Task {
            try await onBlockingQueue {
                defer { close(listener); unlink(path) }
                let connection = accept(listener, nil, nil)
                let request = try JSONDecoder().decode(ControlRequest.self, from: readMessage(from: connection))
                try UnixSocket.writeMessage(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
                try finish(connection)
                return request
            }
        }
    }

    static func askPayload() throws -> NotificationPayload {
        try NotificationPayload(title: "Deploy?", choices: [PushedChoice(title: "Yes", action: .answer)])
    }

    @Test func asksAndReturnsTheAnswer() async throws {
        let path = Self.socketPath()
        let server = try Self.serveAsk(at: path) { connection in
            defer { close(connection) }
            try UnixSocket.writeMessage(JSONEncoder().encode(AskAnswer.answered(choice: "Yes", reply: nil)), to: connection)
        }
        let payload = try Self.askPayload()

        let answer = try await SocketNotificationSender(socketPath: path, launchApp: { Issue.record("launched") }).ask(payload, timeout: nil)

        #expect(answer == .answered(choice: "Yes", reply: nil))
        #expect(try await server.value == .askNotification(payload))
    }

    /// Giving up closes the connection, which tells the app to withdraw the notification.
    @Test func closesTheConnectionWhenTheTimeoutPasses() async throws {
        let path = Self.socketPath()
        let withdrawn = LockedBox(false)
        let server = try Self.serveAsk(at: path) { connection in
            defer { close(connection) }
            var buffer = [UInt8](repeating: 0, count: 16)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            withdrawn.value = read(connection, &buffer, buffer.count) == 0
        }

        await #expect(throws: CLIError.timedOut) {
            try await SocketNotificationSender(socketPath: path, launchApp: {}).ask(Self.askPayload(), timeout: .milliseconds(100))
        }
        _ = try await server.value
        #expect(withdrawn.value)
    }

    @Test func reportsAnAppThatStopsWaitingForTheAnswer() async throws {
        let path = Self.socketPath()
        _ = try Self.serveAsk(at: path) { close($0) }

        await #expect(throws: CLIError.noAnswer("the sidebar closed the connection")) {
            try await SocketNotificationSender(socketPath: path, launchApp: {}).ask(Self.askPayload(), timeout: .seconds(5))
        }
    }

    @Test func reportsRejectedAsks() async throws {
        let path = Self.socketPath()
        _ = try Self.serveOnce(at: path, response: ControlResponse(error: "nope"))

        await #expect(throws: CLIError.rejected("nope")) {
            try await SocketNotificationSender(socketPath: path, launchApp: {}).ask(Self.askPayload(), timeout: nil)
        }
    }

    /// A request larger than the app reads is refused before connecting, not sent and cut off.
    @Test func refusesRequestsTooLargeForTheSocket() async throws {
        let payload = try Self.oversizedPayload()
        let size = try JSONEncoder().encode(ControlRequest.pushNotification(payload)).count

        await #expect(throws: CLIError.tooLarge(size: size)) {
            try await SocketNotificationSender(socketPath: Self.socketPath(), launchApp: { Issue.record("launched") }).push(payload)
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
