import Foundation
import Testing

@testable import JaagaCore

@Suite("Allocated-size accounting")
struct DiskScannerTests {
    @Test("A folder's size is the sum of what its files occupy on disk")
    func sumsAllocatedSizeOfFiles() throws {
        let tree = try TemporaryTree()
        let first = try tree.file("notes/a.bin", bytes: 4_096)
        let second = try tree.file("notes/b.bin", bytes: 10_000)

        let outcome = try DiskScanner().scan(rootPath: tree.directory("notes").path)

        let expected = tree.allocatedBytes(of: first)
            + tree.allocatedBytes(of: second)
            + tree.allocatedBytes(of: tree.root.appendingPathComponent("notes"))
        #expect(outcome.root.allocatedBytes == expected)
        #expect(outcome.root.itemCount == 2)
    }

    @Test("Allocated size is what the disk gives up, not the file's logical length")
    func measuresAllocatedRatherThanLogicalSize() throws {
        let tree = try TemporaryTree()
        // One byte still costs a whole block, so allocated > logical.
        let tiny = try tree.file("tiny/one-byte", bytes: 1)

        let outcome = try DiskScanner().scan(rootPath: tree.directory("tiny").path)

        let onDisk = tree.allocatedBytes(of: tiny)
        #expect(onDisk > 1, "a one-byte file should occupy at least one block")
        #expect(outcome.root.children.first?.allocatedBytes == onDisk)
    }

    @Test("A hard-linked file is counted once, because deleting one name frees nothing")
    func countsHardLinkedFileOnce() throws {
        let tree = try TemporaryTree()
        try tree.directory("linked")
        let original = try tree.file("linked/original.bin", bytes: 64_000)
        try tree.hardLink("linked/second-name.bin", to: original)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("linked").path)

        let blocks = tree.allocatedBytes(of: original)
        let directoryBytes = tree.allocatedBytes(of: tree.root.appendingPathComponent("linked"))
        #expect(
            outcome.root.allocatedBytes == blocks + directoryBytes,
            "two names for one inode must not be charged twice"
        )
        #expect(outcome.root.itemCount == 2, "both names are still items you can see")

        let charged = outcome.root.children.filter { $0.allocatedBytes > 0 }
        #expect(charged.count == 1, "exactly one of the two names carries the blocks")
    }

    @Test("A symlink contributes its own size and its target is not followed")
    func doesNotFollowSymbolicLinks() throws {
        let tree = try TemporaryTree()
        let outside = try tree.directory("outside")
        try tree.file("outside/huge.bin", bytes: 200_000)
        try tree.directory("inside")
        let link = try tree.symbolicLink("inside/shortcut", to: outside)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("inside").path)

        let insideBytes = tree.allocatedBytes(of: tree.root.appendingPathComponent("inside"))
        #expect(outcome.root.allocatedBytes == tree.allocatedBytes(of: link) + insideBytes)
        #expect(outcome.root.itemCount == 1, "the link is one item; nothing behind it is counted")

        let child = try #require(outcome.root.children.first)
        #expect(child.isSymbolicLink)
        #expect(!child.isDirectory, "a link to a directory is still a link, not a directory")
    }

    @Test("A symlink pointing into the scanned tree cannot cause a loop")
    func symbolicLinkCycleTerminates() throws {
        let tree = try TemporaryTree()
        let root = try tree.directory("loop")
        try tree.file("loop/file.bin", bytes: 1_000)
        try tree.symbolicLink("loop/self", to: root)

        let outcome = try DiskScanner().scan(rootPath: root.path)

        #expect(outcome.root.itemCount == 2)
    }

    @Test(
        "An unreadable folder is reported rather than silently skipped",
        .disabled(if: runningAsRoot, "root can read anything, so this cannot be tested as root")
    )
    func reportsUnreadableFolders() throws {
        let tree = try TemporaryTree()
        try tree.directory("readable")
        try tree.file("readable/ok.bin", bytes: 8_000)
        let locked = try tree.directory("locked")
        try tree.file("locked/hidden.bin", bytes: 500_000)
        try tree.makeUnreadable(locked)

        let outcome = try DiskScanner().scan(rootPath: tree.path)

        #expect(outcome.unreadable.count == 1)
        let unreadable = try #require(outcome.unreadable.first)
        #expect(unreadable.path == locked.path)
        #expect(unreadable.errnoCode == EACCES)
        #expect(!outcome.root.isComplete, "a total missing a folder must not claim to be complete")
        #expect(
            outcome.root.allocatedBytes < 500_000,
            "the locked folder's contents are genuinely not counted — which is why it is reported"
        )
    }

    @Test("Nested directories roll their totals up into their parents")
    func rollsUpNestedTotals() throws {
        let tree = try TemporaryTree()
        try tree.file("project/src/main.swift", bytes: 2_000)
        try tree.file("project/build/output.o", bytes: 40_000)
        try tree.file("project/build/deep/more.o", bytes: 30_000)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("project").path)

        let build = try #require(outcome.root.children.first { $0.name == "build" })
        let source = try #require(outcome.root.children.first { $0.name == "src" })
        #expect(build.allocatedBytes > source.allocatedBytes)
        #expect(build.itemCount == 3, "output.o, deep, and more.o")
        #expect(outcome.root.children.first?.name == "build", "children come back largest first")
        #expect(outcome.root.allocatedBytes >= build.allocatedBytes + source.allocatedBytes)
    }

    @Test("Records are kept only to the configured depth, but totals stay exact")
    func retainsRecordsOnlyToConfiguredDepth() throws {
        let tree = try TemporaryTree()
        try tree.file("a/b/c/d/deep.bin", bytes: 20_000)

        let scanner = DiskScanner(configuration: ScanConfiguration(recordDepth: 1))
        let outcome = try scanner.scan(rootPath: tree.root.appendingPathComponent("a").path)

        #expect(outcome.records[tree.root.appendingPathComponent("a").path] != nil)
        #expect(outcome.records[tree.root.appendingPathComponent("a/b").path] != nil)
        #expect(
            outcome.records[tree.root.appendingPathComponent("a/b/c").path] == nil,
            "depth 2 is past the retention limit"
        )
        #expect(outcome.root.itemCount == 4, "b, c, d and deep.bin are all still counted")
        #expect(outcome.root.allocatedBytes >= 20_000)
    }

    @Test("A cancelled scan throws instead of returning a half-measured tree")
    func cancellationStopsTheScan() throws {
        let tree = try TemporaryTree()
        for index in 0..<200 {
            try tree.file("many/file-\(index).bin", bytes: 1_000)
        }

        // Cancel a handful of entries in, which is the shape of a user hitting Escape mid-scan.
        final class Checks: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func shouldCancel() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count > 5
            }
        }
        let checks = Checks()

        #expect(throws: CancellationError.self) {
            _ = try DiskScanner(configuration: ScanConfiguration(recordDepth: 2, progressInterval: 1))
                .scan(
                    rootPath: tree.root.appendingPathComponent("many").path,
                    isCancelled: { checks.shouldCancel() }
                )
        }
    }

    @Test("Progress is reported while a scan runs")
    func reportsProgress() throws {
        let tree = try TemporaryTree()
        for index in 0..<50 {
            try tree.file("many/file-\(index).bin", bytes: 4_096)
        }

        final class Box: @unchecked Sendable {
            var updates: [ScanProgress] = []
        }
        let box = Box()

        let outcome = try DiskScanner(configuration: ScanConfiguration(recordDepth: 2, progressInterval: 10))
            .scan(rootPath: tree.root.appendingPathComponent("many").path) { progress in
                box.updates.append(progress)
            }

        #expect(box.updates.count >= 4)
        #expect(box.updates.last?.itemsScanned ?? 0 <= outcome.itemsScanned)
        #expect(box.updates.map(\.itemsScanned) == box.updates.map(\.itemsScanned).sorted())
    }

    @Test("Scanning something that is not a directory is an error, not an empty answer")
    func rejectsNonDirectories() throws {
        let tree = try TemporaryTree()
        let file = try tree.file("just-a-file.bin", bytes: 100)

        #expect(throws: ScanError.notADirectory(path: file.path)) {
            _ = try DiskScanner().scan(rootPath: file.path)
        }
    }

    @Test("Scanning a path that does not exist reports notFound")
    func reportsMissingPaths() throws {
        let tree = try TemporaryTree()
        let missing = tree.root.appendingPathComponent("nope").path

        let error = try #require(throws: ScanError.self) {
            _ = try DiskScanner().scan(rootPath: missing)
        }
        #expect(error.asProtocolFailure.code == .notFound)
    }

    @Test("Hidden folders are measured; a cache that starts with a dot still costs the same")
    func includesHiddenEntries() throws {
        let tree = try TemporaryTree()
        try tree.file("home/.gradle/caches/big.bin", bytes: 50_000)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("home").path)

        #expect(outcome.root.children.contains { $0.name == ".gradle" })
        #expect(outcome.root.allocatedBytes >= 50_000)
    }
}

/// The bug the captain hit: a folder showing a size that did not include everything beneath it.
///
/// These check the total against `du`, the tool anybody would reach for to disagree with us, and
/// against depths well past the scanner's record-retention limit — because retaining fewer records is
/// exactly the kind of optimisation that could silently start truncating totals.
@Suite("Recursive totals")
struct RecursiveTotalTests {
    /// `du -sk`, the reference. Returns kilobytes, deduplicating hard links, like the scanner.
    private func duKilobytes(_ path: String) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.split(separator: "\t").first, let value = Int64(first.trimmingCharacters(in: .whitespaces))
        else {
            Issue.record("could not parse du output: \(text)")
            return 0
        }
        return value
    }

    @Test("A folder's size matches what du reports for the same tree")
    func agreesWithDu() throws {
        let tree = try TemporaryTree()
        try tree.file("root/a.bin", bytes: 40_000)
        try tree.file("root/one/b.bin", bytes: 130_000)
        try tree.file("root/one/two/c.bin", bytes: 70_000)
        try tree.file("root/one/two/three/d.bin", bytes: 250_000)
        try tree.file("root/other/e.bin", bytes: 15_000)

        let root = tree.root.appendingPathComponent("root").path
        let outcome = try DiskScanner().scan(rootPath: root)

        // du counts in 1 KB units of 512-byte blocks, which is exactly st_blocks × 512.
        let reference = try duKilobytes(root) * 1_024
        #expect(outcome.root.allocatedBytes == reference)
    }

    @Test("A folder ten levels deep is still counted in its ancestor's total")
    func countsDescendantsPastTheRecordDepth() throws {
        let tree = try TemporaryTree()
        var path = "deep"
        for level in 0..<10 {
            path += "/level-\(level)"
            try tree.file("\(path)/file.bin", bytes: 20_000)
        }
        let root = tree.root.appendingPathComponent("deep").path

        // recordDepth only bounds what is kept in memory; it must not bound what is counted.
        for depth in [0, 1, 2, 5] {
            let outcome = try DiskScanner(configuration: ScanConfiguration(recordDepth: depth))
                .scan(rootPath: root)
            let reference = try duKilobytes(root) * 1_024
            #expect(
                outcome.root.allocatedBytes == reference,
                "recordDepth \(depth) changed the total, which it must never do"
            )
            #expect(outcome.root.itemCount == 20, "ten directories and ten files")
        }
    }

    @Test("A child's reported size is its own whole subtree, not just its immediate contents")
    func childTotalsAreRecursive() throws {
        let tree = try TemporaryTree()
        try tree.file("home/Library/shallow.bin", bytes: 10_000)
        try tree.file("home/Library/Caches/deep/deeper/big.bin", bytes: 400_000)
        try tree.file("home/Documents/doc.bin", bytes: 5_000)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("home").path)

        let library = try #require(outcome.root.children.first { $0.name == "Library" })
        let reference = try duKilobytes(tree.root.appendingPathComponent("home/Library").path) * 1_024
        #expect(
            library.allocatedBytes == reference,
            "the child entry the list and the inspector show must carry the whole subtree"
        )
        #expect(library.allocatedBytes > 400_000, "the deep file dominates and has to be in there")
        #expect(library.itemCount == 5, "shallow.bin, Caches, deep, deeper, big.bin")
    }

    @Test(
        "An unreadable folder is attributed to the child it sits under, not just the scan root",
        .disabled(if: runningAsRoot, "root can read anything")
    )
    func unreadableSubtreesAreAttributedToTheirChild() throws {
        let tree = try TemporaryTree()
        try tree.file("home/Library/readable.bin", bytes: 10_000)
        let locked = try tree.directory("home/Library/Locked")
        try tree.file("home/Library/Locked/hidden.bin", bytes: 900_000)
        try tree.file("home/Documents/doc.bin", bytes: 5_000)
        try tree.makeUnreadable(locked)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("home").path)

        #expect(outcome.unreadable.count == 1)
        let library = try #require(outcome.root.children.first { $0.name == "Library" })
        let documents = try #require(outcome.root.children.first { $0.name == "Documents" })

        #expect(
            library.unreadableDescendantCount == 1,
            "the short total is Library's, so Library is what has to be marked as incomplete"
        )
        #expect(
            documents.unreadableDescendantCount == 0,
            "Documents was measured in full and must not be tarred with Library's brush"
        )
        #expect(library.allocatedBytes < 900_000, "the locked bytes genuinely are not counted")
    }

    @Test(
        "A retained record below the root carries the unreadable paths of its own subtree",
        .disabled(if: runningAsRoot, "root can read anything")
    )
    func nestedRecordsCarryTheirUnreadablePaths() throws {
        let tree = try TemporaryTree()
        let locked = try tree.directory("home/Library/Mail")
        try tree.file("home/Library/Mail/inbox.bin", bytes: 300_000)
        try tree.file("home/Library/Preferences/p.plist", bytes: 2_000)
        try tree.file("home/Documents/doc.bin", bytes: 5_000)
        try tree.makeUnreadable(locked)

        let outcome = try DiskScanner().scan(rootPath: tree.root.appendingPathComponent("home").path)

        // What the daemon serves from cache when ~/Library is opened after a scan of ~.
        let library = try #require(outcome.records[tree.root.appendingPathComponent("home/Library").path])
        #expect(!library.isComplete, "Library's own total is short by Mail, so it must say so")
        #expect(library.unreadable.map(\.path) == [locked.path])

        let documents = try #require(outcome.records[tree.root.appendingPathComponent("home/Documents").path])
        #expect(documents.isComplete, "Documents was measured in full")
        let preferences = try #require(
            outcome.records[tree.root.appendingPathComponent("home/Library/Preferences").path]
        )
        #expect(preferences.isComplete, "a readable sibling of the locked folder is complete")
    }
}

@Suite("Directories reached twice")
struct DuplicateDirectoryTests {
    /// A journaled HFS+ disk image, the one filesystem on which a user can hard-link a directory —
    /// which is the same shape as the startup disk's firmlinks: two paths, one directory.
    private final class HFSImage {
        let folder: URL
        let mountPoint: URL

        init() throws {
            folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("jaaga-hfs-\(UUID().uuidString.prefix(8))", isDirectory: true)
            mountPoint = folder.appendingPathComponent("mnt", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let image = folder.appendingPathComponent("image.dmg").path
            try Self.hdiutil(["create", "-size", "8m", "-fs", "JHFS+", "-volname", "jaaga", "-layout", "NONE", image])
            try Self.hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path, image])
        }

        deinit {
            try? Self.hdiutil(["detach", "-force", mountPoint.path])
            try? FileManager.default.removeItem(at: folder)
        }

        private static func hdiutil(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments[0]) failed"])
            }
        }
    }

    @Test("A second path to a directory already walked is counted once, like a firmlink")
    func countsADirectoryReachedTwiceOnce() throws {
        let image = try HFSImage()
        let real = image.mountPoint.appendingPathComponent("a/real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: image.mountPoint.appendingPathComponent("b"),
            withIntermediateDirectories: true
        )
        let payload = real.appendingPathComponent("payload.bin")
        try Data(count: 1_000_000).write(to: payload)
        let alias = image.mountPoint.appendingPathComponent("b/alias")
        guard link(real.path, alias.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }

        let outcome = try DiskScanner().scan(rootPath: image.mountPoint.path)

        var payloadStat = stat()
        #expect(lstat(payload.path, &payloadStat) == 0)
        let payloadBytes = Int64(payloadStat.st_blocks) * 512
        #expect(outcome.root.allocatedBytes >= payloadBytes)
        #expect(
            outcome.root.allocatedBytes < payloadBytes * 2,
            "the directory behind both paths must be charged once, not once per path"
        )
    }
}
