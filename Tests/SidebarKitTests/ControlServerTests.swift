import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

struct ControlServerTests {
    static func socketPath() -> String { "/tmp/as-server-\(UUID().uuidString.prefix(8)).sock" }

    @Test func handsRequestsToMainActorHandler() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "hi")

        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(response == ControlResponse(error: nil))
        #expect(await received.pushes == [payload])
    }

    /// The main actor can be busy for longer than a client waits, such as while NotificationCenter is slow to
    /// answer after a wake. The reply does not wait for it, so the client never reports a failure for, or
    /// sends again, a notification the app goes on to show.
    @MainActor
    @Test func confirmsRequestsWhileTheMainActorIsBusy() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "busy")

        // Blocking on the main thread keeps the main actor busy until the reply arrives or the read times out.
        let descriptor = try UnixSocket.connect(to: path, timeout: timeval(tv_sec: 1, tv_usec: 0))
        defer { close(descriptor) }
        try UnixSocket.writeMessage(JSONEncoder().encode(ControlRequest.pushNotification(payload)), to: descriptor)
        let response = try JSONDecoder().decode(ControlResponse.self, from: readMessage(from: descriptor))

        #expect(response == ControlResponse(error: nil))
        #expect(received.pushes.isEmpty)
        for _ in 0..<1000 where received.pushes.isEmpty { await Task.yield() }
        #expect(received.pushes == [payload])
    }

    /// A request may also end where the client closes its side of the connection.
    @Test func repliesWithErrorForInvalidRequests() async throws {
        let path = Self.socketPath()
        let server = ControlServer(path: path) { _ in }
        try server.start()
        defer { server.stop() }

        let response = try await onBlockingQueue {
            let descriptor = try UnixSocket.connect(to: path)
            defer { close(descriptor) }
            try UnixSocket.writeAll(Data("not json".utf8), to: descriptor)
            shutdown(descriptor, SHUT_WR)
            return try JSONDecoder().decode(ControlResponse.self, from: readMessage(from: descriptor))
        }

        #expect(response.error?.hasPrefix("invalid request") == true)
    }

    /// Only an ask's choices answer it, and an ask needs one: the server refuses requests that mix them up.
    @Test func refusesRequestsWhoseChoicesDoNotFitThem() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let answering = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Yes", action: .answer)])
        let linking = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Docs", action: .open(URL(string: "https://a.example")!))])

        for (request, error) in [
            (ControlRequest.pushNotification(answering), SidebarRequestError.answerOutsideAsk),
            (.askNotification(linking), .askNeedsAnswers),
            (.askNotification(try NotificationPayload(title: "t")), .askNeedsAnswers),
        ] {
            let response = try await UnixSocket.exchange(request, path: path)
            #expect(response.error == "invalid request: \(error)")
        }
        #expect(await received.pushes.isEmpty)
        #expect(await received.asks.isEmpty)
    }

    /// An ask is confirmed like a push, then its connection waits for the answer the main actor sends.
    @MainActor
    @Test func answersAskOnItsConnection() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "Deploy?", choices: [PushedChoice(title: "Yes", action: .answer)])

        let connection = try await UnixSocket.send(.askNotification(payload), path: path)
        let (asked, asker) = try await received.waitForAsk()
        asker.answer(.answered(choice: "Yes", reply: nil))
        asker.answer(.dismissed)

        #expect(connection.response == ControlResponse(error: nil))
        #expect(asked == payload)
        #expect(try await connection.answer(within: .seconds(5)) == .answered(choice: "Yes", reply: nil))
    }

    /// A client that stops waiting, such as one whose timeout passed, closes its connection; the server notices
    /// and calls the hang-up handler, also one set only afterwards.
    @MainActor
    @Test func reportsAskersThatHangUp() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Yes", action: .answer)])
        let hungUp = Mutable(0)

        var connection: ControlConnection? = try await UnixSocket.send(.askNotification(payload), path: path)
        let (_, asker) = try await received.waitForAsk()
        asker.onHangUp { hungUp.value += 1 }
        _ = connection
        connection = nil
        try await waitUntil { hungUp.value == 1 }
        asker.onHangUp { hungUp.value += 1 }
        try await waitUntil { hungUp.value == 2 }
    }

    /// The answer is written as the client reads it. A client that stops reading, such as a command suspended
    /// with Ctrl-Z, holds up only its own answer, which can be larger than the socket buffers; the server goes on
    /// confirming other requests, and the answer arrives whole once the client reads it.
    @MainActor
    @Test func answersAClientDoesNotReadHoldUpNoOtherRequest() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Reply", action: .answer, asksForText: true)])
        let reply = String(repeating: "😀", count: PushedChoice.maxReplyLength)
        #expect(PushedChoice.fits(reply: reply))

        let connection = try await UnixSocket.send(.askNotification(payload), path: path)
        let (_, asker) = try await received.waitForAsk()
        asker.answer(.answered(choice: "Reply", reply: reply))
        let next = try NotificationPayload(title: "next")
        let response = try await UnixSocket.exchange(.pushNotification(next), path: path, timeout: timeval(tv_sec: 2, tv_usec: 0))

        #expect(response == ControlResponse(error: nil))
        try await waitUntil { received.pushes == [next] }
        #expect(try await connection.answer(within: .seconds(5)) == .answered(choice: "Reply", reply: reply))
    }

    /// A client that closes before the server replies makes the reply fail with `EPIPE` rather than end the app
    /// with SIGPIPE (`SO_NOSIGPIPE`, which accepted connections also inherit from the listener), and the server
    /// goes on serving. It runs in a process of its own, where SIGPIPE kills only that process.
    @Test func survivesClientsThatCloseBeforeTheReply() async {
        // The exit-test child is spawned directly by this process. Keep ownership in the parent,
        // whose cleanup still runs if the child dies from SIGPIPE or exits before its defer.
        let path = "/tmp/as-server-sigpipe-\(getpid()).sock"
        defer { unlink(path) }
        await #expect(processExitsWith: .success) {
            signal(SIGPIPE, SIG_DFL)
            let path = "/tmp/as-server-sigpipe-\(getppid()).sock"
            let server = ControlServer(path: path) { _ in }
            try server.start()
            defer { server.stop() }

            // The server reads until the end of the stream, so it replies only after the client closed.
            _ = try await onBlockingQueue { close(try UnixSocket.connect(to: path)) }
            let response = try await UnixSocket.exchange(.pushNotification(NotificationPayload(title: "next")), path: path)

            guard response == ControlResponse(error: nil) else { exit(EXIT_FAILURE) }
        }

    }

    /// Stopping closes the connections of asks still waiting; their clients read no answer.
    @MainActor
    @Test func stopClosesWaitingAsks() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.record($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Yes", action: .answer)])

        let connection = try await UnixSocket.send(.askNotification(payload), path: path)
        _ = try await received.waitForAsk()
        server.stop()

        await #expect(throws: AnswerError.noAnswer("the sidebar closed the connection")) {
            try await connection.answer(within: .seconds(5))
        }
    }

    @Test func refusesToStartWhileAnotherServerListens() throws {
        let path = Self.socketPath()
        let first = ControlServer(path: path) { _ in }
        try first.start()
        defer { first.stop() }

        #expect(throws: ControlServer.StartError.alreadyRunning(path: path)) {
            try ControlServer(path: path) { _ in }.start()
        }
    }

    @Test func stopRemovesSocketAndIsIdempotent() throws {
        let path = Self.socketPath()
        let server = ControlServer(path: path) { _ in }
        try server.start()
        defer { server.stop() }

        server.stop()
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

/// Reads one message from `descriptor`; empty when the stream ended without one.
func readMessage(from descriptor: Int32) throws(SocketError) -> Data {
    var reader = MessageReader(descriptor: descriptor)
    return try reader.next() ?? Data()
}

/// Polls `condition` on the main actor for up to five seconds.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<500 where !(await condition()) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await condition())
}

@MainActor
final class Received {
    var pushes: [NotificationPayload] = []
    var asks: [(NotificationPayload, AskConnection)] = []

    func record(_ request: ControlServer.Request) {
        switch request {
        case .push(let payload): pushes.append(payload)
        case .ask(let payload, let asker): asks.append((payload, asker))
        }
    }

    func waitForAsk() async throws -> (NotificationPayload, AskConnection) {
        try await waitUntil { !self.asks.isEmpty }
        return try #require(asks.first)
    }
}
