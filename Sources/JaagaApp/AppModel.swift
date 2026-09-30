import Foundation
import JaagaLayout
import JaagaProtocol
import Observation
import SwiftUI

/// Everything the window renders, and the only place that talks to the daemon.
///
/// The app holds no filesystem knowledge of its own: sizes, verdicts, reasons and growth all arrive
/// from the daemon already decided. This class navigates, caches the last answer so the interface does
/// not blink, and forwards the user's actions back.
@MainActor
@Observable
final class AppModel {
    enum View: Hashable {
        case spaceMap
        case suspects
        case watched
    }

    enum Sort: Hashable {
        case largest
        case leastUsed
    }

    enum SuspectFilter: Hashable {
        case all
        case safeToClear
        case reviewFirst
    }

    enum Connection {
        case connecting
        case ready(DaemonLauncher.Mode)
        case failed(String)
    }

    // MARK: - Navigation

    var view: View = .spaceMap
    /// The path from the starting location to the folder on screen, for the breadcrumb.
    private(set) var breadcrumb: [Entry] = []
    private(set) var selection: Entry?
    var sort: Sort = .largest
    var suspectFilter: SuspectFilter = .all
    var searchText = ""
    var isQuickLookPresented = false

    // MARK: - Data from the daemon

    private(set) var connection: Connection = .connecting
    private(set) var listing: FolderListing?
    private(set) var suspectReport: SuspectReport?
    private(set) var watchedFolders: [WatchedFolder] = []
    private(set) var volumes: [VolumeInfo] = []
    private(set) var volumeSummary: VolumeSummary?
    private(set) var quickLookReport: QuickLookReport?
    private(set) var homePath = NSHomeDirectory()

    /// The folder currently being measured, with its running counts, or nil when nothing is scanning.
    private(set) var scanProgress: ScanProgressEvent?
    private(set) var isBusy = false
    /// The most recent growth alert, shown at the top of the Watched view until dismissed.
    private(set) var growthAlert: WatchAlertEvent?
    private(set) var errorMessage: String?
    private(set) var lastScanAt: Date?

    private let launcher = DaemonLauncher()
    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    /// Folders visited on the way here, so the toolbar's back button can retrace them.
    private var history: [String] = []

    // MARK: - Derived

    var currentFolder: Entry? { listing?.folder }

    /// The children to show, sorted and filtered by the search field.
    var visibleChildren: [Entry] {
        guard let children = listing?.children else { return [] }
        let filtered = searchText.isEmpty
            ? children
            : children.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        return switch sort {
        case .largest:
            filtered
        case .leastUsed:
            // Never-opened folders sort as the oldest, because "no recorded use" is the strongest
            // hint that nobody will miss it.
            filtered.sorted { left, right in
                let leftDate = left.lastOpened ?? .distantPast
                let rightDate = right.lastOpened ?? .distantPast
                if leftDate != rightDate { return leftDate < rightDate }
                return left.allocatedBytes > right.allocatedBytes
            }
        }
    }

    /// Tonal shade per child, so siblings of one category read as shades of one hue.
    var childShades: [String: Int] {
        ShadeRank.ranks(for: listing?.children ?? [])
    }

    var filteredSuspects: [Suspect] {
        guard let suspects = suspectReport?.suspects else { return [] }
        return switch suspectFilter {
        case .all: suspects
        case .safeToClear: suspects.filter { $0.verdict == .safeToClear }
        case .reviewFirst: suspects.filter { $0.verdict == .reviewFirst }
        }
    }

    var suspectsInsideCurrentFolder: (count: Int, bytes: Int64) {
        guard let folder = currentFolder, let suspects = suspectReport?.suspects else { return (0, 0) }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        var count = 0
        var bytes: Int64 = 0
        for suspect in suspects {
            let inside = suspect.paths.filter { $0.hasPrefix(prefix) }
            guard !inside.isEmpty else { continue }
            count += 1
            // An aggregate's bytes cannot be split per path, so attribute the whole row when any of
            // it is inside. The chip says how many suspects live here, not an exact subtotal.
            bytes += suspect.allocatedBytes
        }
        return (count, bytes)
    }

    var startupVolume: VolumeInfo? {
        volumes.first { $0.isStartupDisk } ?? volumes.first
    }

    var canGoBack: Bool { !history.isEmpty || view != .spaceMap }

    /// The share of the startup disk a size represents, for the inspector's "% of Macintosh HD".
    func shareOfDisk(_ bytes: Int64) -> Double {
        guard let total = startupVolume?.totalBytes, total > 0 else { return 0 }
        return Double(bytes) / Double(total)
    }

    // MARK: - Lifecycle

    func connect() async {
        connection = .connecting
        do {
            let (client, hello, mode) = try await launcher.start()
            self.client = client
            homePath = hello.homePath
            connection = .ready(mode)
            listenForEvents(on: client)
            await loadVolumes()
            await open(path: hello.homePath, pushHistory: false)
            await refreshWatched()
            await loadSuspects()
        } catch {
            connection = .failed(String(describing: error))
        }
    }

    func shutDown() {
        eventTask?.cancel()
        navigationTask?.cancel()
        let client = client
        Task { await client?.disconnect() }
        launcher.stopChildProcessIfAny()
    }

    private func listenForEvents(on client: DaemonClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let events = await client.events()

            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .scanProgress(let progress):
            scanProgress = progress
        case .scanCompleted(let completed):
            scanProgress = nil
            lastScanAt = Date()
            _ = completed
        case .folderChanged(let changed):
            // Something moved underneath us. Re-read the folder on screen if it was affected, so the
            // window never shows a total that is known to be wrong.
            guard let folder = currentFolder else { return }
            let affected = changed.paths.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") || $0.hasPrefix(folder.path + "/") }
            guard affected else { return }
            Task { await self.reload(refresh: true) }
        case .watchUpdated(let updated):
            if let index = watchedFolders.firstIndex(where: { $0.path == updated.folder.path }) {
                watchedFolders[index] = updated.folder
            } else {
                watchedFolders.append(updated.folder)
            }
            watchedFolders.sort { $0.currentBytes > $1.currentBytes }
        case .watchAlert(let alert):
            growthAlert = alert
        }
    }

    func dismissGrowthAlert() {
        growthAlert = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Navigation

    func open(path: String, pushHistory: Bool = true, refresh: Bool = false) async {
        guard let client else { return }
        if pushHistory, let current = currentFolder?.path, current != path {
            history.append(current)
        }
        view = .spaceMap
        searchText = ""
        await run {
            let listing = try await client.listFolder(path: path, refresh: refresh)
            self.listing = listing
            self.lastScanAt = listing.scannedAt
            self.rebuildBreadcrumb(for: listing)
            // Land the selection on the biggest child, which is what the user came to look at.
            self.selection = listing.children.first ?? listing.folder
        }
    }

    func openFolder(_ entry: Entry) async {
        guard entry.isDirectory else {
            selection = entry
            return
        }
        await open(path: entry.path)
    }

    func goBack() async {
        if view != .spaceMap {
            view = .spaceMap
            return
        }
        guard let previous = history.popLast() else { return }
        await open(path: previous, pushHistory: false)
    }

    func goToBreadcrumb(_ entry: Entry) async {
        guard entry.path != currentFolder?.path else { return }
        await open(path: entry.path)
    }

    /// Shows a path in the space map, opening its enclosing folder and selecting it.
    func locate(path: String) async {
        let parent = (path as NSString).deletingLastPathComponent
        await open(path: parent.isEmpty ? path : parent)
        await select(path: path)
    }

    func select(_ entry: Entry) {
        selection = entry
    }

    func select(path: String) async {
        guard let client else { return }
        // The listing on screen usually already knows this entry; only ask the daemon when it does not.
        if let child = listing?.children.first(where: { $0.path == path }) {
            selection = child
            return
        }
        if let folder = listing?.folder, folder.path == path {
            selection = folder
            return
        }
        await run {
            self.selection = try await client.entry(path: path)
        }
    }

    func reload(refresh: Bool = true) async {
        guard let folder = currentFolder else { return }
        await open(path: folder.path, pushHistory: false, refresh: refresh)
        if refresh {
            await loadSuspects(refresh: true)
            await loadVolumeSummary(refresh: true)
        }
    }

    private func rebuildBreadcrumb(for listing: FolderListing) {
        // Build the trail from the home folder down, which is the path the user thinks in. Above home
        // the trail is the filesystem's own, ending at the volume root.
        var components: [String] = []
        var path = listing.folder.path
        while path.count > 1 {
            components.insert(path, at: 0)
            if path == homePath { break }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        if components.isEmpty { components = [listing.folder.path] }

        breadcrumb = components.map { component in
            if component == listing.folder.path { return listing.folder }
            return Entry(
                path: component,
                name: component == homePath ? "Home" : (component as NSString).lastPathComponent,
                isDirectory: true,
                allocatedBytes: 0,
                itemCount: 0,
                directChildCount: nil,
                category: .system,
                verdict: .yourData,
                reason: "",
                kind: "Folder"
            )
        }
    }

    // MARK: - Loading

    private func loadVolumes() async {
        guard let client else { return }
        await run {
            let response = try await client.volumes()
            self.volumes = response.volumes
            self.homePath = response.homePath
        }
        await loadVolumeSummary()
    }

    func loadVolumeSummary(refresh: Bool = false) async {
        guard let client else { return }
        // A failure here only costs the sidebar's coloured bar, so it must not surface as an error.
        volumeSummary = try? await client.volumeSummary(refresh: refresh)
    }

    func loadSuspects(refresh: Bool = false) async {
        guard let client else { return }
        await run {
            self.suspectReport = try await client.suspects(refresh: refresh)
        }
    }

    func refreshWatched() async {
        guard let client else { return }
        await run {
            self.watchedFolders = try await client.watched()
        }
    }

    // MARK: - Actions

    func toggleWatch(path: String) async {
        guard let client else { return }
        await run {
            if self.watchedFolders.contains(where: { $0.path == path }) {
                _ = try await client.unwatch(path: path)
            } else {
                _ = try await client.watch(path: path)
            }
            self.watchedFolders = try await client.watched()
            // The star shows in three places, so the listing and the suspects both need re-reading.
            if let folder = self.currentFolder {
                self.listing = try await client.listFolder(path: folder.path)
            }
            self.suspectReport = try await client.suspects()
            if let selected = self.selection {
                self.selection = try? await client.entry(path: selected.path)
            }
        }
    }

    func isWatched(path: String) -> Bool {
        watchedFolders.contains { $0.path == path }
    }

    func reveal(path: String) async {
        guard let client else { return }
        await run { try await client.reveal(path: path) }
    }

    /// Moves a path to the Trash. Only ever called from a confirmation the user answered.
    func moveToTrash(path: String) async {
        guard let client else { return }
        await run {
            _ = try await client.moveToTrash(path: path, confirmed: true)
            if let folder = self.currentFolder {
                self.listing = try await client.listFolder(path: folder.path, refresh: true)
                self.selection = self.listing?.children.first
            }
            self.watchedFolders = try await client.watched()
            self.suspectReport = try await client.suspects(refresh: true)
            self.volumeSummary = try? await client.volumeSummary(refresh: true)
        }
    }

    func loadQuickLook(for entry: Entry) async {
        guard let client else { return }
        await run {
            self.quickLookReport = try await client.quickLook(path: entry.path)
            self.isQuickLookPresented = true
        }
    }

    func closeQuickLook() {
        isQuickLookPresented = false
        quickLookReport = nil
    }

    /// Runs one piece of daemon work, showing it as busy and surfacing any failure in one place.
    private func run(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            errorMessage = nil
        } catch is CancellationError {
            // The user moved on; nothing to report.
        } catch let failure as ProtocolFailure {
            errorMessage = Self.describe(failure)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Turns a daemon failure into something worth reading, with the remedy where there is one.
    static func describe(_ failure: ProtocolFailure) -> String {
        switch failure.code {
        case .notReadable, .notPermitted:
            "\(failure.message)\n\nGrant Jaaga Full Disk Access in System Settings › Privacy & Security "
                + "to measure everything."
        case .confirmationRequired:
            "Jaaga will not remove anything without an explicit confirmation."
        default:
            failure.message
        }
    }
}
