import Foundation

/// A cancellation flag a synchronous worker can poll from any thread.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Runs the scanner's blocking work off Swift's cooperative thread pool.
///
/// A scan of a large tree is minutes of uninterruptible syscalls. Left on the cooperative pool it
/// would occupy a thread the runtime expects back promptly and could starve every other task in the
/// daemon, so scans get their own queue with a small concurrency limit — two at once is enough to
/// keep the UI responsive while a big rescan runs, without thrashing the disk.
final class ScanRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore

    init(label: String = "com.jaaga.scan", concurrency: Int = 2) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.slots = DispatchSemaphore(value: max(1, concurrency))
    }

    /// Runs `work` on the scan queue, handing it a closure that reports whether the awaiting task has
    /// been cancelled. Cancelling the caller cancels the scan.
    func run<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async { [slots] in
                    // Check before queuing behind the semaphore too: no point waiting for a slot to
                    // run work nobody is waiting for any more.
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    slots.wait()
                    defer { slots.signal() }
                    if flag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        continuation.resume(returning: try work({ flag.isCancelled }))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}
