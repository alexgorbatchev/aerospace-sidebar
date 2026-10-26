import Foundation
import SidebarProtocol
import Testing

struct UnixSocketTests {
    @Test func exchangesOneRequestAndReply() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "hello")

        let server = Task.detached {
            let connection = accept(listener, nil, nil)
            defer { close(connection) }
            let request = try JSONDecoder().decode(ControlRequest.self, from: UnixSocket.readAll(from: connection))
            try UnixSocket.writeAll(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
            return request
        }
        let response = try UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(response == ControlResponse(error: nil))
        #expect(try await server.value == .pushNotification(payload))
    }

    @Test func socketFileIsOwnerOnly() throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }

        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int

        #expect(permissions == 0o600)
    }

    @Test func connectingWithoutListenerFails() {
        #expect(throws: SocketError("connect", code: ENOENT)) {
            try UnixSocket.connect(to: Self.temporarySocketPath())
        }
    }

    @Test func rejectsPathsLongerThanSockaddr() {
        let path = "/tmp/" + String(repeating: "x", count: 200)

        #expect(throws: SocketError("socket path", code: ENAMETOOLONG)) { try UnixSocket.connect(to: path) }
        #expect(throws: SocketError("socket path", code: ENAMETOOLONG)) { try UnixSocket.listen(on: path) }
    }

    @Test func listeningOnUnwritableDirectoryFails() {
        #expect(throws: SocketError.self) { try UnixSocket.listen(on: "/nonexistent-dir/x.sock") }
    }

    @Test func readAllRejectsOversizedMessages() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        descriptors.forEach(UnixSocket.disableSIGPIPE)
        defer { close(descriptors[0]) }
        let writer = Task.detached { [descriptors] in
            defer { close(descriptors[1]) }
            try? UnixSocket.writeAll(Data(count: UnixSocket.maxMessageSize + 1), to: descriptors[1])
        }

        #expect(throws: SocketError("read", code: EMSGSIZE)) { try UnixSocket.readAll(from: descriptors[0]) }
        writer.cancel()
    }

    @Test func writeAndReadReportClosedDescriptors() {
        #expect(throws: SocketError("write", code: EBADF)) { try UnixSocket.writeAll(Data([1]), to: -1) }
        #expect(throws: SocketError("read", code: EBADF)) { try UnixSocket.readAll(from: -1) }
    }

    @Test func writingToClosedPeerFailsInsteadOfKillingProcess() {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        UnixSocket.disableSIGPIPE(descriptors[1])
        close(descriptors[0])
        defer { close(descriptors[1]) }

        // The first writes may still land in the socket buffer; the error surfaces once the kernel notices.
        #expect(throws: SocketError("write", code: EPIPE)) {
            for _ in 0..<100 {
                try UnixSocket.writeAll(Data(count: 4096), to: descriptors[1])
            }
        }
    }

    @Test func describesErrorWithStrerror() {
        #expect(SocketError("connect", code: ECONNREFUSED).description == "connect failed: Connection refused")
    }

    static func temporarySocketPath() -> String {
        "/tmp/as-test-\(UUID().uuidString.prefix(8)).sock"
    }
}
