import Foundation
import os
import SidebarProtocol

/// Serves `ControlRequest`s on the Unix control socket.
///
/// Only processes of the same user can connect: the socket file is mode 0600 inside the per-user
/// temporary directory, and each peer's uid is checked with `getpeereid`. This is the only way to
/// push notifications that run commands on click or ask for an answer.
///
/// A request is confirmed as soon as it decodes and validates, and then handed to the main actor. The
/// reply never waits for the main actor, which can be busy for longer than a client waits (NotificationCenter
/// can take ~15 s to answer after a wake): a client that gave up on a request the app goes on to show would
/// report a failure for it, or send it again. An ask request's connection stays open after the reply, for the
/// answer (`AskConnection`).
public final class ControlServer: Sendable {
    public enum StartError: Error, Equatable {
        case alreadyRunning(path: String)
    }

    /// A request handed to the main actor.
    public enum Request: Sendable {
        case push(NotificationPayload)
        /// A notification whose choices answer `asker`, the client waiting on its connection.
        case ask(NotificationPayload, asker: AskConnection)
    }

    private static let logger = Logger(category: "control")
    private static let receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)

    public let path: String
    private let handler: @MainActor @Sendable (Request) -> Void
    private let queue = DispatchQueue(label: "com.alexgorbatchev.aerospace-sidebar.control")
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var descriptor: Int32 = -1
        var source: (any DispatchSourceRead)?
        /// Ask connections still waiting for their answer, which `stop()` closes.
        var asks: [ObjectIdentifier: AskConnection] = [:]
    }

    public init(
        path: String = SidebarApp.controlSocketPath,
        handler: @escaping @MainActor @Sendable (Request) -> Void
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
        state.withLock {
            $0.descriptor = descriptor
            $0.source = source
        }
        source.resume()
    }

    /// Stops listening and closes the connections of asks still waiting, whose clients then read no answer.
    public func stop() {
        let (source, asks) = state.withLock { state in
            defer { state = State() }
            return (state.source, Array(state.asks.values))
        }
        asks.forEach { $0.close() }
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
            var reader = MessageReader(descriptor: connection)
            guard let message = try reader.next() else { throw SocketError("read", code: ENODATA) }
            request = try JSONDecoder().decode(ControlRequest.self, from: message)
            try request.validate()
        } catch {
            reply(ControlResponse(error: "invalid request: \(error)"), on: connection)
            close(connection)
            return
        }
        switch request {
        case .pushNotification(let payload):
            Task { @MainActor [handler] in handler(.push(payload)) }
            reply(ControlResponse(error: nil), on: connection)
            close(connection)
        case .askNotification(let payload):
            guard reply(ControlResponse(error: nil), on: connection) else {
                close(connection)
                return
            }
            let asker = AskConnection(descriptor: connection, queue: queue) { [state] asker in
                _ = state.withLock { $0.asks.removeValue(forKey: ObjectIdentifier(asker)) }
            }
            state.withLock { $0.asks[ObjectIdentifier(asker)] = asker }
            asker.watch()
            Task { @MainActor [handler] in handler(.ask(payload, asker: asker)) }
        }
    }

    @discardableResult
    private func reply(_ response: ControlResponse, on connection: Int32) -> Bool {
        do {
            try UnixSocket.writeMessage(JSONEncoder().encode(response), to: connection)
            return true
        } catch {
            Self.logger.error("Cannot reply on control socket: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// The client of an ask request, waiting on its connection for the answer (`AskAnswer`). The connection is
/// closed once it is answered, or when the client hangs up first, such as when the user stops the command or
/// its timeout passes; the server notices the end of the stream and calls the hang-up handler.
///
/// The connection does not block: the answer is written as the client reads it (`DispatchSourceWrite`), so a
/// client that stops reading, such as a command suspended with Ctrl-Z, holds up only its own answer, never the
/// queue that accepts every other request.
public final class AskConnection: NotificationAsking, Sendable {
    private static let logger = Logger(category: "control")

    private struct State {
        /// Watches for the client hanging up until the answer is due.
        var reader: (any DispatchSourceRead)?
        /// Writes the answer once `reader` has let go of the descriptor.
        var writer: (any DispatchSourceWrite)?
        /// The answer's bytes still to write.
        var unwritten = Data()
        var closed = false
        var hungUp = false
        var onHangUp: (@MainActor @Sendable () -> Void)?
    }

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let finished: @Sendable (AskConnection) -> Void
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// - Parameter finished: Called once the connection is closed, whichever way.
    init(descriptor: Int32, queue: DispatchQueue, finished: @escaping @Sendable (AskConnection) -> Void) {
        self.descriptor = descriptor
        self.queue = queue
        self.finished = finished
    }

    /// Starts watching the connection for the client hanging up; the connection owns the descriptor from then on.
    func watch() {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let reader = state.withLock { state -> (any DispatchSourceRead)? in
            guard !state.closed else { return nil }
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            reader.setEventHandler { [self] in clientSent() }
            reader.setCancelHandler { [self] in readerLetGo() }
            state.reader = reader
            return reader
        }
        guard let reader else {
            Darwin.close(descriptor)
            return
        }
        reader.resume()
    }

    /// The client sends nothing after its request, so a readable connection has ended, unless it sent more
    /// anyway, which is read and ignored.
    private func clientSent() {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = read(descriptor, &buffer, buffer.count)
        guard count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) else { return }
        let handler = state.withLock { state -> (@MainActor @Sendable () -> Void)? in
            state.hungUp = true
            return state.onHangUp
        }
        guard close() else { return }
        if let handler {
            Task { @MainActor in handler() }
        }
    }

    /// Writes the answer and closes the connection; does nothing once it is closed or answered.
    public func answer(_ answer: AskAnswer) {
        let message: Data
        do {
            message = try UnixSocket.message(JSONEncoder().encode(answer))
        } catch {
            Self.logger.error("Cannot encode an answer: \(String(describing: error), privacy: .public)")
            return
        }
        let reader = state.withLock { state -> (any DispatchSourceRead)? in
            guard let reader = state.reader else { return nil }
            state.reader = nil
            state.unwritten = message
            return reader
        }
        // Its cancel handler starts writing: a descriptor takes a new source only once the old one let go of it.
        reader?.cancel()
    }

    /// Closes the descriptor the reader watched, or writes the answer to it when one is due.
    private func readerLetGo() {
        let writer = state.withLock { state -> (any DispatchSourceWrite)? in
            guard !state.closed, !state.unwritten.isEmpty else { return nil }
            let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            writer.setEventHandler { [self] in writeAnswer() }
            writer.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
            state.writer = writer
            return writer
        }
        guard let writer else {
            Darwin.close(descriptor)
            return
        }
        writer.resume()
    }

    /// Writes what the client has room for, and closes the connection once the answer is written or fails.
    private func writeAnswer() {
        let unwritten = state.withLock { $0.unwritten }
        guard !unwritten.isEmpty else { return }
        let written = unwritten.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }
        if written < 0 {
            let code = errno
            guard code != EAGAIN, code != EINTR else { return }
            Self.logger.error("Cannot answer an ask: \(SocketError("write", code: code).description, privacy: .public)")
            close()
            return
        }
        let done = state.withLock { state in
            guard !state.closed else { return false }
            state.unwritten = Data(state.unwritten.dropFirst(written))
            return state.unwritten.isEmpty
        }
        if done { close() }
    }

    /// Calls `handler` on the main actor once the client hangs up before an answer, at once if it already has.
    public func onHangUp(_ handler: @escaping @MainActor @Sendable () -> Void) {
        let hungUp = state.withLock { state in
            state.onHangUp = handler
            return state.hungUp
        }
        if hungUp {
            Task { @MainActor in handler() }
        }
    }

    /// Closes the connection, dropping what is left of an answer; false when it was closed already.
    @discardableResult
    func close() -> Bool {
        let sources = state.withLock { state -> ((any DispatchSourceRead)?, (any DispatchSourceWrite)?)? in
            guard !state.closed else { return nil }
            state.closed = true
            state.unwritten = Data()
            defer {
                state.reader = nil
                state.writer = nil
            }
            return (state.reader, state.writer)
        }
        guard let (reader, writer) = sources else { return false }
        // The reader's cancel handler closes the descriptor, or the writer's once the reader let go of it.
        reader?.cancel()
        writer?.cancel()
        finished(self)
        return true
    }
}
