import Foundation

public struct ScanProgressEvent: Codable, Sendable, Hashable {
    /// The request that started this scan, so a client can ignore other clients' scans.
    public var requestID: String?
    public var root: String
    public var currentPath: String
    public var itemsScanned: Int
    public var bytesScanned: Int64

    public init(requestID: String?, root: String, currentPath: String, itemsScanned: Int, bytesScanned: Int64) {
        self.requestID = requestID
        self.root = root
        self.currentPath = currentPath
        self.itemsScanned = itemsScanned
        self.bytesScanned = bytesScanned
    }
}

public struct ScanCompletedEvent: Codable, Sendable, Hashable {
    public var requestID: String?
    public var root: String
    public var allocatedBytes: Int64
    public var itemCount: Int
    public var durationSeconds: Double
    public var unreadableCount: Int

    public init(
        requestID: String?,
        root: String,
        allocatedBytes: Int64,
        itemCount: Int,
        durationSeconds: Double,
        unreadableCount: Int
    ) {
        self.requestID = requestID
        self.root = root
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.durationSeconds = durationSeconds
        self.unreadableCount = unreadableCount
    }
}

/// FSEvents noticed a change under a watched folder, so anything cached below `paths` is stale.
public struct FolderChangedEvent: Codable, Sendable, Hashable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

/// A folder was starred, or an already-watched one was re-measured.
public struct WatchUpdatedEvent: Codable, Sendable, Hashable {
    public var folder: WatchedFolder

    public init(folder: WatchedFolder) {
        self.folder = folder
    }
}

/// A folder stopped being watched.
///
/// Paired with `watchUpdated` so every client sees the same watch list: the app's stars have to change
/// when a CLI unstars something, not only when the app itself does.
public struct WatchRemovedEvent: Codable, Sendable, Hashable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

/// A watched folder is growing much faster than its own recent pace.
public struct WatchAlertEvent: Codable, Sendable, Hashable {
    public var folder: WatchedFolder
    public var accelerationFactor: Double?
    /// Ready-to-show sentence, e.g. "DerivedData is growing 3.1× faster than usual".
    public var message: String

    public init(folder: WatchedFolder, accelerationFactor: Double?, message: String) {
        self.folder = folder
        self.accelerationFactor = accelerationFactor
        self.message = message
    }
}

public enum Event: Sendable {
    case scanProgress(ScanProgressEvent)
    case scanCompleted(ScanCompletedEvent)
    case folderChanged(FolderChangedEvent)
    case watchUpdated(WatchUpdatedEvent)
    case watchRemoved(WatchRemovedEvent)
    case watchAlert(WatchAlertEvent)

    public var name: Name {
        switch self {
        case .scanProgress: .scanProgress
        case .scanCompleted: .scanCompleted
        case .folderChanged: .folderChanged
        case .watchUpdated: .watchUpdated
        case .watchRemoved: .watchRemoved
        case .watchAlert: .watchAlert
        }
    }

    public enum Name: String, Codable, Sendable, CaseIterable {
        case scanProgress
        case scanCompleted
        case folderChanged
        case watchUpdated
        case watchRemoved
        case watchAlert
    }
}
