import Foundation
import SidebarProtocol
import Testing

struct UnixSocketTests {
    @Test func exchangesOneRequestAndReply() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "hello")

        async let served = onBlockingQueue {
            let connection = accept(listener, nil, nil)
            defer { close(connection) }
            let request = try JSONDecoder().decode(ControlRequest.self, from: UnixSocket.readAll(from: connection))
            try UnixSocket.writeAll(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
            return request
        }
        let response = try await UnixSocket.exchange(.pushNotification(payload), path: path)

        #expect(response == ControlResponse(error: nil))
        #expect(try await served == .pushNotification(payload))
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

    @Test func readAllRejectsOversizedMessages() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        descriptors.forEach(UnixSocket.disableSIGPIPE)
        let (reader, writer) = (descriptors[0], descriptors[1])
        async let written: Void = onBlockingQueue {
            defer { close(writer) }
            try? UnixSocket.writeAll(Data(count: UnixSocket.maxMessageSize + 1), to: writer)
        }

        await #expect(throws: SocketError("read", code: EMSGSIZE)) {
            try await onBlockingQueue {
                defer { close(reader) }
                return try UnixSocket.readAll(from: reader)
            }
        }
        await written
    }

    /// The request was sent in full, so the server may have it: the failure is told apart from one before sending.
    @Test func clientGivesUpOnServerThatNeverReplies() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        async let accepted = onBlockingQueue { accept(listener, nil, nil) }

        await #expect(throws: ExchangeError.noReply(SocketError("read", code: EAGAIN).description)) {
            try await UnixSocket.exchange(
                .pushNotification(NotificationPayload(title: "t")),
                path: path,
                timeout: timeval(tv_sec: 0, tv_usec: 200_000)
            )
        }
        close(await accepted)
    }

    /// No socket file, or a stale one nothing listens on, means no server; other connect failures do not.
    @Test func connectFailuresTellWhetherAServerListens() async throws {
        let missing = Self.temporarySocketPath()
        let stale = Self.temporarySocketPath()
        close(try UnixSocket.listen(on: stale))
        defer { unlink(stale) }
        let request = ControlRequest.pushNotification(try NotificationPayload(title: "t"))

        for (path, error) in [
            (missing, SocketError("connect", code: ENOENT)),
            (stale, SocketError("connect", code: ECONNREFUSED)),
        ] {
            await #expect(throws: ExchangeError.notConnected(error)) { try await UnixSocket.exchange(request, path: path) }
        }
        #expect(ExchangeError.notConnected(SocketError("connect", code: ENOENT)).meansNoListener)
        #expect(ExchangeError.notConnected(SocketError("connect", code: ECONNREFUSED)).meansNoListener)
        #expect(!ExchangeError.notConnected(SocketError("socket path", code: ENAMETOOLONG)).meansNoListener)
        #expect(!ExchangeError.notSent(SocketError("write", code: EPIPE)).meansNoListener)
        #expect(!ExchangeError.noReply("late").meansNoListener)
    }

    /// A server that hangs up before reading the whole request never handled it.
    @Test func serverClosingMidRequestMeansNotSent() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        // Larger than the socket buffers hold, so the client is still writing when the server hangs up.
        let request = ControlRequest.pushNotification(try NotificationPayload(body: String(repeating: "\u{1}", count: 4096)))
        async let hungUp: Void = onBlockingQueue { close(accept(listener, nil, nil)) }

        let error = await #expect(throws: ExchangeError.self) { try await UnixSocket.exchange(request, path: path) }
        await hungUp

        guard case .notSent(let socketError) = error else {
            Issue.record("expected notSent, got \(String(describing: error))")
            return
        }
        #expect(socketError.operation == "write")
    }

    /// The server reads at most `maxMessageSize` bytes; a larger request is refused before connecting.
    @Test func refusesRequestsLargerThanTheServerReads() async throws {
        let text = String(repeating: "\u{1}", count: 4095) + "e" + String(repeating: "\u{301}", count: 6000)
        let request = ControlRequest.pushNotification(try NotificationPayload(body: text, action: .run(command: text, workingDirectory: "/")))
        let size = try JSONEncoder().encode(request).count
        #expect(size > UnixSocket.maxMessageSize)

        // Nothing listens on the path, so connecting would fail differently.
        await #expect(throws: ExchangeError.tooLarge(size: size)) {
            try await UnixSocket.exchange(request, path: Self.temporarySocketPath())
        }
    }

    @Test func blockingQueuePropagatesErrors() async {
        await #expect(throws: SocketError("x", code: EIO)) {
            try await onBlockingQueue { () throws -> Int in throw SocketError("x", code: EIO) }
        }
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
