import Foundation

/// Tells the daemon when a watched folder changes, so its cached size is never quietly wrong.
///
/// Wraps one FSEvents stream over every watched path. Events are coalesced by FSEvents itself and
/// then debounced here, because a build writing ten thousand files should wake us once, not ten
/// thousand times.
public final class FolderWatcher: @unchecked Sendable {
    /// How long to wait for a burst of changes to settle before reporting it.
    public let debounce: TimeInterval
    /// FSEvents' own coalescing window.
    public let latency: TimeInterval

    private let queue = DispatchQueue(label: "com.jaaga.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void

    /// Everything below is touched only on `queue`.
    private var stream: FSEventStreamRef?
    private var watchedPaths: [String] = []
    private var pendingPaths: Set<String> = []
    private var flushWorkItem: DispatchWorkItem?

    public init(
        debounce: TimeInterval = 2,
        latency: TimeInterval = 1,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        self.debounce = debounce
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        // No queue hop: deinit means nothing else holds us, so the stream is ours to tear down.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Replaces the watched set. Paths that are already watched keep watching without a gap.
    public func setWatchedPaths(_ paths: [String]) {
        queue.async { [self] in
            let sorted = paths.sorted()
            guard sorted != watchedPaths else { return }
            watchedPaths = sorted
            restartStream()
        }
    }

    public func stop() {
        queue.sync { [self] in
            watchedPaths = []
            teardownStream()
            flushWorkItem?.cancel()
            flushWorkItem = nil
            pendingPaths.removeAll()
        }
    }

    // MARK: - Stream lifecycle (queue-confined)

    private func restartStream() {
        teardownStream()
        guard !watchedPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                // kFSEventStreamCreateFlagUseCFTypes means `paths` is a CFArray of CFString.
                let changed = unsafeBitCast(paths, to: NSArray.self).compactMap { $0 as? String }
                watcher.received(paths: changed, count: count)
            },
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    private func teardownStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Called on `queue` by FSEvents.
    private func received(paths: [String], count: Int) {
        guard !paths.isEmpty else { return }
        // Report the watched root rather than the leaf that changed: the daemon invalidates whole
        // subtrees anyway, and a root is a stable key for the app to match against.
        for path in paths {
            pendingPaths.insert(watchedRoot(containing: path) ?? path)
        }
        scheduleFlush()
    }

    private func watchedRoot(containing path: String) -> String? {
        watchedPaths
            .filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [self] in
            let batch = pendingPaths
            pendingPaths.removeAll()
            flushWorkItem = nil
            guard !batch.isEmpty else { return }
            onChange(batch.sorted())
        }
        flushWorkItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
