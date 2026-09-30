import Foundation
import JaagaCore
import JaagaProtocol
import Testing

@testable import JaagaDaemon

/// A daemon running over a real socket against a throwaway home folder.
///
/// The point of these tests is that nothing is faked below the socket: a real `bind`/`connect`, real
/// JSON on the wire, a real scan of a real tree. If the framing, the version check or the request
/// routing were wrong, these would notice, and a CLI written in another language would hit the same
/// wall.
private final class DaemonFixture: Sendable {
    let home: URL
    let daemon: JaagaDaemon
    let client: DaemonClient

    /// A socket under /tmp rather than inside the temporary home: `sockaddr_un` has 103 bytes to play
    /// with and a nested temporary path can exceed it.
    init(configure: (inout DaemonConfiguration) -> Void = { _ in }) throws {
        let id = UUID().uuidString.prefix(8)
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jaaga-daemon-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let supportDirectory = URL(fileURLWithPath: "/tmp/jaaga-t-\(id)", isDirectory: true)
        var configuration = DaemonConfiguration(
            paths: JaagaPaths(supportDirectory: supportDirectory),
            home: home.path,
            // FSEvents would make these tests wait on the filesystem to notice things; the
            // invalidation path is driven directly instead.
            watchesFileSystem: false
        )
        configure(&configuration)

        daemon = try JaagaDaemon(configuration: configuration)
        client = DaemonClient(socketPath: configuration.paths.socketPath, timeout: .seconds(30))
    }

    func start() async throws {
        try await daemon.start()
        try await client.connect(clientName: "JaagaDaemonTests", clientVersion: "test")
    }

    func stop() async {
        await client.disconnect()
        await daemon.stop()
        Self.makeEverythingRemovable(under: home)
        try? FileManager.default.removeItem(at: home)
        try? FileManager.default.removeItem(at: daemon.configuration.paths.supportDirectory)
    }

    /// A directory left at 0o000 by a permissions test cannot be removed until it is readable again.
    private static func makeEverythingRemovable(under root: URL) {
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let relative as String in walker {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent(relative).path
            )
        }
    }

    @discardableResult
    func directory(_ relativePath: String) throws -> URL {
        let url = home.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relativePath: String, bytes: Int) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
        return url
    }

    /// The tree the assertions below describe: a little of everything the app shows.
    func buildSampleTree() throws {
        try file("Library/Caches/Spotify/audio.bin", bytes: 300_000)
        try file("Library/Caches/Homebrew/bottle.tar", bytes: 120_000)
        try file("Library/Developer/Xcode/DerivedData/Atlas-abc/build.o", bytes: 900_000)
        try file("Developer/ledger-web/package.json", bytes: 300)
        try file("Developer/ledger-web/node_modules/left-pad/index.js", bytes: 80_000)
        try file("Developer/ledger-web/src/main.ts", bytes: 4_000)
        try file("Movies/clip.mov", bytes: 500_000)
        try file("Documents/thesis.pdf", bytes: 20_000)
    }
}

/// Runs `body` against a started daemon and always shuts it down afterwards.
///
/// A `defer { Task { ... } }` would let one test's daemon outlive it and fight the next test for the
/// socket, so the fixture's lifetime is a scope instead.
private func withDaemon(
    startDaemon: Bool = true,
    connectClient: Bool = true,
    configure: (inout DaemonConfiguration) -> Void = { _ in },
    _ body: (DaemonFixture) async throws -> Void
) async throws {
    let fixture = try DaemonFixture(configure: configure)
    do {
        if startDaemon {
            if connectClient {
                try await fixture.start()
            } else {
                try await fixture.daemon.start()
            }
        }
        try await body(fixture)
    } catch {
        await fixture.stop()
        throw error
    }
    await fixture.stop()
}

@Suite("Daemon round trip over the socket", .serialized)
struct DaemonRoundTripTests {
    @Test("A client connects, shakes hands on the version, and is told where it is")
    func handshake() async throws {
        try await withDaemon(connectClient: false) { fixture in
            let hello = try await fixture.client.connect(clientName: "test-client", clientVersion: "0.1")

            #expect(hello.protocolVersion == JaagaProtocolVersion.current)
            #expect(hello.supportedProtocolVersions == JaagaProtocolVersion.supported)
            #expect(hello.homePath == fixture.home.path)
            #expect(hello.socketPath == fixture.daemon.socketPath)
        }
    }

    @Test("Listing a folder returns its children largest first, measured on disk")
    func listFolder() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let listing = try await fixture.client.listFolder(path: fixture.home.path)

            #expect(listing.folder.path == fixture.home.path)
            #expect(listing.complete)
            #expect(listing.fromCache == false, "the first look has to measure")
            #expect(listing.unreadable.isEmpty)

            let names = listing.children.map(\.name)
            #expect(Set(names) == Set(["Library", "Developer", "Movies", "Documents"]))
            #expect(
                listing.children.map(\.allocatedBytes) == listing.children.map(\.allocatedBytes).sorted(by: >),
                "children come back largest first so the map and the list agree"
            )
            #expect(listing.children.first?.name == "Library", "1.3 MB of caches outweighs everything else")

            let total = listing.children.reduce(0) { $0 + $1.allocatedBytes }
            #expect(listing.folder.allocatedBytes >= total)
        }
    }

    @Test("Looking at the same folder again is served from cache")
    func cacheMakesReopeningInstant() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let first = try await fixture.client.listFolder(path: fixture.home.path)
            let second = try await fixture.client.listFolder(path: fixture.home.path)

            #expect(first.fromCache == false)
            #expect(second.fromCache, "walking back up a breadcrumb should cost nothing")
            #expect(second.folder.allocatedBytes == first.folder.allocatedBytes)
            #expect(second.scannedAt == first.scannedAt, "the cached answer keeps its original scan time")
        }
    }

    @Test("Rescanning picks up a change the cache would otherwise hide")
    func refreshRemeasures() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let before = try await fixture.client.listFolder(path: fixture.home.path)
            try fixture.file("Movies/another.mov", bytes: 2_000_000)

            let stale = try await fixture.client.listFolder(path: fixture.home.path)
            #expect(stale.folder.allocatedBytes == before.folder.allocatedBytes, "still the cached figure")

            let fresh = try await fixture.client.listFolder(path: fixture.home.path, refresh: true)
            #expect(fresh.fromCache == false)
            #expect(fresh.folder.allocatedBytes > before.folder.allocatedBytes)
        }
    }

    @Test("Classification comes back with the listing, so the app colours nothing itself")
    func listingCarriesVerdicts() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let library = try await fixture.client.listFolder(
                path: fixture.home.appendingPathComponent("Library/Caches").path
            )

            #expect(library.folder.verdict == .safeToClear)
            #expect(library.folder.category == .cache)
            #expect(library.folder.reason.isEmpty == false)
            for child in library.children {
                #expect(child.verdict == .safeToClear, "everything under Caches inherits the verdict")
                #expect(child.category == .cache)
            }
        }
    }

    @Test("The usual suspects are found and totalled")
    func suspects() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let report = try await fixture.client.suspects()

            let ids = Set(report.suspects.map(\.id))
            #expect(ids.contains("user-caches"))
            #expect(ids.contains("xcode-derived-data"))
            #expect(ids.contains("node-modules"))
            #expect(report.totalBytes == report.suspects.reduce(0) { $0 + $1.allocatedBytes })
            #expect(report.safeToClearBytes > 0)
            #expect(report.safeToClearBytes <= report.totalBytes)
            #expect(
                report.suspects.map(\.allocatedBytes) == report.suspects.map(\.allocatedBytes).sorted(by: >)
            )

            let nodeModules = try #require(report.suspects.first { $0.id == "node-modules" })
            #expect(nodeModules.reason.contains("1 project."), "one project, so no stray plural")
            #expect(nodeModules.paths.count == 1)
        }
    }

    @Test("Starring a folder is remembered, and its history is written to disk")
    func watchAndUnwatch() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let caches = fixture.home.appendingPathComponent("Library/Caches").path
            let watched = try await fixture.client.watch(path: caches)

            #expect(watched.path == caches)
            #expect(watched.currentBytes > 0)
            #expect(watched.samples.count == 1)
            #expect(watched.growth.isAlerting == false, "one measurement is not a trend")

            let all = try await fixture.client.watched()
            #expect(all.map(\.path) == [caches])
            #expect(
                FileManager.default.fileExists(atPath: fixture.daemon.configuration.paths.watchStatePath.path),
                "the history has to survive a restart, so it must be on disk already"
            )

            // The listing now reports it as watched, which is what draws the star.
            let listing = try await fixture.client.listFolder(
                path: fixture.home.appendingPathComponent("Library").path,
                refresh: true
            )
            let entry = try #require(listing.children.first { $0.name == "Caches" })
            #expect(entry.isWatched)

            #expect(try await fixture.client.unwatch(path: caches))
            #expect(try await fixture.client.watched().isEmpty)
        }
    }

    @Test("Re-measuring a watched folder adds a sample and reports it as an event")
    func samplingEmitsEvents() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let caches = fixture.home.appendingPathComponent("Library/Caches").path
            let atStar = try await fixture.client.watch(path: caches)

            let events = await fixture.client.events()
            let collector = Task { () -> WatchedFolder? in
                for await event in events {
                    if case .watchUpdated(let updated) = event, updated.folder.path == caches {
                        return updated.folder
                    }
                }
                return nil
            }

            try fixture.file("Library/Caches/Spotify/more-audio.bin", bytes: 400_000)
            await fixture.daemon.sampleWatchedFoldersNow()

            let updated = try #require(await collector.value)
            #expect(
                updated.currentBytes > atStar.currentBytes,
                "the folder grew by 400 KB and the re-measure has to see it"
            )
            // Two measurements seconds apart collapse into one sample on purpose — see
            // `WatchStore.appending` and its own test. What matters here is that the sample was
            // refreshed and announced, not how many rows it left behind.
            #expect(updated.samples.last?.bytes == updated.currentBytes)
            #expect(try await fixture.client.watched().first?.currentBytes == updated.currentBytes)
        }
    }

    @Test("Starring from one client is announced to the others, and so is unstarring")
    func watchChangesReachEveryClient() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let watcher = DaemonClient(socketPath: fixture.daemon.socketPath, timeout: .seconds(30))
            try await watcher.connect(clientName: "observer")
            let events = await watcher.events()

            let caches = fixture.home.appendingPathComponent("Library/Caches").path
            let collector = Task { () -> [Event.Name] in
                var seen: [Event.Name] = []
                for await event in events {
                    switch event {
                    case .watchUpdated(let updated) where updated.folder.path == caches:
                        seen.append(.watchUpdated)
                    case .watchRemoved(let removed) where removed.path == caches:
                        seen.append(.watchRemoved)
                        return seen
                    default:
                        continue
                    }
                }
                return seen
            }

            // A different client does the starring; without the events, the observer's stars would
            // silently disagree with the daemon's list.
            try await fixture.client.watch(path: caches)
            #expect(try await fixture.client.unwatch(path: caches))

            #expect(await collector.value == [.watchUpdated, .watchRemoved])
            await watcher.disconnect()
        }
    }

    @Test("Quick Look on a folder returns what is inside it, largest first")
    func quickLookOnAFolder() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let report = try await fixture.client.quickLook(
                path: fixture.home.appendingPathComponent("Library/Caches").path,
                limit: 1
            )

            #expect(report.prefersSystemPreview == false)
            #expect(report.items.count == 1)
            #expect(report.items.first?.name == "Spotify", "the biggest one first")
            #expect(report.items.first?.isDirectory == true)
            #expect(report.truncated, "there was more than the limit asked for")
            #expect(report.entry.verdict == .safeToClear)
            let allComplete = report.items.allSatisfy { $0.isComplete }
            #expect(allComplete, "nothing here was unreadable")
        }
    }

    @Test("Quick Look on a file hands the rendering back to the system previewer")
    func quickLookOnAFile() async throws {
        try await withDaemon { fixture in
            let clip = try fixture.file("Movies/clip.mov", bytes: 500_000)

            let report = try await fixture.client.quickLook(path: clip.path)

            #expect(report.prefersSystemPreview, "the daemon cannot draw a video; QuickLook can")
            #expect(report.items.isEmpty)
            #expect(report.entry.isDirectory == false)
            #expect(report.entry.allocatedBytes > 0)
        }
    }

    @Test("Moving to the Trash is refused without an explicit confirmation")
    func trashRequiresConfirmation() async throws {
        try await withDaemon { fixture in
            let clip = try fixture.file("Movies/clip.mov", bytes: 100_000)

            let failure = await #expect(throws: ProtocolFailure.self) {
                try await fixture.client.moveToTrash(path: clip.path, confirmed: false)
            }
            #expect(failure?.code == .confirmationRequired)
            #expect(
                FileManager.default.fileExists(atPath: clip.path),
                "a refused deletion must leave the file exactly where it was"
            )
        }
    }

    @Test("A confirmed trash moves the item and leaves the totals ready to be re-measured")
    func trashMovesTheItem() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()
            let clip = try fixture.file("Movies/clip.mov", bytes: 300_000)

            let before = try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Movies").path)
            let response = try await fixture.client.moveToTrash(path: clip.path, confirmed: true)

            #expect(response.originalPath == clip.path)
            #expect(response.reclaimedBytes > 0)
            #expect(FileManager.default.fileExists(atPath: clip.path) == false)
            if let trashed = response.trashedPath {
                #expect(FileManager.default.fileExists(atPath: trashed), "it went to the Trash, not into thin air")
                try? FileManager.default.removeItem(atPath: trashed)
            }

            let after = try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Movies").path)
            #expect(after.fromCache == false, "the enclosing folder's cached total was invalidated")
            #expect(after.folder.allocatedBytes < before.folder.allocatedBytes)
        }
    }

    @Test(
        "An unreadable folder is reported in the listing rather than shrinking the total silently",
        .disabled(if: runningAsRoot, "root can read anything")
    )
    func reportsUnreadableFolders() async throws {
        try await withDaemon { fixture in
            try fixture.file("Readable/ok.bin", bytes: 10_000)
            let locked = try fixture.directory("Locked")
            try fixture.file("Locked/hidden.bin", bytes: 400_000)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            }

            let listing = try await fixture.client.listFolder(path: fixture.home.path)

            #expect(listing.complete == false)
            let unreadable = try #require(listing.unreadable.first)
            #expect(unreadable.path == locked.path)
            #expect(unreadable.errnoCode == EACCES)
            #expect(unreadable.reason.isEmpty == false)
        }
    }

    @Test(
        "A child whose subtree was partly unreadable says so, so its size reads as a lower bound",
        .disabled(if: runningAsRoot, "root can read anything")
    )
    func childrenCarryTheirOwnUnreadableCount() async throws {
        try await withDaemon { fixture in
            try fixture.file("Library/readable.bin", bytes: 10_000)
            let locked = try fixture.directory("Library/Locked")
            try fixture.file("Library/Locked/hidden.bin", bytes: 800_000)
            try fixture.file("Documents/doc.bin", bytes: 5_000)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

            let listing = try await fixture.client.listFolder(path: fixture.home.path)

            let library = try #require(listing.children.first { $0.name == "Library" })
            let documents = try #require(listing.children.first { $0.name == "Documents" })

            #expect(library.unreadableDescendantCount == 1)
            #expect(library.isComplete == false, "the app shows 'at least' for exactly this")
            #expect(documents.isComplete, "a folder measured in full must not be caveated")
            #expect(listing.folder.isComplete == false)

            // Quick Look has to carry it too: a folder nobody could read shows "0 bytes" otherwise,
            // which reads as empty rather than as unmeasured.
            let quickLook = try await fixture.client.quickLook(
                path: fixture.home.appendingPathComponent("Library").path
            )
            let lockedItem = try #require(quickLook.items.first { $0.name == "Locked" })
            #expect(lockedItem.isComplete == false)
            #expect(lockedItem.unreadableDescendantCount == 1)

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
    }

    @Test(
        "A subfolder opened from the cache after its parent's scan is still marked incomplete",
        .disabled(if: runningAsRoot, "root can read anything")
    )
    func cachedSubfolderKeepsItsUnreadableCaveat() async throws {
        try await withDaemon { fixture in
            try fixture.file("Library/Preferences/p.plist", bytes: 2_000)
            let locked = try fixture.directory("Library/Mail")
            try fixture.file("Library/Mail/inbox.bin", bytes: 300_000)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

            _ = try await fixture.client.listFolder(path: fixture.home.path)
            let library = try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Library").path)

            #expect(library.fromCache, "the home scan already measured Library")
            #expect(library.complete == false, "the ~/Library the captain opened must still say 'at least'")
            #expect(library.folder.isComplete == false)
            #expect(library.unreadable.map(\.path) == [locked.path])

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        }
    }

    @Test("Moving to the Trash takes only an absolute path, and never home, above it, or Jaaga's own state")
    func trashRefusesDangerousPaths() async throws {
        try await withDaemon { fixture in
            try fixture.file("Movies/clip.mov", bytes: 1_000)
            let support = fixture.daemon.configuration.paths.supportDirectory.path

            let refused: [(String, ErrorCode)] = [
                ("Movies/clip.mov", .invalidParameters),
                (fixture.home.path, .notPermitted),
                ((fixture.home.path as NSString).deletingLastPathComponent, .notPermitted),
                ("~", .notPermitted),
                (support, .notPermitted),
                (fixture.daemon.configuration.paths.socketPath, .notPermitted),
            ]
            for (path, code) in refused {
                let failure = await #expect(throws: ProtocolFailure.self, "\(path) must be refused") {
                    try await fixture.client.moveToTrash(path: path, confirmed: true)
                }
                #expect(failure?.code == code, "\(path)")
            }
            #expect(FileManager.default.fileExists(atPath: fixture.home.path))
            #expect(FileManager.default.fileExists(atPath: fixture.daemon.configuration.paths.socketPath))
        }
    }

    @Test("A path starting with ~ means the daemon's home, not the account's")
    func tildeMeansTheConfiguredHome() async throws {
        try await withDaemon { fixture in
            let name = "jaaga-tilde-\(UUID().uuidString).bin"
            let file = try fixture.file(name, bytes: 1_000)

            let response = try await fixture.client.moveToTrash(path: "~/\(name)", confirmed: true)

            #expect(response.originalPath == file.path)
            #expect(FileManager.default.fileExists(atPath: file.path) == false)
            if let trashed = response.trashedPath { try? FileManager.default.removeItem(atPath: trashed) }
        }
    }

    @Test("The suspects report answers for the root that was asked about, not the last one measured")
    func suspectsFollowTheirRoot() async throws {
        try await withDaemon { fixture in
            try fixture.file("Library/Caches/app/blob.bin", bytes: 10_000)
            try fixture.file("Other/Library/Caches/app/blob.bin", bytes: 10_000)
            let other = fixture.home.appendingPathComponent("Other").path

            let home = try await fixture.client.suspects()
            let elsewhere = try await fixture.client.suspects(root: other)

            #expect(home.suspects.flatMap(\.paths).allSatisfy { !$0.hasPrefix(other + "/") })
            #expect(!elsewhere.suspects.isEmpty)
            #expect(elsewhere.suspects.flatMap(\.paths).allSatisfy { $0.hasPrefix(other + "/") })
        }
    }

    @Test("A request id belongs to the client that chose it: another client cannot cancel it")
    func requestIDsArePerConnection() async throws {
        try await withDaemon { fixture in
            for index in 0..<8_000 {
                try fixture.file("Huge/dir-\(index % 80)/file-\(index).bin", bytes: 1_024)
            }
            let huge = fixture.home.appendingPathComponent("Huge").path

            let owner = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { owner.close() }
            let stranger = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { stranger.close() }

            try owner.send(#"{"v":1,"id":"1","method":"listFolder","params":{"path":"\#(huge)"}}"#)
            try await Task.sleep(for: .milliseconds(10))
            let cancel = try stranger.exchange(#"{"v":1,"id":"2","method":"cancel","params":{"requestID":"1"}}"#)

            let result = try #require(cancel["result"] as? [String: Any])
            #expect(result["ok"] as? Bool == false, "the stranger has no request 1 to cancel")
            let answer = try owner.receive()
            #expect(answer["type"] as? String == "response", "the owner's scan must run to completion")
        }
    }

    @Test("A cancel sent right behind its request is taken after it, never before")
    func framesAreTakenInOrder() async throws {
        try await withDaemon { fixture in
            for index in 0..<4_000 {
                try fixture.file("Huge/dir-\(index % 40)/file-\(index).bin", bytes: 1_024)
            }
            let huge = fixture.home.appendingPathComponent("Huge").path
            let raw = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { raw.close() }

            // One write, two frames: the order on the wire is the only order there is.
            try raw.send(
                #"{"v":1,"id":"1","method":"listFolder","params":{"path":"\#(huge)"}}"# + "\n"
                    + #"{"v":1,"id":"2","method":"cancel","params":{"requestID":"1"}}"#
            )
            var replies: [String: [String: Any]] = [:]
            while replies.count < 2 {
                let reply = try raw.receive()
                if let id = reply["id"] as? String { replies[id] = reply }
            }

            let cancel = try #require(replies["2"]?["result"] as? [String: Any])
            #expect(cancel["ok"] as? Bool == true, "the request was in flight when its cancel arrived")
            let error = try #require(replies["1"]?["error"] as? [String: Any])
            #expect(error["code"] as? String == ErrorCode.cancelled.rawValue)
        }
    }

    @Test("Scan progress names its request only to the client that made it")
    func progressIsAttributedOnlyToItsOwner() async throws {
        try await withDaemon(configure: { configuration in
            configuration.scan = ScanConfiguration(recordDepth: 2, progressInterval: 4)
        }) { fixture in
            for index in 0..<80 {
                try fixture.file("Many/file-\(index).bin", bytes: 4_096)
            }
            let observer = DaemonClient(socketPath: fixture.daemon.socketPath, timeout: .seconds(30))
            try await observer.connect(clientName: "observer")

            func requestIDs(from events: AsyncStream<Event>) -> Task<[String?], Never> {
                Task {
                    var ids: [String?] = []
                    for await event in events {
                        switch event {
                        case .scanProgress(let progress): ids.append(progress.requestID)
                        case .scanCompleted(let completed):
                            ids.append(completed.requestID)
                            return ids
                        default: continue
                        }
                    }
                    return ids
                }
            }
            let mine = requestIDs(from: await fixture.client.events())
            let theirs = requestIDs(from: await observer.events())

            _ = try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Many").path)

            let ownIDs = await mine.value
            let otherIDs = await theirs.value
            #expect(!ownIDs.isEmpty && ownIDs.allSatisfy { $0 != nil })
            #expect(!otherIDs.isEmpty && otherIDs.allSatisfy { $0 == nil }, "an id means nothing to another client")
            await observer.disconnect()
        }
    }

    @Test("A client that stops reading does not stall the daemon for everyone else")
    func aStuckClientDoesNotBlockOthers() async throws {
        try await withDaemon { fixture in
            let stuck = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { stuck.close() }

            // Far more answer than a socket buffer holds, and never read.
            let requests = (1...400).map { #"{"v":1,"id":"\#($0)","method":"volumes"}"# }
            try stuck.send(requests.joined(separator: "\n"))
            try await Task.sleep(for: .milliseconds(200))

            let answered = try await fixture.client.volumes()
            #expect(!answered.volumes.isEmpty)
        }
    }

    @Test("A listing too big for the request size limit still reaches the client")
    func largeResponsesArrive() async throws {
        try await withDaemon { fixture in
            let longName = String(repeating: "n", count: 200)
            let folder = try fixture.directory("Wide")
            for index in 0..<12_000 {
                FileManager.default.createFile(atPath: folder.appendingPathComponent("\(longName)-\(index)").path, contents: nil)
            }

            let listing = try await fixture.client.listFolder(path: folder.path)

            #expect(listing.children.count == 12_000)
        }
    }

    @Test("A request that outlives the client's timeout fails with timedOut instead of waiting on")
    func timeoutIsEnforced() async throws {
        try await withDaemon { fixture in
            for index in 0..<8_000 {
                try fixture.file("Huge/dir-\(index % 80)/file-\(index).bin", bytes: 1_024)
            }
            let impatient = DaemonClient(socketPath: fixture.daemon.socketPath, timeout: .milliseconds(1))
            _ = try? await impatient.connect(clientName: "impatient")

            await #expect(throws: DaemonClient.ClientError.self) {
                _ = try await impatient.listFolder(path: fixture.home.appendingPathComponent("Huge").path)
            }
            await impatient.disconnect()
        }
    }

    @Test("Asking about a missing path gets notFound, with the path named")
    func missingPath() async throws {
        try await withDaemon { fixture in
            let missing = fixture.home.appendingPathComponent("no-such-folder").path
            let failure = await #expect(throws: ProtocolFailure.self) {
                try await fixture.client.listFolder(path: missing)
            }
            #expect(failure?.code == .notFound)
            #expect(failure?.path == missing)
        }
    }

    @Test("A request for an unsupported protocol version is refused with a clear message")
    func rejectsUnsupportedVersion() async throws {
        try await withDaemon { fixture in
            // Hand-written frame, because the typed client always sends the version it supports.
            let raw = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { raw.close() }
            let reply = try raw.exchange(#"{"v":99,"id":"1","method":"volumes"}"#)

            #expect(reply["type"] as? String == "error")
            #expect(reply["id"] as? String == "1")
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? String == ErrorCode.unsupportedProtocolVersion.rawValue)
            let message = try #require(error["message"] as? String)
            #expect(message.contains("99"), "the message should name the version that was asked for")
        }
    }

    @Test("An unknown method is refused without dropping the connection")
    func rejectsUnknownMethod() async throws {
        try await withDaemon { fixture in
            let raw = try RawSocketClient(socketPath: fixture.daemon.socketPath)
            defer { raw.close() }

            let failure = try raw.exchange(#"{"v":1,"id":"1","method":"listFolders","params":{}}"#)
            let error = try #require(failure["error"] as? [String: Any])
            #expect(error["code"] as? String == ErrorCode.unknownMethod.rawValue)

            // Still usable afterwards: one bad frame must not cost the client its connection.
            let ok = try raw.exchange(#"{"v":1,"id":"2","method":"volumes"}"#)
            #expect(ok["type"] as? String == "response")
            #expect(ok["method"] as? String == "volumes")
        }
    }

    @Test("Volumes are listed, with the startup disk first")
    func listsVolumes() async throws {
        try await withDaemon { fixture in
            let response = try await fixture.client.volumes()

            #expect(response.homePath == fixture.home.path)
            let startup = try #require(response.volumes.first)
            #expect(startup.isStartupDisk, "the startup disk leads the sidebar's Locations list")
            #expect(startup.totalBytes > 0)
            #expect(startup.freeBytes >= 0)
            #expect(startup.freeBytes <= startup.totalBytes)
        }
    }

    @Test("Scan progress is reported while a folder is being measured")
    func reportsScanProgress() async throws {
        try await withDaemon(configure: { configuration in
            configuration.scan = ScanConfiguration(recordDepth: 2, progressInterval: 4)
        }) { fixture in
            for index in 0..<80 {
                try fixture.file("Many/file-\(index).bin", bytes: 4_096)
            }

            let events = await fixture.client.events()
            let collector = Task {
                var progress = 0
                var completed = false
                for await event in events {
                    switch event {
                    case .scanProgress: progress += 1
                    case .scanCompleted: completed = true
                    default: break
                    }
                    if completed { break }
                }
                return (progress, completed)
            }

            _ = try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Many").path)
            let (progressCount, completed) = await collector.value

            #expect(progressCount > 1, "a long scan has to show it is alive")
            #expect(completed)
        }
    }

    @Test("Two clients on one socket both get answers and both see events")
    func servesSeveralClients() async throws {
        try await withDaemon { fixture in
            try fixture.buildSampleTree()

            let second = DaemonClient(socketPath: fixture.daemon.socketPath, timeout: .seconds(30))
            try await second.connect(clientName: "second-client")

            let events = await second.events()
            let collector = Task {
                for await event in events {
                    if case .folderChanged = event { return true }
                }
                return false
            }

            async let first = fixture.client.listFolder(path: fixture.home.path)
            async let other = second.listFolder(path: fixture.home.appendingPathComponent("Library").path)
            let (home, library) = try await (first, other)

            #expect(home.folder.allocatedBytes > 0)
            #expect(library.folder.name == "Library")

            // An action on one connection is announced on the other, which is how two windows stay in step.
            let thesis = fixture.home.appendingPathComponent("Documents/thesis.pdf").path
            let trashed = try await fixture.client.moveToTrash(path: thesis, confirmed: true)
            if let path = trashed.trashedPath { try? FileManager.default.removeItem(atPath: path) }

            #expect(await collector.value, "the other client should hear that something changed")
            await second.disconnect()
        }
    }

    @Test("Cancelling an abandoned request stops the client waiting and leaves the connection usable")
    func cancellingAbandonsTheRequest() async throws {
        try await withDaemon { fixture in
            // Enough files that the scan is still running when the cancellation lands.
            for index in 0..<8_000 {
                try fixture.file("Huge/dir-\(index % 80)/file-\(index).bin", bytes: 1_024)
            }

            let events = await fixture.client.events()
            let scan = Task {
                try await fixture.client.listFolder(path: fixture.home.appendingPathComponent("Huge").path)
            }
            // Cancel once the daemon says the scan is under way, not after a guessed delay: a fast
            // disk finishes this tree in about the time a fixed sleep would wait.
            for await event in events {
                if case .scanProgress = event { break }
            }
            scan.cancel()

            await #expect(throws: CancellationError.self) {
                _ = try await scan.value
            }

            // The connection survives a cancellation, so the next request still works.
            let listing = try await fixture.client.listFolder(path: fixture.home.path)
            #expect(listing.folder.path == fixture.home.path)
        }
    }

    @Test("Cancelling a request that already finished is reported as having cancelled nothing")
    func cancellingAnUnknownRequestIsHonest() async throws {
        try await withDaemon { fixture in
            let raw = try RawSocketClient(socketPath: fixture.daemon.socketPath)

            let reply = try raw.exchange(
                #"{"v":1,"id":"1","method":"cancel","params":{"requestID":"no-such-request"}}"#
            )

            #expect(reply["type"] as? String == "response")
            #expect(reply["method"] as? String == "cancel")
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["ok"] as? Bool == false, "saying it cancelled something it did not would be a lie")
            raw.close()
        }
    }

    @Test("A second daemon refuses to take over a socket that is already being served")
    func refusesToStealTheSocket() async throws {
        try await withDaemon { fixture in
            let intruder = try JaagaDaemon(configuration: fixture.daemon.configuration)

            await #expect(throws: UnixSocketServer.StartError.self) {
                try await intruder.start()
            }
            // The original is still answering.
            #expect(try await fixture.client.volumes().volumes.isEmpty == false)
        }
    }

    @Test("A socket file left behind by a crashed daemon is cleaned up, not treated as a blocker")
    func reclaimsAStaleSocketFile() async throws {
        // The daemon must not be running yet: the point is what it does with a file already there.
        try await withDaemon(startDaemon: false) { fixture in
            let socketPath = fixture.daemon.configuration.paths.socketPath
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: URL(fileURLWithPath: socketPath))

            // Nothing is listening on it, so the daemon should clear it away and bind.
            try await fixture.start()

            #expect(try await fixture.client.volumes().homePath == fixture.home.path)
        }
    }
}

/// Running as root defeats permission tests.
private var runningAsRoot: Bool { geteuid() == 0 }

/// A deliberately dumb client that writes exactly the bytes a test gives it, for checking how the
/// daemon answers frames the typed client would never produce.
private final class RawSocketClient {
    private let descriptor: Int32

    init(socketPath: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw DaemonClient.ClientError.connectionFailed(path: socketPath, errnoCode: errno)
        }
    }

    private var pending = Data()

    /// Sends one line and returns the first non-event frame that comes back.
    func exchange(_ line: String) throws -> [String: Any] {
        try send(line)
        return try receive()
    }

    /// Writes `line` and a newline, without waiting for anything back.
    func send(_ line: String) throws {
        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let written = payload.withUnsafeBufferPointer { write(descriptor, $0.baseAddress! + sent, $0.count - sent) }
            guard written > 0 else { throw DaemonClient.ClientError.disconnected }
            sent += written
        }
    }

    /// Returns the next non-event frame.
    func receive() throws -> [String: Any] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            while let newline = pending.firstIndex(of: 0x0A) {
                let frame = Data(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                    continue
                }
                if object["type"] as? String == "event" { continue }
                return object
            }
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { throw DaemonClient.ClientError.disconnected }
            pending.append(contentsOf: buffer[0..<count])
        }
    }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }
}
