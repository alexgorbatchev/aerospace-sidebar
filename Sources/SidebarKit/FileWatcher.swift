import Foundation

/// Calls `onChange` after a file changes and then stays unchanged for `delay`, whether it was written in
/// place, replaced atomically, created or removed.
///
/// Watching the directory catches replacements and creation; watching the file catches writes in place,
/// which leave the directory untouched. Other files in the directory wake the watcher too, so it compares
/// the file's inode, size and modification time before reporting. The delay keeps a half-written file
/// from being read while another tool is still writing it.
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
        directorySource = makeSource(path: url.deletingLastPathComponent().path, events: .write)
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

    /// Opens the file again, since a replaced or recreated file is a new inode.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = makeSource(path: url.path, events: [.write, .extend, .delete, .rename, .revoke])
    }

    private func changed() {
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
