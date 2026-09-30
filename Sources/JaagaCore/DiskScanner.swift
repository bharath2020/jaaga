import Foundation
import JaagaProtocol

public struct ScanProgress: Sendable, Hashable {
    public var currentPath: String
    public var itemsScanned: Int
    public var bytesScanned: Int64
}

public struct ScanConfiguration: Sendable, Hashable {
    /// How many levels below the scanned root keep their own `DirectoryRecord`.
    ///
    /// Totals are always exact for the whole subtree; this only bounds what stays in memory.
    /// Two levels covers the space map, the list under it, the inspector's "biggest inside", and a
    /// Quick Look of any child — anything deeper is a fresh (and by then warm) scan.
    public var recordDepth: Int
    /// Emit a progress callback roughly every this many items.
    public var progressInterval: Int

    public init(recordDepth: Int = 2, progressInterval: Int = 2048) {
        self.recordDepth = recordDepth
        self.progressInterval = progressInterval
    }

    public static let `default` = ScanConfiguration()
}

public struct ScanOutcome: Sendable {
    public var root: DirectoryRecord
    /// `root` plus every descendant directory within `ScanConfiguration.recordDepth`, keyed by path.
    public var records: [String: DirectoryRecord]
    public var itemsScanned: Int
    public var unreadable: [UnreadablePath]
    public var duration: TimeInterval
}

public enum ScanError: Error, Sendable, Equatable {
    case notFound(path: String, errnoCode: Int32)
    case notADirectory(path: String)
    case notReadable(path: String, errnoCode: Int32)

    public var asProtocolFailure: ProtocolFailure {
        switch self {
        case .notFound(let path, let code):
            ProtocolFailure(code: .notFound, message: "No such file or directory", path: path, errnoCode: code)
        case .notADirectory(let path):
            ProtocolFailure(code: .notADirectory, message: "Not a directory", path: path)
        case .notReadable(let path, let code):
            ProtocolFailure(
                code: .notReadable,
                message: "Could not read \(path): \(String(cString: strerror(code))). "
                    + "Jaaga may need Full Disk Access.",
                path: path,
                errnoCode: code
            )
        }
    }
}

/// Measures how much disk a folder tree actually occupies.
///
/// The rules, all of which the tests pin down:
///
/// - **Allocated, not logical.** Sizes come from `st_blocks * 512`, so a sparse file costs what it
///   really costs and a pile of tiny files costs its block overhead. This is the number that
///   changes the free-space figure when you delete something.
/// - **One volume.** A child on a different device is skipped rather than folded into the parent's
///   total, so a mounted disk image never inflates your home folder.
/// - **Symlinks are never followed.** A link contributes only its own (tiny) size. Nothing is
///   counted twice and there are no traversal cycles.
/// - **Hard links are counted once.** Two names for the same inode occupy one set of blocks, so the
///   second name adds nothing — which is what the Finder's free-space figure will also say.
/// - **Unreadable folders are reported.** A folder that cannot be opened goes into `unreadable`
///   with its errno, so a total that is short says so instead of quietly lying.
///
/// The scan is cancellable through normal task cancellation and reports progress as it goes.
public struct DiskScanner: Sendable {
    public var configuration: ScanConfiguration

    public init(configuration: ScanConfiguration = .default) {
        self.configuration = configuration
    }

    /// Measures `rootPath`, calling `onProgress` periodically on the calling thread.
    ///
    /// `isCancelled` is consulted between entries and throws `CancellationError` when it turns true,
    /// leaving no partial result behind. It is a closure rather than `Task.isCancelled` because the
    /// daemon runs scans on its own queue, off the cooperative pool, where there is no task to ask.
    /// `onProgress` comes before `isCancelled` so that a trailing closure binds to the progress
    /// callback, which is the one callers usually want to write inline.
    public func scan(
        rootPath: String,
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ScanOutcome {
        let started = Date()
        let root = (rootPath as NSString).standardizingPath

        var rootStat = stat()
        guard lstat(root, &rootStat) == 0 else {
            throw ScanError.notFound(path: root, errnoCode: errno)
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ScanError.notADirectory(path: root)
        }

        var run = ScanRun(
            configuration: configuration,
            rootDevice: rootStat.st_dev,
            startedAt: started,
            isCancelled: isCancelled,
            onProgress: onProgress
        )

        let aggregate = try run.walk(directoryPath: root, depth: 0, statOfDirectory: rootStat)

        guard var rootRecord = run.records[root] else {
            // `walk` only fails to leave a record when it could not open the root at all.
            throw ScanError.notReadable(path: root, errnoCode: run.rootErrno ?? EACCES)
        }
        rootRecord.unreadable = run.unreadable
        run.records[root] = rootRecord

        return ScanOutcome(
            root: rootRecord,
            records: run.records,
            itemsScanned: aggregate.items,
            unreadable: run.unreadable,
            duration: Date().timeIntervalSince(started)
        )
    }
}

// MARK: - One traversal

/// Mutable state for a single `scan` call. Never shared across tasks.
private struct ScanRun {
    struct Aggregate {
        var bytes: Int64 = 0
        var items: Int = 0
        var directories: Int = 0
        /// Folders in this subtree that could not be opened, so `bytes` is short by an unknown amount.
        var unreadable: Int = 0

        static let zero = Aggregate()

        static func += (lhs: inout Aggregate, rhs: Aggregate) {
            lhs.bytes += rhs.bytes
            lhs.items += rhs.items
            lhs.directories += rhs.directories
            lhs.unreadable += rhs.unreadable
        }
    }

    /// Identifies a file across the volumes we might touch, for hard-link de-duplication.
    struct INode: Hashable {
        var device: dev_t
        var inode: ino_t
    }

    let configuration: ScanConfiguration
    let rootDevice: dev_t
    let startedAt: Date
    let isCancelled: @Sendable () -> Bool
    let onProgress: (@Sendable (ScanProgress) -> Void)?

    var records: [String: DirectoryRecord] = [:]
    var unreadable: [UnreadablePath] = []
    /// Only populated when the scan root itself could not be opened.
    var rootErrno: Int32?
    /// Inodes already counted, tracked only for files with more than one link.
    var countedINodes: Set<INode> = []
    var itemsScanned = 0
    var bytesScanned: Int64 = 0
    var itemsSinceProgress = 0

    mutating func walk(directoryPath: String, depth: Int, statOfDirectory: stat) throws -> Aggregate {
        if isCancelled() { throw CancellationError() }

        // O_NOFOLLOW: refuse to descend even if this component turned into a symlink since we
        // stat'd it. O_DIRECTORY: refuse if it is no longer a directory.
        let directoryFD = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else {
            let code = errno
            if depth == 0 { rootErrno = code }
            noteUnreadable(directoryPath, errnoCode: code)
            return Aggregate(bytes: 0, items: 0, directories: 0, unreadable: 1)
        }
        defer { close(directoryFD) }

        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
        } catch {
            let code = (error as NSError).code == NSFileReadNoPermissionError ? EACCES : errno
            if depth == 0 { rootErrno = code }
            noteUnreadable(directoryPath, errnoCode: code, message: error.localizedDescription)
            return Aggregate(bytes: 0, items: 0, directories: 0, unreadable: 1)
        }

        var total = Aggregate.zero
        var children: [ChildRecord] = []
        children.reserveCapacity(names.count)

        for name in names {
            if isCancelled() { throw CancellationError() }
            let childPath = directoryPath.hasSuffix("/") ? directoryPath + name : directoryPath + "/" + name

            var childStat = stat()
            guard fstatat(directoryFD, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                // A file that vanished mid-scan is normal in a cache folder; only a permission
                // problem is worth reporting, because that is the one that skews the total.
                let code = errno
                if code == EACCES || code == EPERM {
                    noteUnreadable(childPath, errnoCode: code)
                    total.unreadable += 1
                }
                continue
            }

            // A child on another device belongs to that volume's own total, not this one.
            guard childStat.st_dev == rootDevice else { continue }

            let mode = childStat.st_mode & S_IFMT
            let ownBytes = Int64(childStat.st_blocks) * 512

            if mode == S_IFLNK {
                // The link itself, never its target: following it would double-count the target
                // and could loop.
                count(items: 1, bytes: ownBytes, at: childPath)
                total.bytes += ownBytes
                total.items += 1
                children.append(
                    ChildRecord(
                        name: name,
                        path: childPath,
                        isDirectory: false,
                        isSymbolicLink: true,
                        allocatedBytes: ownBytes,
                        itemCount: 1,
                        directChildCount: 0,
                        created: date(childStat.st_birthtimespec),
                        contentModified: date(childStat.st_mtimespec),
                        lastOpened: date(childStat.st_atimespec)
                    )
                )
                continue
            }

            if mode == S_IFDIR {
                let subtree = try walk(directoryPath: childPath, depth: depth + 1, statOfDirectory: childStat)
                // The directory's own inode takes blocks too.
                let directoryBytes = subtree.bytes + ownBytes
                count(items: 1, bytes: ownBytes, at: childPath)
                total.bytes += directoryBytes
                total.items += subtree.items + 1
                total.directories += subtree.directories + 1
                total.unreadable += subtree.unreadable

                let directChildren: Int? = records[childPath]?.children.count
                children.append(
                    ChildRecord(
                        name: name,
                        path: childPath,
                        isDirectory: true,
                        isSymbolicLink: false,
                        allocatedBytes: directoryBytes,
                        itemCount: subtree.items,
                        directChildCount: directChildren,
                        unreadableDescendantCount: subtree.unreadable,
                        created: date(childStat.st_birthtimespec),
                        contentModified: date(childStat.st_mtimespec),
                        lastOpened: date(childStat.st_atimespec)
                    )
                )
                continue
            }

            // A regular file, or something exotic like a fifo or a socket — either way its blocks
            // are what it costs.
            var bytes = ownBytes
            if childStat.st_nlink > 1 {
                // Several names, one set of blocks. Count the blocks for the first name we meet and
                // nothing for the rest, which is what deleting one name would actually free.
                let node = INode(device: childStat.st_dev, inode: childStat.st_ino)
                if !countedINodes.insert(node).inserted {
                    bytes = 0
                }
            }
            count(items: 1, bytes: bytes, at: childPath)
            total.bytes += bytes
            total.items += 1
            children.append(
                ChildRecord(
                    name: name,
                    path: childPath,
                    isDirectory: false,
                    isSymbolicLink: false,
                    allocatedBytes: bytes,
                    itemCount: 1,
                    directChildCount: 0,
                    created: date(childStat.st_birthtimespec),
                    contentModified: date(childStat.st_mtimespec),
                    lastOpened: date(childStat.st_atimespec)
                )
            )
        }

        if depth <= configuration.recordDepth {
            children.sort { $0.allocatedBytes > $1.allocatedBytes }
            records[directoryPath] = DirectoryRecord(
                path: directoryPath,
                name: displayName(of: directoryPath),
                allocatedBytes: total.bytes + Int64(statOfDirectory.st_blocks) * 512,
                itemCount: total.items,
                directoryCount: total.directories,
                children: children,
                created: date(statOfDirectory.st_birthtimespec),
                contentModified: date(statOfDirectory.st_mtimespec),
                lastOpened: date(statOfDirectory.st_atimespec),
                unreadable: [],
                scannedAt: startedAt
            )
        } else {
            // Past the retention depth we drop the child summaries and keep only the totals,
            // which is the whole point of the depth limit.
            records.removeValue(forKey: directoryPath)
        }

        return total
    }

    private mutating func count(items: Int, bytes: Int64, at path: String) {
        itemsScanned += items
        bytesScanned += bytes
        itemsSinceProgress += items
        guard let onProgress, itemsSinceProgress >= configuration.progressInterval else { return }
        itemsSinceProgress = 0
        onProgress(ScanProgress(currentPath: path, itemsScanned: itemsScanned, bytesScanned: bytesScanned))
    }

    private mutating func noteUnreadable(_ path: String, errnoCode: Int32, message: String? = nil) {
        unreadable.append(
            UnreadablePath(
                path: path,
                reason: message ?? String(cString: strerror(errnoCode)),
                errnoCode: errnoCode
            )
        )
    }
}

// MARK: - Small helpers

extension Date {
    /// A `stat` timestamp as a `Date`, or nil when the filesystem has none to give (a zero
    /// `st_birthtimespec` on a volume that does not record creation dates, for instance).
    public init?(timespec spec: timespec) {
        guard spec.tv_sec > 0 else { return nil }
        self.init(timeIntervalSince1970: Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000)
    }
}

func date(_ spec: timespec) -> Date? { Date(timespec: spec) }

/// The last path component, or `/` for the volume root.
func displayName(of path: String) -> String {
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
}
