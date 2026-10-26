import Foundation

/// A request sent over the control socket: one JSON document per connection.
public enum ControlRequest: Codable, Equatable, Sendable {
    case pushNotification(NotificationPayload)
}

/// The reply to a `ControlRequest`; `error` is nil on success.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let error: String?

    public init(error: String?) {
        self.error = error
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

    /// Reads until the peer closes its write side.
    public static func readAll(from descriptor: Int32) throws(SocketError) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw SocketError("read", code: errno) }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= maxMessageSize else { throw SocketError("read", code: EMSGSIZE) }
        }
    }

    /// Sends one request and waits for the reply, on a Dispatch thread (see `onBlockingQueue`).
    public static func exchange(
        _ request: ControlRequest,
        path: String,
        timeout: timeval = clientTimeout
    ) async throws -> ControlResponse {
        try await onBlockingQueue {
            let descriptor = try connect(to: path, timeout: timeout)
            defer { close(descriptor) }
            try writeAll(JSONEncoder().encode(request), to: descriptor)
            shutdown(descriptor, SHUT_WR)
            return try JSONDecoder().decode(ControlResponse.self, from: readAll(from: descriptor))
        }
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
