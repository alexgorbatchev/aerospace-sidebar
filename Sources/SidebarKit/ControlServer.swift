import Foundation
import os
import SidebarProtocol

/// Serves `ControlRequest`s on the Unix control socket.
///
/// Only processes of the same user can connect: the socket file is mode 0600 inside the per-user
/// temporary directory, and each peer's uid is checked with `getpeereid`. This is the only way to
/// push notifications that run commands on click.
public final class ControlServer: Sendable {
    public enum StartError: Error, Equatable {
        case alreadyRunning(path: String)
    }

    private static let logger = Logger(subsystem: "com.alexgorbatchev.aerospace-sidebar", category: "control")
    private static let receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)

    public let path: String
    private let handler: @MainActor @Sendable (ControlRequest) -> ControlResponse
    private let queue = DispatchQueue(label: "com.alexgorbatchev.aerospace-sidebar.control")
    private let state = OSAllocatedUnfairLock<(descriptor: Int32, source: (any DispatchSourceRead)?)>(
        initialState: (-1, nil)
    )

    public init(
        path: String = SidebarApp.controlSocketPath,
        handler: @escaping @MainActor @Sendable (ControlRequest) -> ControlResponse
    ) {
        self.path = path
        self.handler = handler
    }

    /// Starts listening. Fails when another process already serves the socket.
    public func start() throws {
        if let existing = try? UnixSocket.connect(to: path) {
            close(existing)
            throw StartError.alreadyRunning(path: path)
        }
        let descriptor = try UnixSocket.listen(on: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [self] in acceptConnection(on: descriptor) }
        source.setCancelHandler { close(descriptor) }
        state.withLock { $0 = (descriptor, source) }
        source.resume()
    }

    public func stop() {
        let source = state.withLock { state in
            defer { state = (-1, nil) }
            return state.source
        }
        guard let source else { return }
        source.cancel()
        unlink(path)
    }

    private func acceptConnection(on listener: Int32) {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        UnixSocket.disableSIGPIPE(connection)
        var timeout = Self.receiveTimeout
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
            close(connection)
            return
        }
        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: UnixSocket.readAll(from: connection))
        } catch {
            reply(ControlResponse(error: "invalid request: \(error)"), on: connection)
            return
        }
        Task { @MainActor [handler, queue] in
            let response = handler(request)
            queue.async { [self] in reply(response, on: connection) }
        }
    }

    private func reply(_ response: ControlResponse, on connection: Int32) {
        defer { close(connection) }
        do {
            try UnixSocket.writeAll(JSONEncoder().encode(response), to: connection)
        } catch {
            Self.logger.error("Cannot reply on control socket: \(String(describing: error), privacy: .public)")
        }
    }
}
