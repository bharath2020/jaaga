import Foundation

/// How a folder's bytes are coloured and grouped. Every entry the daemon reports carries one.
public enum UsageCategory: String, Codable, Sendable, CaseIterable {
    case cache
    case media
    case dev
    case apps
    case docs
    case downloads
    case photos
    case system
}

/// What Jaaga is willing to say about deleting something.
public enum Verdict: String, Codable, Sendable, CaseIterable {
    /// Rebuilt or re-downloaded on demand. Nothing of yours is lost.
    case safeToClear = "safe_to_clear"
    /// Big and often disposable, but only you know which parts you still need.
    case reviewFirst = "review_first"
    /// Your own files. Jaaga never suggests clearing these.
    case yourData = "your_data"
}

/// A folder or file as the daemon sees it. Sizes are always *allocated* (on-disk) bytes.
public struct Entry: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    /// Allocated (on-disk) bytes, recursive for directories. Hard-linked files are counted once.
    public var allocatedBytes: Int64
    /// Files plus directories inside, recursive. `1` for a file.
    public var itemCount: Int
    /// Immediate children. `0` for a file, `nil` when the daemon has not measured this folder's
    /// contents yet (it sits below the depth the last scan retained).
    public var directChildCount: Int?
    public var category: UsageCategory
    public var verdict: Verdict
    /// One plain-language sentence explaining why this is big and what clearing it costs.
    public var reason: String
    /// Short human label, e.g. "Xcode build cache".
    public var kind: String
    public var lastOpened: Date?
    public var contentModified: Date?
    public var created: Date?
    public var isWatched: Bool
    /// How many folders inside this entry could not be opened.
    ///
    /// When it is non-zero, `allocatedBytes` is a **lower bound**: the real figure is larger by an
    /// amount nobody can know without reading those folders. A client must not present the number as
    /// exact. On a real `~/Library` this is routinely 150-odd TCC-protected folders until Full Disk
    /// Access is granted, which is precisely when a total looks wrong and unexplained.
    public var unreadableDescendantCount: Int

    /// False when part of this entry's subtree could not be read.
    public var isComplete: Bool { unreadableDescendantCount == 0 }

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool = false,
        allocatedBytes: Int64,
        itemCount: Int,
        directChildCount: Int?,
        category: UsageCategory,
        verdict: Verdict,
        reason: String,
        kind: String,
        lastOpened: Date? = nil,
        contentModified: Date? = nil,
        created: Date? = nil,
        isWatched: Bool = false,
        unreadableDescendantCount: Int = 0
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.directChildCount = directChildCount
        self.category = category
        self.verdict = verdict
        self.reason = reason
        self.kind = kind
        self.lastOpened = lastOpened
        self.contentModified = contentModified
        self.created = created
        self.isWatched = isWatched
        self.unreadableDescendantCount = unreadableDescendantCount
    }
}

/// A folder the scanner could not open. Reported rather than silently undercounted, because the
/// usual cause is a missing Full Disk Access grant and the user needs to know the total is short.
public struct UnreadablePath: Codable, Sendable, Hashable {
    public var path: String
    public var reason: String
    /// POSIX errno when one is available, so a client can single out `EACCES` (13).
    public var errnoCode: Int32?

    public init(path: String, reason: String, errnoCode: Int32? = nil) {
        self.path = path
        self.reason = reason
        self.errnoCode = errnoCode
    }
}

/// One folder plus its immediate children: everything the space map and the list below it need.
public struct FolderListing: Codable, Sendable {
    public var folder: Entry
    /// Largest first.
    public var children: [Entry]
    public var parentPath: String?
    public var scannedAt: Date
    /// True when served from the daemon's cache without touching the disk.
    public var fromCache: Bool
    /// False when part of the subtree could not be read, so `allocatedBytes` is a lower bound.
    public var complete: Bool
    public var unreadable: [UnreadablePath]

    public init(
        folder: Entry,
        children: [Entry],
        parentPath: String?,
        scannedAt: Date,
        fromCache: Bool,
        complete: Bool,
        unreadable: [UnreadablePath]
    ) {
        self.folder = folder
        self.children = children
        self.parentPath = parentPath
        self.scannedAt = scannedAt
        self.fromCache = fromCache
        self.complete = complete
        self.unreadable = unreadable
    }
}

public struct VolumeInfo: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var mountPath: String
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var isStartupDisk: Bool
    public var isInternal: Bool
    public var isRemovable: Bool

    public var id: String { mountPath }
    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    public init(
        name: String,
        mountPath: String,
        totalBytes: Int64,
        freeBytes: Int64,
        isStartupDisk: Bool,
        isInternal: Bool,
        isRemovable: Bool
    ) {
        self.name = name
        self.mountPath = mountPath
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isStartupDisk = isStartupDisk
        self.isInternal = isInternal
        self.isRemovable = isRemovable
    }
}

public struct CategorySegment: Codable, Sendable, Hashable, Identifiable {
    public var label: String
    public var category: UsageCategory
    public var bytes: Int64

    public var id: String { label }

    public init(label: String, category: UsageCategory, bytes: Int64) {
        self.label = label
        self.category = category
        self.bytes = bytes
    }
}

/// The sidebar disk card: free space plus a breakdown of what is using the rest.
///
/// `segments` only covers what the daemon has actually measured. `accountedBytes` says how much
/// that is, so a client can show the remainder honestly instead of implying a complete picture.
public struct VolumeSummary: Codable, Sendable {
    public var volume: VolumeInfo
    public var segments: [CategorySegment]
    public var accountedBytes: Int64
    public var measuredAt: Date?

    public init(volume: VolumeInfo, segments: [CategorySegment], accountedBytes: Int64, measuredAt: Date?) {
        self.volume = volume
        self.segments = segments
        self.accountedBytes = accountedBytes
        self.measuredAt = measuredAt
    }
}

/// One entry from the usual-suspects catalog, measured on this machine.
public struct Suspect: Codable, Sendable, Hashable, Identifiable {
    /// Stable catalog rule id, e.g. `xcode-derived-data`.
    public var id: String
    public var title: String
    /// What to show the user, e.g. `~/Developer/*/node_modules`.
    public var displayPath: String
    /// The concrete paths that make up this suspect. One entry unless `isAggregate`.
    public var paths: [String]
    public var category: UsageCategory
    public var verdict: Verdict
    public var reason: String
    public var kind: String
    public var allocatedBytes: Int64
    public var itemCount: Int
    public var isWatched: Bool
    /// True when `allocatedBytes` is the sum of many matched paths (node_modules, installers).
    public var isAggregate: Bool

    public init(
        id: String,
        title: String,
        displayPath: String,
        paths: [String],
        category: UsageCategory,
        verdict: Verdict,
        reason: String,
        kind: String,
        allocatedBytes: Int64,
        itemCount: Int,
        isWatched: Bool,
        isAggregate: Bool
    ) {
        self.id = id
        self.title = title
        self.displayPath = displayPath
        self.paths = paths
        self.category = category
        self.verdict = verdict
        self.reason = reason
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.isWatched = isWatched
        self.isAggregate = isAggregate
    }
}

public struct SuspectReport: Codable, Sendable {
    /// Largest first. Only suspects that exist on this machine and hold bytes.
    public var suspects: [Suspect]
    public var totalBytes: Int64
    public var safeToClearBytes: Int64
    public var scannedAt: Date
    public var unreadable: [UnreadablePath]

    public init(
        suspects: [Suspect],
        totalBytes: Int64,
        safeToClearBytes: Int64,
        scannedAt: Date,
        unreadable: [UnreadablePath]
    ) {
        self.suspects = suspects
        self.totalBytes = totalBytes
        self.safeToClearBytes = safeToClearBytes
        self.scannedAt = scannedAt
        self.unreadable = unreadable
    }
}

public struct SizeSample: Codable, Sendable, Hashable {
    public var at: Date
    public var bytes: Int64

    public init(at: Date, bytes: Int64) {
        self.at = at
        self.bytes = bytes
    }
}

/// How fast a watched folder is growing, and whether that is unusual *for this folder*.
public struct GrowthSummary: Codable, Sendable, Hashable {
    /// Newest sample minus oldest sample in the retained history.
    public var deltaBytes: Int64
    /// Seconds spanned by `deltaBytes`.
    public var windowSeconds: Double
    public var recentBytesPerDay: Double
    public var baselineBytesPerDay: Double
    /// `recentBytesPerDay / baselineBytesPerDay`. Nil when the folder was flat before, which is
    /// itself worth alerting on but has no meaningful ratio.
    public var accelerationFactor: Double?
    public var isAlerting: Bool

    public init(
        deltaBytes: Int64,
        windowSeconds: Double,
        recentBytesPerDay: Double,
        baselineBytesPerDay: Double,
        accelerationFactor: Double?,
        isAlerting: Bool
    ) {
        self.deltaBytes = deltaBytes
        self.windowSeconds = windowSeconds
        self.recentBytesPerDay = recentBytesPerDay
        self.baselineBytesPerDay = baselineBytesPerDay
        self.accelerationFactor = accelerationFactor
        self.isAlerting = isAlerting
    }

    public static let none = GrowthSummary(
        deltaBytes: 0,
        windowSeconds: 0,
        recentBytesPerDay: 0,
        baselineBytesPerDay: 0,
        accelerationFactor: nil,
        isAlerting: false
    )
}

public struct WatchedFolder: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var name: String
    public var category: UsageCategory
    public var verdict: Verdict
    public var addedAt: Date
    public var currentBytes: Int64
    /// Oldest first.
    public var samples: [SizeSample]
    public var growth: GrowthSummary

    public var id: String { path }

    public init(
        path: String,
        name: String,
        category: UsageCategory,
        verdict: Verdict,
        addedAt: Date,
        currentBytes: Int64,
        samples: [SizeSample],
        growth: GrowthSummary
    ) {
        self.path = path
        self.name = name
        self.category = category
        self.verdict = verdict
        self.addedAt = addedAt
        self.currentBytes = currentBytes
        self.samples = samples
        self.growth = growth
    }
}

public struct QuickLookItem: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var allocatedBytes: Int64
    public var contentModified: Date?
    public var fileExtension: String?

    public var id: String { path }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        allocatedBytes: Int64,
        contentModified: Date? = nil,
        fileExtension: String? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.allocatedBytes = allocatedBytes
        self.contentModified = contentModified
        self.fileExtension = fileExtension
    }
}

/// What Quick Look shows: for a folder, what is inside it largest first; for a file, the metadata
/// and a hint that the client should hand the path to the system previewer instead.
public struct QuickLookReport: Codable, Sendable {
    public var entry: Entry
    public var items: [QuickLookItem]
    /// True when `items` was cut short by `QuickLookRequest.limit`.
    public var truncated: Bool
    /// True for files, where the client should use the native previewer for the visual part.
    public var prefersSystemPreview: Bool

    public init(entry: Entry, items: [QuickLookItem], truncated: Bool, prefersSystemPreview: Bool) {
        self.entry = entry
        self.items = items
        self.truncated = truncated
        self.prefersSystemPreview = prefersSystemPreview
    }
}
