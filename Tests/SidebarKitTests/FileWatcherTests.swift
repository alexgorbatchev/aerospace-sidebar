import Foundation
@testable import SidebarKit
import Testing

@MainActor
struct FileWatcherTests {
    let directory: TemporaryDirectory
    let url: URL

    init() throws {
        directory = try TemporaryDirectory()
        url = directory.url.appendingPathComponent("aerospace.toml")
    }

    /// Starts a watcher and returns a counter of its reports.
    func watch(delay: Duration = .milliseconds(30)) -> (FileWatcher, Counter) {
        let counter = Counter()
        let watcher = FileWatcher(url: url, delay: delay) { counter.count += 1 }
        watcher.start()
        return (watcher, counter)
    }

    /// Waits for `count` reports, then a while longer to catch extra ones.
    func expectReports(_ count: Int, from counter: Counter) async throws {
        for _ in 0..<300 where counter.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await settle()
        #expect(counter.count == count)
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test func reportsWritesInPlace() async throws {
        try directory.write("a", to: "aerospace.toml")
        let (watcher, counter) = watch()
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b".utf8))
        try handle.close()

        try await expectReports(1, from: counter)
    }

    @Test func reportsAtomicReplacementsAndKeepsWatchingTheNewFile() async throws {
        try directory.write("a", to: "aerospace.toml")
        let (watcher, counter) = watch()
        defer { watcher.stop() }

        try "b".write(to: url, atomically: true, encoding: .utf8)
        try await expectReports(1, from: counter)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c".utf8))
        try handle.close()

        try await expectReports(2, from: counter)
    }

    @Test func reportsCreationAndRemoval() async throws {
        let (watcher, counter) = watch()
        defer { watcher.stop() }

        try directory.write("a", to: "aerospace.toml")
        try await expectReports(1, from: counter)
        try FileManager.default.removeItem(at: url)

        try await expectReports(2, from: counter)
    }

    @Test func ignoresOtherFilesInTheDirectory() async throws {
        try directory.write("a", to: "aerospace.toml")
        let (watcher, counter) = watch()
        defer { watcher.stop() }

        try directory.write("x", to: "other.txt")
        try await settle()

        #expect(counter.count == 0)
    }

    @Test func reportsBurstsOnceTheyEnd() async throws {
        try directory.write("a", to: "aerospace.toml")
        let (watcher, counter) = watch(delay: .milliseconds(100))
        defer { watcher.stop() }

        // The main actor does not yield between the writes, so all their events arrive before the delay ends.
        for text in ["b", "bc", "bcd"] {
            try text.write(to: url, atomically: false, encoding: .utf8)
        }

        try await expectReports(1, from: counter)
    }

    @Test func stopEndsReports() async throws {
        try directory.write("a", to: "aerospace.toml")
        let (watcher, counter) = watch()

        watcher.stop()
        try directory.write("b", to: "aerospace.toml")
        try await settle()

        #expect(counter.count == 0)
    }

    @Test func missingDirectoryWatchesNothing() async throws {
        let watcher = FileWatcher(url: directory.url.appendingPathComponent("missing/aerospace.toml"), delay: .milliseconds(10)) {
            Issue.record("unexpected report")
        }

        watcher.start()
        try await settle()
        watcher.stop()
    }
}

@MainActor
final class Counter {
    var count = 0
}
