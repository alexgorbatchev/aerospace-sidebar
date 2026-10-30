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
            let request = try JSONDecoder().decode(ControlRequest.self, from: readMessage(from: connection))
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

    @Test func readerRejectsOversizedMessages() async throws {
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
                return try readMessage(from: reader)
            }
        }
        await written
    }

    /// The limit is on the message, wherever its newline falls in what one read brought.
    @Test(arguments: [UnixSocket.maxMessageSize, UnixSocket.maxMessageSize + 1])
    func readerLimitsTheMessageItself(size: Int) async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        descriptors.forEach(UnixSocket.disableSIGPIPE)
        let (reader, writer) = (descriptors[0], descriptors[1])
        async let written: Void = onBlockingQueue {
            defer { close(writer) }
            try? UnixSocket.writeMessage(Data(repeating: UInt8(ascii: "a"), count: size), to: writer)
        }

        let read: Result<Data, SocketError>
        do {
            read = .success(try await onBlockingQueue {
                defer { close(reader) }
                return try readMessage(from: reader)
            })
        } catch let error as SocketError {
            read = .failure(error)
        }
        await written

        if size > UnixSocket.maxMessageSize {
            #expect(throws: SocketError("read", code: EMSGSIZE)) { try read.get() }
        } else {
            #expect(try read.get().count == size)
        }
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
        #expect(throws: SocketError("read", code: EBADF)) { try readMessage(from: -1) }
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

    /// Messages end at a newline, so one read may hold several; what is left when the stream ends is the last.
    @Test func readerSplitsMessagesAtNewlines() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[0]) }
        try UnixSocket.writeMessage(Data("one".utf8), to: descriptors[1])
        try UnixSocket.writeAll(Data("two\nthree".utf8), to: descriptors[1])
        close(descriptors[1])
        var reader = MessageReader(descriptor: descriptors[0])

        #expect(try reader.next() == Data("one".utf8))
        #expect(try reader.next() == Data("two".utf8))
        #expect(try reader.next() == Data("three".utf8))
        #expect(try reader.next() == nil)
    }

    @Test func readerGivesUpAtItsDeadline() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        var reader = MessageReader(descriptor: descriptors[0])

        #expect(throws: SocketError("read", code: EAGAIN)) { try reader.next(deadline: .now + .milliseconds(50)) }
        #expect(throws: SocketError("read", code: ETIMEDOUT)) { try reader.next(deadline: .now - .seconds(1)) }
    }

    /// After confirming an ask, the server answers on the same connection.
    @Test func readsTheAnswerAfterTheReply() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Reply", action: .answer, asksForText: true)])

        async let served: Void = onBlockingQueue {
            let connection = accept(listener, nil, nil)
            defer { close(connection) }
            _ = try readMessage(from: connection)
            try UnixSocket.writeMessage(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
            try UnixSocket.writeMessage(JSONEncoder().encode(AskAnswer.answered(choice: "Reply", reply: "on my way")), to: connection)
        }
        let connection = try await UnixSocket.send(.askNotification(payload), path: path)
        try await served

        #expect(connection.response == ControlResponse(error: nil))
        #expect(try await connection.answer(within: nil) == .answered(choice: "Reply", reply: "on my way"))
    }

    /// The send timeout bounds sending the request and reading its reply, not the wait for the answer, which
    /// without a timeout of its own lasts as long as it takes.
    @Test func answerWithoutTimeoutOutlastsTheSendTimeout() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        let payload = try NotificationPayload(title: "t", choices: [PushedChoice(title: "Yes", action: .answer)])

        // Served from a Dispatch thread started before the client connects, so that a busy cooperative pool cannot
        // delay the reply past the client's short timeout.
        let served = DispatchGroup()
        DispatchQueue.global().async(group: served) {
            let connection = accept(listener, nil, nil)
            defer { close(connection) }
            _ = try? readMessage(from: connection)
            try? UnixSocket.writeMessage(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
            usleep(1_000_000)
            try? UnixSocket.writeMessage(JSONEncoder().encode(AskAnswer.answered(choice: "Yes", reply: nil)), to: connection)
        }
        let connection = try await UnixSocket.send(.askNotification(payload), path: path, timeout: timeval(tv_sec: 0, tv_usec: 500_000))

        #expect(try await connection.answer(within: nil) == .answered(choice: "Yes", reply: nil))
        await onBlockingQueue { served.wait() }
    }

    @Test func answerWaitsAtMostItsTimeoutAndReportsClosedConnections() async throws {
        let path = Self.temporarySocketPath()
        let listener = try UnixSocket.listen(on: path)
        defer { close(listener); unlink(path) }
        let request = ControlRequest.askNotification(try NotificationPayload(title: "t", choices: [PushedChoice(title: "Yes", action: .answer)]))
        func serve(then finish: @escaping @Sendable (Int32) throws -> Void) async throws -> ControlConnection {
            async let served: Void = onBlockingQueue {
                let connection = accept(listener, nil, nil)
                _ = try readMessage(from: connection)
                try UnixSocket.writeMessage(JSONEncoder().encode(ControlResponse(error: nil)), to: connection)
                try finish(connection)
            }
            let connection = try await UnixSocket.send(request, path: path)
            try await served
            return connection
        }

        let open = Mutable<Int32>(-1)
        let waiting = try await serve { open.value = $0 }
        await #expect(throws: AnswerError.timedOut) { try await waiting.answer(within: .milliseconds(100)) }
        close(open.value)

        let closed = try await serve { close($0) }
        await #expect(throws: AnswerError.noAnswer("the sidebar closed the connection")) { try await closed.answer(within: .seconds(5)) }

        let garbled = try await serve { connection in
            try UnixSocket.writeMessage(Data("{}".utf8), to: connection)
            close(connection)
        }
        let error = await #expect(throws: AnswerError.self) { try await garbled.answer(within: .seconds(5)) }
        guard case .noAnswer = error else {
            Issue.record("expected noAnswer, got \(String(describing: error))")
            return
        }
    }

    @Test func describesErrorWithStrerror() {
        #expect(SocketError("connect", code: ECONNREFUSED).description == "connect failed: Connection refused")
    }

    static func temporarySocketPath() -> String {
        "/tmp/as-test-\(UUID().uuidString.prefix(8)).sock"
    }
}

/// Reads one message from `descriptor`; empty when the stream ended without one.
func readMessage(from descriptor: Int32) throws(SocketError) -> Data {
    var reader = MessageReader(descriptor: descriptor)
    return try reader.next() ?? Data()
}

/// A value shared with a closure that runs on another thread.
final class Mutable<Value: Sendable>: @unchecked Sendable {
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
