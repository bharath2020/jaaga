import AppKit
import Foundation
import JaagaCore
import JaagaProtocol

/// Everything the daemon knows how to answer.
///
/// An actor, so the cache and the in-flight registry need no locks of their own. The expensive part —
/// walking the filesystem — is deliberately pushed out to `ScanRunner`, because a scan that ran inside
/// the actor would block every other request behind it for as long as it took.
public actor DaemonService {
    private let configuration: DaemonConfiguration
    private let eventHub: EventHub
    private let scanner: DiskScanner
    private let scanRunner: ScanRunner
    private let classifier: Classifier
    private let suspectFinder: SuspectFinder
    private let volumeInventory = VolumeInventory()
    private let fileActions = FileActions()
    private let watchStore: WatchStore
    private let cache: ScanCache

    /// Requests still running, so `cancel` has something to cancel.
    private var inFlight: [String: Task<Void, Never>] = [:]
    /// Paths currently watched, mirrored so the FSEvents stream can be kept in step.
    private var watchedPaths: Set<String> = []
    private var folderWatcher: FolderWatcher?
    private var samplingTask: Task<Void, Never>?

    /// The last computed suspect report, so switching back to that view is instant.
    private var cachedSuspectReport: SuspectReport?

    public init(configuration: DaemonConfiguration, eventHub: EventHub) throws {
        self.configuration = configuration
        self.eventHub = eventHub
        self.scanner = DiskScanner(configuration: configuration.scan)
        self.scanRunner = ScanRunner(concurrency: configuration.scanConcurrency)
        let catalog = try SuspectCatalog.resolved(overrideURL: configuration.paths.catalogOverridePath)
        self.classifier = Classifier(home: configuration.home, catalog: catalog)
        self.suspectFinder = SuspectFinder(catalog: catalog)
        self.watchStore = WatchStore(fileURL: configuration.paths.watchStatePath)
        self.cache = ScanCache(
            capacity: configuration.cacheCapacity,
            timeToLive: configuration.cacheTimeToLive
        )
    }

    // MARK: - Lifecycle

    /// Brings up the watched-folder machinery: the FSEvents stream and the periodic re-measure.
    public func start() async {
        watchedPaths = Set(await watchStore.watchedPaths)

        if configuration.watchesFileSystem {
            let watcher = FolderWatcher { [weak self] changed in
                guard let self else { return }
                Task { await self.fileSystemChanged(paths: changed) }
            }
            watcher.setWatchedPaths(Array(watchedPaths))
            folderWatcher = watcher
        }

        let interval = configuration.samplingInterval
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                await self.sampleWatchedFolders()
            }
        }
    }

    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        folderWatcher?.stop()
        folderWatcher = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Frame handling

    /// Handles one decoded line from `connection`. Returns once the work is *started*, not finished,
    /// so a long scan never blocks the next request on the same connection.
    public func accept(frame line: Data, from connection: SocketConnection) {
        let frame: RequestFrame
        do {
            frame = try Wire.decode(RequestFrame.self, from: line)
        } catch let failure as ProtocolFailure {
            send(.failure(id: requestID(in: line), failure), to: connection)
            return
        } catch {
            send(
                .failure(
                    id: requestID(in: line),
                    ProtocolFailure(code: .malformedFrame, message: "Could not decode request: \(error)")
                ),
                to: connection
            )
            return
        }

        guard JaagaProtocolVersion.supported.contains(frame.version) else {
            send(
                .failure(
                    id: frame.id,
                    ProtocolFailure(
                        code: .unsupportedProtocolVersion,
                        message: "This daemon speaks protocol version(s) "
                            + JaagaProtocolVersion.supported.map(String.init).joined(separator: ", ")
                            + "; the request asked for \(frame.version)."
                    )
                ),
                to: connection
            )
            return
        }

        // Cancellation has to be answered immediately: queueing it behind the work it is meant to
        // stop would make it useless.
        if case .cancel(let request) = frame.request {
            let cancelled = inFlight.removeValue(forKey: request.requestID)
            cancelled?.cancel()
            send(.response(id: frame.id, .cancel(Acknowledgement(ok: cancelled != nil))), to: connection)
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(frame, for: connection)
            await self.finished(requestID: frame.id)
        }
        inFlight[frame.id] = task
    }

    private func finished(requestID: String) {
        inFlight.removeValue(forKey: requestID)
    }

    private func perform(_ frame: RequestFrame, for connection: SocketConnection) async {
        do {
            let response = try await respond(to: frame.request, requestID: frame.id)
            send(.response(id: frame.id, response), to: connection)
        } catch is CancellationError {
            send(
                .failure(
                    id: frame.id,
                    ProtocolFailure(code: .cancelled, message: "Request \(frame.id) was cancelled.")
                ),
                to: connection
            )
        } catch let failure as ProtocolFailure {
            send(.failure(id: frame.id, failure), to: connection)
        } catch let scanError as ScanError {
            send(.failure(id: frame.id, scanError.asProtocolFailure), to: connection)
        } catch {
            send(
                .failure(
                    id: frame.id,
                    ProtocolFailure(code: .internalError, message: String(describing: error))
                ),
                to: connection
            )
        }
    }

    /// The whole request surface. Kept in one place so the protocol document has one thing to mirror.
    public func respond(to request: Request, requestID: String? = nil) async throws -> Response {
        switch request {
        case .hello(let parameters):
            return .hello(try hello(parameters))

        case .volumes:
            return .volumes(
                VolumesResponse(volumes: volumeInventory.volumes(), homePath: configuration.home)
            )

        case .volumeSummary(let parameters):
            return .volumeSummary(try await volumeSummary(parameters, requestID: requestID))

        case .listFolder(let parameters):
            return .listFolder(try await listFolder(parameters, requestID: requestID))

        case .entry(let parameters):
            return .entry(try await entry(at: parameters.path, requestID: requestID))

        case .suspects(let parameters):
            return .suspects(try await suspects(parameters, requestID: requestID))

        case .watch(let parameters):
            return .watch(try await watch(path: parameters.path, requestID: requestID))

        case .unwatch(let parameters):
            return .unwatch(Acknowledgement(ok: try await unwatch(path: parameters.path)))

        case .watched:
            return .watched(WatchedResponse(folders: try await watchedFolders()))

        case .quickLook(let parameters):
            return .quickLook(try await quickLook(parameters, requestID: requestID))

        case .reveal(let parameters):
            try reveal(path: parameters.path)
            return .reveal(Acknowledgement())

        case .moveToTrash(let parameters):
            return .moveToTrash(try await moveToTrash(parameters))

        case .cancel(let parameters):
            let cancelled = inFlight.removeValue(forKey: parameters.requestID)
            cancelled?.cancel()
            return .cancel(Acknowledgement(ok: cancelled != nil))
        }
    }

    // MARK: - hello

    private func hello(_ parameters: HelloRequest) throws -> HelloResponse {
        guard JaagaProtocolVersion.supported.contains(parameters.protocolVersion) else {
            throw ProtocolFailure(
                code: .unsupportedProtocolVersion,
                message: "\(parameters.clientName) asked for protocol version "
                    + "\(parameters.protocolVersion); this daemon speaks "
                    + JaagaProtocolVersion.supported.map(String.init).joined(separator: ", ") + "."
            )
        }
        return HelloResponse(
            protocolVersion: JaagaProtocolVersion.current,
            supportedProtocolVersions: JaagaProtocolVersion.supported,
            daemonVersion: configuration.daemonVersion,
            homePath: configuration.home,
            socketPath: configuration.paths.socketPath
        )
    }

    // MARK: - Folders

    private func listFolder(_ parameters: ListFolderRequest, requestID: String?) async throws -> FolderListing {
        let path = Self.normalize(parameters.path)
        if parameters.refresh {
            cache.invalidateSubtree(path)
            cachedSuspectReport = nil
        }

        if let cached = cache.record(for: path) {
            return await listing(from: cached, fromCache: true)
        }

        let record = try await measureDirectory(at: path, requestID: requestID)
        return await listing(from: record, fromCache: false)
    }

    private func listing(from record: DirectoryRecord, fromCache: Bool) async -> FolderListing {
        let watched = watchedPaths
        var children: [Entry] = []
        children.reserveCapacity(record.children.count)
        for child in record.children {
            children.append(entry(from: child, isWatched: watched.contains(child.path)))
        }

        let parent = (record.path as NSString).deletingLastPathComponent
        return FolderListing(
            folder: entry(from: record, isWatched: watched.contains(record.path)),
            children: children,
            parentPath: (parent == record.path || parent.isEmpty) ? nil : parent,
            scannedAt: record.scannedAt,
            fromCache: fromCache,
            complete: record.unreadable.isEmpty,
            unreadable: record.unreadable
        )
    }

    private func entry(at path: String, requestID: String?) async throws -> Entry {
        let normalized = Self.normalize(path)

        if let record = cache.record(for: normalized) {
            return entry(from: record, isWatched: watchedPaths.contains(normalized))
        }

        // The parent's cached listing already knows this child's size; use it rather than paying for
        // a fresh scan just to fill an inspector.
        let parentPath = (normalized as NSString).deletingLastPathComponent
        if let parent = cache.record(for: parentPath),
           let child = parent.children.first(where: { $0.path == normalized }) {
            return entry(from: child, isWatched: watchedPaths.contains(normalized))
        }

        var info = stat()
        guard lstat(normalized, &info) == 0 else {
            throw ProtocolFailure(
                code: .notFound,
                message: "No such file or directory",
                path: normalized,
                errnoCode: errno
            )
        }

        if (info.st_mode & S_IFMT) == S_IFDIR {
            let record = try await measureDirectory(at: normalized, requestID: requestID)
            return entry(from: record, isWatched: watchedPaths.contains(normalized))
        }

        return entry(from: fileChildRecord(path: normalized, info: info), isWatched: watchedPaths.contains(normalized))
    }

    /// Measures a directory, serving from the cache when it can and scanning when it cannot.
    private func measureDirectory(at path: String, requestID: String?) async throws -> DirectoryRecord {
        if let cached = cache.record(for: path) { return cached }

        let scanner = self.scanner
        let hub = self.eventHub
        let started = Date()
        let outcome = try await scanRunner.run { isCancelled in
            try scanner.scan(
                rootPath: path,
                onProgress: { progress in
                    hub.publish(
                        .scanProgress(
                            ScanProgressEvent(
                                requestID: requestID,
                                root: path,
                                currentPath: progress.currentPath,
                                itemsScanned: progress.itemsScanned,
                                bytesScanned: progress.bytesScanned
                            )
                        )
                    )
                },
                isCancelled: isCancelled
            )
        }

        cache.store(outcome.records)
        eventHub.publish(
            .scanCompleted(
                ScanCompletedEvent(
                    requestID: requestID,
                    root: path,
                    allocatedBytes: outcome.root.allocatedBytes,
                    itemCount: outcome.root.itemCount,
                    durationSeconds: Date().timeIntervalSince(started),
                    unreadableCount: outcome.unreadable.count
                )
            )
        )
        return outcome.root
    }

    // MARK: - Volume summary

    private func volumeSummary(_ parameters: VolumeSummaryRequest, requestID: String?) async throws -> VolumeSummary {
        let volumes = volumeInventory.volumes()
        let volume: VolumeInfo
        if let mountPath = parameters.mountPath {
            guard let match = volumes.first(where: { $0.mountPath == Self.normalize(mountPath) }) else {
                throw ProtocolFailure(code: .notFound, message: "No mounted volume at that path", path: mountPath)
            }
            volume = match
        } else {
            guard let startup = volumes.first(where: \.isStartupDisk) ?? volumes.first else {
                throw ProtocolFailure(code: .internalError, message: "No volumes are mounted")
            }
            volume = startup
        }

        // The breakdown is built from the home folder, the one tree Jaaga can read without special
        // permission. Everything else on the volume becomes a single "System & apps" remainder rather
        // than pretending to a detail we have not measured.
        let homeRecord: DirectoryRecord?
        if parameters.refresh {
            cache.invalidateSubtree(configuration.home)
            homeRecord = try? await measureDirectory(at: configuration.home, requestID: requestID)
        } else {
            homeRecord = cache.record(for: configuration.home)
        }

        guard let homeRecord, volumeInventory.volume(containing: configuration.home)?.mountPath == volume.mountPath else {
            return VolumeSummary(volume: volume, segments: [], accountedBytes: 0, measuredAt: nil)
        }

        var byCategory: [UsageCategory: Int64] = [:]
        for child in homeRecord.children {
            let classification = classifier.classify(path: child.path, isDirectory: child.isDirectory)
            byCategory[classification.category, default: 0] += child.allocatedBytes
        }

        var segments = byCategory
            .filter { $0.value > 0 }
            .map { CategorySegment(label: Self.label(for: $0.key), category: $0.key, bytes: $0.value) }
            .sorted { $0.bytes > $1.bytes }

        let remainder = volume.usedBytes - homeRecord.allocatedBytes
        if remainder > 0 {
            segments.append(
                CategorySegment(label: "System & apps", category: .system, bytes: remainder)
            )
        }

        return VolumeSummary(
            volume: volume,
            segments: segments,
            accountedBytes: segments.reduce(0) { $0 + $1.bytes },
            measuredAt: homeRecord.scannedAt
        )
    }

    private static func label(for category: UsageCategory) -> String {
        switch category {
        case .cache: "Library & caches"
        case .media: "Movies & music"
        case .dev: "Code"
        case .apps: "Apps & app data"
        case .docs: "Documents"
        case .downloads: "Downloads"
        case .photos: "Photos"
        case .system: "Other"
        }
    }

    // MARK: - Usual suspects

    private func suspects(_ parameters: SuspectsRequest, requestID: String?) async throws -> SuspectReport {
        if !parameters.refresh, let cached = cachedSuspectReport { return cached }

        let root = Self.normalize(parameters.root ?? configuration.home)
        if parameters.refresh {
            cachedSuspectReport = nil
        }

        let finder = self.suspectFinder
        let matches = try await scanRunner.run { _ in finder.discover(root: root) }

        var suspects: [Suspect] = []
        var unreadable: [UnreadablePath] = []
        let watched = watchedPaths

        for match in matches {
            var bytes: Int64 = 0
            var items = 0

            if match.pathsAreDirectories {
                for path in match.paths {
                    if parameters.refresh { cache.invalidateSubtree(path) }
                    do {
                        let record = try await measureDirectory(at: path, requestID: requestID)
                        bytes += record.allocatedBytes
                        items += record.itemCount
                        unreadable.append(contentsOf: record.unreadable)
                    } catch let failure as ProtocolFailure {
                        unreadable.append(
                            UnreadablePath(path: path, reason: failure.message, errnoCode: failure.errnoCode)
                        )
                    } catch let error as ScanError {
                        let failure = error.asProtocolFailure
                        unreadable.append(
                            UnreadablePath(path: path, reason: failure.message, errnoCode: failure.errnoCode)
                        )
                    }
                }
            } else {
                // Individual files: a stat each, no traversal.
                for path in match.paths {
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    bytes += Int64(info.st_blocks) * 512
                    items += 1
                }
            }

            guard bytes > 0 else { continue }

            suspects.append(
                Suspect(
                    id: match.rule.id,
                    title: match.rule.title,
                    displayPath: match.displayPath,
                    paths: match.paths,
                    category: match.rule.category,
                    verdict: match.rule.verdict,
                    reason: match.rule.reason(matchCount: match.paths.count),
                    kind: match.rule.kind,
                    allocatedBytes: bytes,
                    itemCount: items,
                    isWatched: match.paths.allSatisfy(watched.contains),
                    isAggregate: match.rule.isAggregate || match.paths.count > 1
                )
            )
        }

        suspects.sort { $0.allocatedBytes > $1.allocatedBytes }

        let report = SuspectReport(
            suspects: suspects,
            totalBytes: suspects.reduce(0) { $0 + $1.allocatedBytes },
            safeToClearBytes: suspects
                .filter { $0.verdict == .safeToClear }
                .reduce(0) { $0 + $1.allocatedBytes },
            scannedAt: Date(),
            unreadable: unreadable
        )
        cachedSuspectReport = report
        return report
    }

    // MARK: - Watching

    private func watch(path: String, requestID: String?) async throws -> WatchedFolder {
        let normalized = Self.normalize(path)
        var info = stat()
        guard lstat(normalized, &info) == 0 else {
            throw ProtocolFailure(
                code: .notFound,
                message: "Cannot watch something that is not there",
                path: normalized,
                errnoCode: errno
            )
        }

        let bytes: Int64
        if (info.st_mode & S_IFMT) == S_IFDIR {
            bytes = try await measureDirectory(at: normalized, requestID: requestID).allocatedBytes
        } else {
            bytes = Int64(info.st_blocks) * 512
        }

        try await watchStore.watch(path: normalized, currentBytes: bytes)
        watchedPaths.insert(normalized)
        folderWatcher?.setWatchedPaths(Array(watchedPaths))
        cachedSuspectReport = nil

        guard let folder = try await watchedFolders().first(where: { $0.path == normalized }) else {
            throw ProtocolFailure(code: .internalError, message: "Watched folder vanished while being saved", path: normalized)
        }
        // Announced so every other client's stars change too, not just the one that asked.
        eventHub.publish(.watchUpdated(WatchUpdatedEvent(folder: folder)))
        return folder
    }

    private func unwatch(path: String) async throws -> Bool {
        let normalized = Self.normalize(path)
        let removed = try await watchStore.unwatch(path: normalized)
        watchedPaths.remove(normalized)
        folderWatcher?.setWatchedPaths(Array(watchedPaths))
        cachedSuspectReport = nil
        if removed {
            eventHub.publish(.watchRemoved(WatchRemovedEvent(path: normalized)))
        }
        return removed
    }

    private func watchedFolders() async throws -> [WatchedFolder] {
        let records = await watchStore.allRecords()
        let analyzer = configuration.growth
        return records.map { record in
            let classification = classifier.classify(path: record.path, isDirectory: true)
            return WatchedFolder(
                path: record.path,
                name: (record.path as NSString).lastPathComponent,
                category: classification.category,
                verdict: classification.verdict,
                addedAt: record.addedAt,
                currentBytes: record.latestBytes,
                samples: record.samples,
                growth: analyzer.summarize(samples: record.samples)
            )
        }
        .sorted { $0.currentBytes > $1.currentBytes }
    }

    /// Re-measures every watched folder and reports what changed.
    public func sampleWatchedFolders() async {
        let paths = await watchStore.watchedPaths
        for path in paths {
            cache.invalidateSubtree(path)
            guard let record = try? await measureDirectory(at: path, requestID: nil) else { continue }
            guard let updated = try? await watchStore.addSample(path: path, bytes: record.allocatedBytes) else {
                continue
            }

            let classification = classifier.classify(path: path, isDirectory: true)
            let summary = configuration.growth.summarize(samples: updated.samples)
            let folder = WatchedFolder(
                path: path,
                name: (path as NSString).lastPathComponent,
                category: classification.category,
                verdict: classification.verdict,
                addedAt: updated.addedAt,
                currentBytes: updated.latestBytes,
                samples: updated.samples,
                growth: summary
            )

            eventHub.publish(.watchUpdated(WatchUpdatedEvent(folder: folder)))
            if summary.isAlerting {
                eventHub.publish(
                    .watchAlert(
                        WatchAlertEvent(
                            folder: folder,
                            accelerationFactor: summary.accelerationFactor,
                            message: configuration.growth.alertMessage(name: folder.name, summary: summary)
                        )
                    )
                )
            }
        }
    }

    /// FSEvents saw something change under a watched folder.
    private func fileSystemChanged(paths: [String]) async {
        for path in paths {
            cache.invalidateSubtree(path)
        }
        cachedSuspectReport = nil
        eventHub.publish(.folderChanged(FolderChangedEvent(paths: paths)))
    }

    // MARK: - Quick Look

    private func quickLook(_ parameters: QuickLookRequest, requestID: String?) async throws -> QuickLookReport {
        let path = Self.normalize(parameters.path)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw ProtocolFailure(
                code: .notFound,
                message: "No such file or directory",
                path: path,
                errnoCode: errno
            )
        }

        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            // A file: the client should hand the path to the system previewer, which can actually
            // render it. All the daemon usefully adds is the metadata and the verdict.
            return QuickLookReport(
                entry: entry(from: fileChildRecord(path: path, info: info), isWatched: watchedPaths.contains(path)),
                items: [],
                truncated: false,
                prefersSystemPreview: true
            )
        }

        let record = try await measureDirectory(at: path, requestID: requestID)
        let limit = max(1, parameters.limit)
        let items = record.children.prefix(limit).map { child in
            QuickLookItem(
                name: child.name,
                path: child.path,
                isDirectory: child.isDirectory,
                allocatedBytes: child.allocatedBytes,
                contentModified: child.contentModified,
                fileExtension: child.isDirectory
                    ? nil
                    : (child.name as NSString).pathExtension.isEmpty ? nil : (child.name as NSString).pathExtension
            )
        }

        return QuickLookReport(
            entry: entry(from: record, isWatched: watchedPaths.contains(path)),
            items: items,
            truncated: record.children.count > limit,
            prefersSystemPreview: false
        )
    }

    // MARK: - Actions

    private func reveal(path: String) throws {
        let normalized = Self.normalize(path)
        guard FileManager.default.fileExists(atPath: normalized) else {
            throw ProtocolFailure(code: .notFound, message: "Nothing to reveal", path: normalized)
        }
        let actions = fileActions
        // NSWorkspace wants the main thread, and the daemon's main thread runs the run loop.
        DispatchQueue.main.async {
            try? actions.reveal(path: normalized)
        }
    }

    private func moveToTrash(_ parameters: TrashRequest) async throws -> TrashResponse {
        let path = Self.normalize(parameters.path)
        let known = cache.record(for: path)?.allocatedBytes
        let response = try fileActions.moveToTrash(
            path: path,
            confirmed: parameters.confirmed,
            knownBytes: known
        )

        // Everything above the deleted item just got smaller, so those totals are wrong now.
        cache.invalidateSubtree(path)
        cachedSuspectReport = nil
        if watchedPaths.contains(path) {
            _ = try? await watchStore.unwatch(path: path)
            watchedPaths.remove(path)
            folderWatcher?.setWatchedPaths(Array(watchedPaths))
            eventHub.publish(.watchRemoved(WatchRemovedEvent(path: path)))
        }
        eventHub.publish(
            .folderChanged(FolderChangedEvent(paths: [(path as NSString).deletingLastPathComponent]))
        )
        return response
    }

    // MARK: - Building protocol entries

    private func entry(from record: DirectoryRecord, isWatched: Bool) -> Entry {
        let classification = classifier.classify(path: record.path, isDirectory: true)
        return Entry(
            path: record.path,
            name: record.name,
            isDirectory: true,
            isSymbolicLink: false,
            allocatedBytes: record.allocatedBytes,
            itemCount: record.itemCount,
            directChildCount: record.children.count,
            category: classification.category,
            verdict: classification.verdict,
            reason: classification.reason,
            kind: classification.kind,
            lastOpened: record.lastOpened,
            contentModified: record.contentModified,
            created: record.created,
            isWatched: isWatched,
            unreadableDescendantCount: record.unreadable.count
        )
    }

    private func entry(from child: ChildRecord, isWatched: Bool) -> Entry {
        let classification = classifier.classify(path: child.path, isDirectory: child.isDirectory)
        return Entry(
            path: child.path,
            name: child.name,
            isDirectory: child.isDirectory,
            isSymbolicLink: child.isSymbolicLink,
            allocatedBytes: child.allocatedBytes,
            itemCount: child.itemCount,
            directChildCount: child.isDirectory ? child.directChildCount : 0,
            category: classification.category,
            verdict: classification.verdict,
            reason: classification.reason,
            kind: classification.kind,
            lastOpened: child.lastOpened,
            contentModified: child.contentModified,
            created: child.created,
            isWatched: isWatched,
            unreadableDescendantCount: child.unreadableDescendantCount
        )
    }

    private func fileChildRecord(path: String, info: stat) -> ChildRecord {
        ChildRecord(
            name: (path as NSString).lastPathComponent,
            path: path,
            isDirectory: false,
            isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK,
            allocatedBytes: Int64(info.st_blocks) * 512,
            itemCount: 1,
            directChildCount: 0,
            created: Date(timespec: info.st_birthtimespec),
            contentModified: Date(timespec: info.st_mtimespec),
            lastOpened: Date(timespec: info.st_atimespec)
        )
    }

    // MARK: - Plumbing

    private func send(_ frame: ServerFrame, to connection: SocketConnection) {
        guard let data = try? Wire.frame(frame) else { return }
        connection.send(data)
    }

    /// Best-effort id recovery from a frame we could not fully decode, so the client can still match
    /// the failure to the request that caused it.
    private func requestID(in line: Data) -> String? {
        struct IDOnly: Decodable { var id: String? }
        return (try? JSONDecoder().decode(IDOnly.self, from: line))?.id
    }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }
}
