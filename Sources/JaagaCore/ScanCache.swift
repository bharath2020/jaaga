import Foundation

/// Remembers measured directories so reopening a folder is instant.
///
/// A scan of a large tree costs seconds; walking back up a breadcrumb should cost nothing. The cache
/// is keyed by path, bounded, and evicted least-recently-used first, so browsing a deep tree never
/// grows without limit.
///
/// It lives only for the daemon's lifetime. A fresh daemon measures again, which is the honest
/// default: a cache that survived a reboot would confidently report sizes from before it.
public final class ScanCache {
    public struct Entry {
        public var record: DirectoryRecord
        public var storedAt: Date
    }

    /// Roughly how many directories to keep. Each entry is a record plus its child summaries, so a
    /// few thousand is a handful of megabytes.
    public let capacity: Int
    /// How long a record is served before it is measured again.
    public let timeToLive: TimeInterval

    private var entries: [String: Entry] = [:]
    /// Least recently used first.
    private var accessOrder: [String] = []

    public init(capacity: Int = 4_096, timeToLive: TimeInterval = 15 * 60) {
        self.capacity = capacity
        self.timeToLive = timeToLive
    }

    /// The cached record for `path`, if one is there and still fresh.
    public func record(for path: String, now: Date = Date()) -> DirectoryRecord? {
        guard let entry = entries[path] else { return nil }
        guard now.timeIntervalSince(entry.storedAt) <= timeToLive else {
            remove(path)
            return nil
        }
        touch(path)
        return entry.record
    }

    /// Stores everything one scan produced.
    public func store(_ records: [String: DirectoryRecord], at date: Date = Date()) {
        for (path, record) in records {
            entries[path] = Entry(record: record, storedAt: date)
            touch(path)
        }
        evictIfNeeded()
    }

    public func remove(_ path: String) {
        entries.removeValue(forKey: path)
        accessOrder.removeAll { $0 == path }
    }

    /// Drops `path` and everything beneath it. Called when FSEvents says a watched tree changed, and
    /// on an explicit rescan, so a stale parent total can never outlive the change that broke it.
    public func invalidateSubtree(_ path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let doomed = entries.keys.filter { $0 == path || $0.hasPrefix(prefix) }
        for key in doomed { remove(key) }
        invalidateAncestors(of: path)
    }

    /// A change deep in a tree changes every total above it, so those records are stale too.
    public func invalidateAncestors(of path: String) {
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            remove(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        remove("/")
    }

    public func removeAll() {
        entries.removeAll()
        accessOrder.removeAll()
    }

    public var count: Int { entries.count }

    private func touch(_ path: String) {
        if let index = accessOrder.lastIndex(of: path) {
            accessOrder.remove(at: index)
        }
        accessOrder.append(path)
    }

    private func evictIfNeeded() {
        while entries.count > capacity, let oldest = accessOrder.first {
            accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
