import Foundation

/// A request sent over the control socket: one JSON message per connection (see `UnixSocket.writeMessage`).
public enum ControlRequest: Codable, Equatable, Sendable {
    case pushNotification(NotificationPayload)
    /// Shows a notification whose choices answer the client, which keeps the connection open after the
    /// `ControlResponse` and reads an `AskAnswer` from it. Closing the connection withdraws the notification.
    case askNotification(NotificationPayload)

    /// - Throws: `SidebarRequestError.answerOutsideAsk` for a push with a choice that answers an ask,
    ///   `.askNeedsAnswers` for an ask without choices or with one that does not answer it, and `.keyOnAsk` for an
    ///   ask with a key.
    public func validate() throws(SidebarRequestError) {
        switch self {
        case .pushNotification(let payload):
            guard !payload.asks else { throw .answerOutsideAsk }
        case .askNotification(let payload):
            guard !payload.choices.isEmpty, payload.choices.allSatisfy({ $0.action == .answer }) else {
                throw .askNeedsAnswers
            }
            guard payload.key == nil else { throw .keyOnAsk }
        }
    }
}

/// The reply to a `ControlRequest`; `error` is nil on success.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let error: String?

    public init(error: String?) {
        self.error = error
    }
}

/// What became of an asked notification: the second message on its connection, after the `ControlResponse`.
public enum AskAnswer: Codable, Equatable, Sendable {
    /// The user chose `choice`; `reply` is the text sent with a choice that asks for it.
    case answered(choice: String, reply: String?)
    /// The card went without an answer: dismissed, cleared, expired, dropped for the history limits, or hidden
    /// by a rule.
    case dismissed
}

/// Why waiting for an `AskAnswer` ended without one.
public enum AnswerError: Error, Equatable, Sendable {
    /// No answer came within the time given.
    case timedOut
    /// The connection closed or failed first, such as when the app quit; the detail says how.
    case noAnswer(String)
}

/// Why `UnixSocket.exchange` failed, by how far the request got. Only a request that never reached the
/// server may be sent again: once it has been sent in full, the server may have handled it.
public enum ExchangeError: Error, Equatable, Sendable {
    /// The encoded request is larger than the server reads (`UnixSocket.maxMessageSize`); nothing was sent.
    case tooLarge(size: Int)
    /// Connecting failed, so nothing was sent.
    case notConnected(SocketError)
    /// Sending failed partway, so the server never read the whole request.
    case notSent(SocketError)
    /// The whole request was sent but no reply came back, such as when the server did not answer in time.
    case noReply(String)

    /// Nothing listens on the path: no socket file (`ENOENT`), or one with no listener behind it (`ECONNREFUSED`),
    /// as when the app is not running.
    public var meansNoListener: Bool {
        guard case .notConnected(let error) = self else { return false }
        return [ENOENT, ECONNREFUSED].contains(error.code)
    }
}

public struct SocketError: Error, Equatable, Sendable, CustomStringConvertible {
    public let operation: String
    public let code: Int32

    public init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

/// Blocking Unix domain stream socket helpers shared by the app and the CLI.
public enum UnixSocket {
    /// Largest request or response either side accepts.
    public static let maxMessageSize = 64 * 1024
    /// How long a client waits on a send or reply before giving up.
    public static let clientTimeout = timeval(tv_sec: 5, tv_usec: 0)

    /// Connects to `path`; sends and reads time out after `timeout`.
    public static func connect(to path: String, timeout: timeval = clientTimeout) throws(SocketError) -> Int32 {
        var address = try address(for: path)
        let descriptor = try makeSocket()
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = SocketError("connect", code: errno)
            close(descriptor)
            throw error
        }
        var timeout = timeout
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    /// Binds and listens on `path`, replacing a stale socket file. Only the owner can connect.
    public static func listen(on path: String) throws(SocketError) -> Int32 {
        var address = try address(for: path)
        unlink(path)
        let descriptor = try makeSocket()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 16) == 0 else {
            let error = SocketError("listen", code: errno)
            close(descriptor)
            throw error
        }
        return descriptor
    }

    public static func writeAll(_ data: Data, to descriptor: Int32) throws(SocketError) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes {
                write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard written > 0 else { throw SocketError("write", code: errno) }
            offset += written
        }
    }

    /// Writes one message (`message(_:)`).
    public static func writeMessage(_ data: Data, to descriptor: Int32) throws(SocketError) {
        try writeAll(message(data), to: descriptor)
    }

    /// The bytes of one message: `data`, which must hold no newline (compact JSON has none), and a newline.
    public static func message(_ data: Data) -> Data {
        data + [newline]
    }

    static let newline = UInt8(ascii: "\n")

    /// Sends one request and waits for the reply, on a Dispatch thread (see `onBlockingQueue`).
    /// - Throws: `ExchangeError`, which tells whether the server may have received the request.
    public static func exchange(
        _ request: ControlRequest,
        path: String,
        timeout: timeval = clientTimeout
    ) async throws -> ControlResponse {
        try await send(request, path: path, timeout: timeout).response
    }

    /// Sends one request and reads the reply, on a Dispatch thread, keeping the connection open for the answer
    /// an ask request waits for (`ControlConnection.answer(within:)`).
    /// - Throws: `ExchangeError`, which tells whether the server may have received the request.
    public static func send(
        _ request: ControlRequest,
        path: String,
        timeout: timeval = clientTimeout
    ) async throws -> ControlConnection {
        let data = try JSONEncoder().encode(request)
        guard data.count <= maxMessageSize else { throw ExchangeError.tooLarge(size: data.count) }
        return try await onBlockingQueue {
            let descriptor: Int32
            do throws(SocketError) {
                descriptor = try connect(to: path, timeout: timeout)
            } catch {
                throw ExchangeError.notConnected(error)
            }
            do throws(SocketError) {
                try writeMessage(data, to: descriptor)
            } catch {
                close(descriptor)
                throw ExchangeError.notSent(error)
            }
            var reader = MessageReader(descriptor: descriptor)
            do {
                guard let reply = try reader.next() else { throw SocketError("read", code: ECONNRESET) }
                let response = try JSONDecoder().decode(ControlResponse.self, from: reply)
                return ControlConnection(descriptor: descriptor, reader: reader, response: response)
            } catch {
                close(descriptor)
                throw ExchangeError.noReply(String(describing: error))
            }
        }
    }

    /// Sets how long each read on `descriptor` may wait; nil waits as long as it takes.
    static func setReceiveTimeout(_ timeout: Duration?, on descriptor: Int32) {
        var value = timeval(tv_sec: 0, tv_usec: 0)
        if let timeout {
            let (seconds, attoseconds) = timeout.components
            // A zero timeval waits forever, so the shortest wait is a microsecond.
            value = timeval(tv_sec: Int(seconds), tv_usec: Int32(max(attoseconds / 1_000_000_000_000, seconds == 0 ? 1 : 0)))
        }
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func makeSocket() throws(SocketError) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError("socket", code: errno) }
        disableSIGPIPE(descriptor)
        return descriptor
    }

    /// Makes writes to a closed peer fail with `EPIPE` instead of killing the process with SIGPIPE.
    public static func disableSIGPIPE(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func address(for path: String) throws(SocketError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError("socket path", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}

/// Reads newline-terminated messages (`UnixSocket.writeMessage`) from a socket, keeping what it read past the
/// end of one message for the next.
public struct MessageReader: Sendable {
    public let descriptor: Int32
    private var buffer = Data()

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The next message, without its newline. At the end of the stream it is what is left, or nil when nothing
    /// is, so a peer may also end its last message by closing its write side.
    /// - Parameter deadline: When reading gives up with `ETIMEDOUT`; nil keeps the socket's receive timeout,
    ///   which ends a read with `EAGAIN`.
    /// - Throws: `SocketError`, with `EMSGSIZE` for a message longer than `UnixSocket.maxMessageSize`.
    public mutating func next(deadline: ContinuousClock.Instant? = nil) throws(SocketError) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            // The limit applies to the message, not to what one read brought, which can run past its end.
            let end = buffer.prefix(UnixSocket.maxMessageSize + 1).firstIndex(of: UnixSocket.newline)
            if let end {
                let message = buffer[buffer.startIndex..<end]
                buffer = Data(buffer[buffer.index(after: end)...])
                return Data(message)
            }
            guard buffer.count <= UnixSocket.maxMessageSize else { throw SocketError("read", code: EMSGSIZE) }
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { throw SocketError("read", code: ETIMEDOUT) }
                UnixSocket.setReceiveTimeout(remaining, on: descriptor)
            }
            let count = read(descriptor, &chunk, chunk.count)
            guard count >= 0 else { throw SocketError("read", code: errno) }
            guard count > 0 else {
                defer { buffer = Data() }
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}

/// A connection to the control socket that sent a request and read its reply; closed when released.
public final class ControlConnection: @unchecked Sendable {
    /// The server's reply to the request.
    public let response: ControlResponse
    private let descriptor: Int32
    /// Only `answer(within:)` reads it, once.
    private var reader: MessageReader

    init(descriptor: Int32, reader: MessageReader, response: ControlResponse) {
        self.descriptor = descriptor
        self.reader = reader
        self.response = response
    }

    deinit {
        close(descriptor)
    }

    /// Waits on a Dispatch thread for the answer to an ask request, for at most `timeout` (nil waits as long as
    /// it takes). Closing the connection afterwards, as releasing it does, withdraws a notification still waiting.
    /// - Throws: `AnswerError`.
    public func answer(within timeout: Duration?) async throws -> AskAnswer {
        try await onBlockingQueue { [self] in
            do {
                UnixSocket.setReceiveTimeout(nil, on: descriptor)
                guard let message = try reader.next(deadline: timeout.map { ContinuousClock.now.advanced(by: $0) }) else {
                    throw AnswerError.noAnswer("the sidebar closed the connection")
                }
                return try JSONDecoder().decode(AskAnswer.self, from: message)
            } catch let error as SocketError where [ETIMEDOUT, EAGAIN].contains(error.code) {
                throw AnswerError.timedOut
            } catch let error as AnswerError {
                throw error
            } catch {
                throw AnswerError.noAnswer(String(describing: error))
            }
        }
    }
}
