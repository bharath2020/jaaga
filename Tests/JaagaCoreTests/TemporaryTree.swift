import Foundation
import Testing

/// A throwaway directory tree for tests, removed when the test ends.
///
/// Every helper returns the path it made, so a test reads as a description of the tree it is about
/// to measure.
struct TemporaryTree: ~Copyable {
    let root: URL

    init(name: String = "jaaga-tests") throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Restore permissions first: a 000 directory cannot be removed while it is unreadable.
        if let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in walker {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    var path: String { root.path }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file of exactly `bytes` bytes of zeroes.
    @discardableResult
    func file(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
        return url
    }

    /// A second name for an existing file: same inode, same blocks.
    @discardableResult
    func hardLink(_ relativePath: String, to existing: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: existing, to: url)
        return url
    }

    @discardableResult
    func symbolicLink(_ relativePath: String, to destination: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    func makeUnreadable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// What the filesystem says a path occupies, straight from `lstat`. Tests compare the scanner
    /// against this rather than against a hard-coded number, because block size is the filesystem's
    /// business, not the test's.
    func allocatedBytes(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }
}

/// Running as root defeats permission tests: root can read a 000 directory.
var runningAsRoot: Bool { geteuid() == 0 }
