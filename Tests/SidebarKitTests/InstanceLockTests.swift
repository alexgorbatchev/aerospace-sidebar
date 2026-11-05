import Darwin
import Foundation
@testable import SidebarKit
import SidebarProtocol
import Testing

struct InstanceLockTests {
    /// The holder writes its process id; a second claim, as another process's would, is refused naming it, until
    /// the holder releases the lock.
    @Test func refusesASecondClaimUntilTheFirstIsReleased() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("sidebar.lock").path

        var lock: InstanceLock? = try InstanceLock.claim(at: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "\(getpid())\n")
        #expect(throws: InstanceLock.ClaimError.held(pid: getpid())) { try InstanceLock.claim(at: path) }
        #expect(lock?.path == path)

        lock = nil
        let next = try InstanceLock.claim(at: path)
        #expect(next.path == path)
    }

    /// A stale file from a copy that exited holds no lock, and its longer contents are replaced, not overwritten
    /// in part.
    @Test func claimsAStaleFileAndReplacesItsProcessID() throws {
        let directory = try TemporaryDirectory()
        try directory.write("1234567890\n", to: "sidebar.lock")
        let path = directory.url.appendingPathComponent("sidebar.lock").path

        let lock = try InstanceLock.claim(at: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "\(getpid())\n")
        _ = lock
    }

    /// A holder that has not written its process id yet is refused all the same, naming no process.
    @Test func refusesWithoutAProcessIDBeforeTheHolderWritesOne() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("sidebar.lock").path
        let holder = open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        defer { close(holder) }
        try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

        #expect(throws: InstanceLock.ClaimError.held(pid: nil)) { try InstanceLock.claim(at: path) }
    }

    @Test func reportsALockFileThatCannotBeOpened() {
        #expect(throws: InstanceLock.ClaimError.unavailable(path: "/nonexistent-directory/sidebar.lock", code: ENOENT)) {
            try InstanceLock.claim(at: "/nonexistent-directory/sidebar.lock")
        }
    }
}
