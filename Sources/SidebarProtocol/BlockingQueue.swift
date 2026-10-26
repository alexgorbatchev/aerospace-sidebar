import Foundation

/// Runs blocking work (socket I/O, waiting for a process) on a Dispatch thread.
///
/// Swift's cooperative thread pool is only about as wide as the CPU count. Blocking calls on it can
/// occupy every thread, so the work they wait for never runs: on a 3-core CI runner, socket tests
/// that read on the pool starved the servers they were reading from.
public func onBlockingQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// `onBlockingQueue` for work that cannot fail.
public func onBlockingQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: work())
        }
    }
}
