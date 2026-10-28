import Foundation
import SidebarProtocol

/// Runs an executable to completion on a Dispatch thread (see `onBlockingQueue`) and collects its standard
/// output and error.
public enum SystemCommand {
    public static func run(_ executable: String, _ arguments: [String]) async -> CommandResult {
        await onBlockingQueue {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return CommandResult(status: 127, output: String(describing: error))
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return CommandResult(status: process.terminationStatus, output: output)
        }
    }
}
