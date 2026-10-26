import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

struct ControlServerTests {
    static func socketPath() -> String { "/tmp/as-server-\(UUID().uuidString.prefix(8)).sock" }

    @Test func handsRequestsToMainActorHandler() async throws {
        let path = Self.socketPath()
        let received = Received()
        let server = ControlServer(path: path) { request in
            received.requests.append(request)
            return ControlResponse(error: nil)
        }
        try server.start()
        defer { server.stop() }
        let payload = try NotificationPayload(title: "hi")

        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(response == ControlResponse(error: nil))
        #expect(await received.requests == [.pushNotification(payload)])
    }

    @Test func repliesWithErrorForInvalidRequests() async throws {
        let path = Self.socketPath()
        let server = ControlServer(path: path) { _ in ControlResponse(error: nil) }
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
        let first = ControlServer(path: path) { _ in ControlResponse(error: nil) }
        try first.start()
        defer { first.stop() }

        #expect(throws: ControlServer.StartError.alreadyRunning(path: path)) {
            try ControlServer(path: path) { _ in ControlResponse(error: nil) }.start()
        }
    }

    @Test func stopRemovesSocketAndIsIdempotent() throws {
        let path = Self.socketPath()
        let server = ControlServer(path: path) { _ in ControlResponse(error: nil) }
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
