import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

struct ControlServerTests {
    static func socketPath() -> String { "/tmp/as-server-\(UUID().uuidString.prefix(8)).sock" }

    @Test func handsRequestsToMainActorHandler() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.requests.append($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "hi")

        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(response == ControlResponse(error: nil))
        #expect(await received.requests == [.pushNotification(payload)])
    }

    /// The main actor can be busy for longer than a client waits, such as while NotificationCenter is slow to
    /// answer after a wake. The reply does not wait for it, so the client never reports a failure for, or
    /// sends again, a notification the app goes on to show.
    @MainActor
    @Test func confirmsRequestsWhileTheMainActorIsBusy() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { received.requests.append($0) }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "busy")

        // Blocking on the main thread keeps the main actor busy until the reply arrives or the read times out.
        let descriptor = try UnixSocket.connect(to: path, timeout: timeval(tv_sec: 1, tv_usec: 0))
        defer { close(descriptor) }
        try UnixSocket.writeAll(JSONEncoder().encode(ControlRequest.pushNotification(payload)), to: descriptor)
        shutdown(descriptor, SHUT_WR)
        let response = try JSONDecoder().decode(ControlResponse.self, from: UnixSocket.readAll(from: descriptor))

        #expect(response == ControlResponse(error: nil))
        #expect(received.requests.isEmpty)
        for _ in 0..<1000 where received.requests.isEmpty { await Task.yield() }
        #expect(received.requests == [.pushNotification(payload)])
    }

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
            return try JSONDecoder().decode(ControlResponse.self, from: UnixSocket.readAll(from: descriptor))
        }

        #expect(response.error?.hasPrefix("invalid request") == true)
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

        server.stop()
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@MainActor
final class Received {
    var requests: [ControlRequest] = []
}
