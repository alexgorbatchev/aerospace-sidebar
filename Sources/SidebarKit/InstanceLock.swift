import Darwin
import Foundation
import os

/// The running sidebar's claim to be the only one: an exclusive `flock` on a lock file, held until the lock is
/// released or the process exits, crashes included, since the kernel drops the lock with its last descriptor.
/// The holder writes its process id into the file so that a refused launch can say which process runs.
public final class InstanceLock: Sendable {
    public enum ClaimError: Error, Equatable {
        /// Another process holds the lock; `pid` is the one it wrote, nil while it has not written it yet.
        case held(pid: pid_t?)
        /// The lock file could not be opened or locked (`errno`).
        case unavailable(path: String, code: Int32)
    }

    public let path: String
    private let descriptor: Int32

    private init(path: String, descriptor: Int32) {
        self.path = path
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Takes the lock at `path` without waiting, or throws who holds it.
    public static func claim(at path: String) throws(ClaimError) -> InstanceLock {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw .unavailable(path: path, code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            defer { close(descriptor) }
            guard code == EWOULDBLOCK else { throw .unavailable(path: path, code: code) }
            throw .held(pid: holder(of: descriptor))
        }
        let pid = Array("\(getpid())\n".utf8)
        if ftruncate(descriptor, 0) != 0 || pwrite(descriptor, pid, pid.count, 0) != pid.count {
            // The lock holds all the same; only a refused launch's message loses the process id.
            Logger(category: "app").error("Cannot write the process id into \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
        }
        return InstanceLock(path: path, descriptor: descriptor)
    }

    private static func holder(of descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return pid_t(String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
