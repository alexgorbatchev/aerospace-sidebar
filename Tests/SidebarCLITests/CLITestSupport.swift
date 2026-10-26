import Foundation
@testable import SidebarCLI
import SidebarProtocol

final class BufferOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    let fails: Bool

    init(fails: Bool = false) {
        self.fails = fails
    }

    var text: String { lock.withLock { buffer } }

    func write(_ text: String) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { buffer += text }
    }
}

final class RecordingSender: NotificationSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NotificationPayload] = []
    let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var payloads: [NotificationPayload] { lock.withLock { recorded } }

    func push(_ payload: NotificationPayload) async throws {
        if let error { throw error }
        lock.withLock { recorded.append(payload) }
    }
}

struct Invocation {
    let status: Int32
    let output: String
    let errorOutput: String
}

func invoke(
    _ arguments: [String],
    agent: Bool = false,
    sender: RecordingSender = RecordingSender(),
    output: BufferOutput = BufferOutput(),
    width: Int? = 100
) async -> Invocation {
    let errorOutput = BufferOutput()
    let context = CLIContext(
        environment: agent ? ["AGENT": "1"] : [:],
        output: output,
        errorOutput: errorOutput,
        sender: sender,
        workingDirectory: "/Users/dev/project",
        homeDirectory: "/Users/dev",
        terminalWidth: width
    )
    let status = await SidebarCLI.main(arguments: arguments, context: context)
    return Invocation(status: status, output: output.text, errorOutput: errorOutput.text)
}
