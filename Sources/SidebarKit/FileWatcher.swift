import Foundation

/// Calls `onChange` after a file changes and then stays unchanged for `delay`, whether it was written in
/// place, replaced atomically, created or removed.
///
/// Watching the directory catches replacements and creation; watching the file catches writes in place,
/// which leave the directory untouched. While the directory is missing, its nearest existing ancestor is
/// watched instead, so creating the directory and then the file is seen. Other files in the directory
/// wake the watcher too, so it compares the file's inode, size and modification time before reporting.
/// The delay keeps a half-written file from being read while another tool is still writing it.
@MainActor
public final class FileWatcher {
    struct Signature: Equatable {
        var inode: UInt64
        var size: Int64
        var modified: Int
        var modifiedNanoseconds: Int
    }

    public let url: URL
    private let delay: Duration
    private let onChange: @MainActor () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: Task<Void, Never>?
    private var signature: Signature?

    public init(url: URL, delay: Duration, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.delay = delay
        self.onChange = onChange
    }

    public func start() {
        stop()
        signature = Self.signature(of: url)
        watchDirectory()
        watchFile()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        pending?.cancel()
        pending = nil
    }

    /// Opens the file's directory again, or its nearest existing ancestor while it is missing, since the
    /// directory may have been created, removed or replaced. A directory created between finding the
    /// ancestor and opening it raises no event there, so it looks again once the source is open.
    private func watchDirectory() {
        var directory: URL
        repeat {
            directory = Self.nearestExistingDirectory(of: url)
            directorySource?.cancel()
            directorySource = makeSource(path: directory.path, events: [.write, .delete, .rename])
        } while Self.nearestExistingDirectory(of: url) != directory
    }

    /// Opens the file again, since a replaced or recreated file is a new inode.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .delete, .rename, .revoke])
    }

    private func changed() {
        watchDirectory()
        watchFile()
        pending?.cancel()
        pending = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let current = Self.signature(of: url)
            guard current != signature else { return }
            signature = current
            onChange()
        }
    }

    private func makeSource(path: String, events: DispatchSource.FileSystemEvent) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.changed() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// The file's directory, or its nearest ancestor that exists.
    static func nearestExistingDirectory(of url: URL) -> URL {
        var directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue),
              directory.pathComponents.count > 1 {
            directory.deleteLastPathComponent()
        }
        return directory
    }

    static func signature(of url: URL) -> Signature? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return Signature(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modified: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}

/// `FileWatcher`s on the files `urls` names, named again after every report, so that a file that becomes or
/// stops being a symlink is watched at its new target (`followingSymlinks(_:)`).
@MainActor
public final class FileWatchers {
    private let delay: Duration
    private let urls: @MainActor () -> [URL]
    private let onChange: @MainActor () -> Void
    private var watchers: [URL: FileWatcher] = [:]

    public init(delay: Duration, urls: @escaping @MainActor () -> [URL], onChange: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.urls = urls
        self.onChange = onChange
    }

    public func start() {
        stop()
        watch()
    }

    public func stop() {
        watchers.values.forEach { $0.stop() }
        watchers = [:]
    }

    /// `urls` and the targets of those that are symlinks. A watcher on a symlink follows its target file but not
    /// the target's directory, so a target removed and created again later, which leaves the symlink's
    /// directory as it was, is seen only by a watcher on the target.
    public nonisolated static func followingSymlinks(_ urls: [URL]) -> [URL] {
        urls + urls.compactMap(\.symlinkTarget)
    }

    private func watch() {
        let urls = urls()
        for (url, watcher) in watchers where !urls.contains(url) {
            watcher.stop()
            watchers[url] = nil
        }
        for url in urls where watchers[url] == nil {
            let watcher = FileWatcher(url: url, delay: delay) { [weak self] in
                self?.watch()
                self?.onChange()
            }
            watcher.start()
            watchers[url] = watcher
        }
    }
}

extension URL {
    /// The file the symlink at this file URL points to, through any further symlinks; nil when it is not a
    /// symlink. Unlike `resolvingSymlinksInPath()`, which leaves a symlink to a missing file as it is, it names
    /// a missing target too, so that the target can be watched or created.
    var symlinkTarget: URL? {
        var target = self
        var links = 0
        while links < MAXSYMLINKS, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) {
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).absoluteURL.standardizedFileURL
            links += 1
        }
        return links == 0 ? nil : target
    }
}
