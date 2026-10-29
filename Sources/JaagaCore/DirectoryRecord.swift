import Foundation
import JaagaProtocol

/// What the scanner retains about one directory: its recursive totals plus a summary of each
/// immediate child.
///
/// Records are kept per *directory*, never per file, so memory grows with the number of folders
/// rather than the number of files. A `node_modules` tree with a million files still costs only as
/// much as its directory count.
public struct DirectoryRecord: Sendable, Hashable {
    public var path: String
    public var name: String
    /// Allocated (on-disk) bytes for the whole subtree, hard links counted once.
    public var allocatedBytes: Int64
    /// Files plus directories inside, recursive, not counting this directory.
    public var itemCount: Int
    public var directoryCount: Int
    /// Largest first.
    public var children: [ChildRecord]
    public var created: Date?
    public var contentModified: Date?
    public var lastOpened: Date?
    /// Directories inside this subtree the scanner could not open.
    public var unreadable: [UnreadablePath]
    public var scannedAt: Date

    public var isComplete: Bool { unreadable.isEmpty }

    public init(
        path: String,
        name: String,
        allocatedBytes: Int64,
        itemCount: Int,
        directoryCount: Int,
        children: [ChildRecord],
        created: Date?,
        contentModified: Date?,
        lastOpened: Date?,
        unreadable: [UnreadablePath],
        scannedAt: Date
    ) {
        self.path = path
        self.name = name
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.directoryCount = directoryCount
        self.children = children
        self.created = created
        self.contentModified = contentModified
        self.lastOpened = lastOpened
        self.unreadable = unreadable
        self.scannedAt = scannedAt
    }
}

public struct ChildRecord: Sendable, Hashable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var allocatedBytes: Int64
    public var itemCount: Int
    /// `nil` when this child sits below the depth the scan retained records for.
    public var directChildCount: Int?
    /// How many folders inside this child could not be opened.
    ///
    /// Non-zero means `allocatedBytes` is a lower bound. Held per child rather than only for the scan
    /// root, because the number a person reads is usually a child's — the row in the list, the block
    /// in the map, the figure in the inspector — and that is where the caveat has to appear.
    public var unreadableDescendantCount: Int
    public var created: Date?
    public var contentModified: Date?
    public var lastOpened: Date?

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        allocatedBytes: Int64,
        itemCount: Int,
        directChildCount: Int?,
        unreadableDescendantCount: Int = 0,
        created: Date?,
        contentModified: Date?,
        lastOpened: Date?
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.directChildCount = directChildCount
        self.unreadableDescendantCount = unreadableDescendantCount
        self.created = created
        self.contentModified = contentModified
        self.lastOpened = lastOpened
    }
}
