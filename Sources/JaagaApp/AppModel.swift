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
    /// A folder the user asked to open that has not answered yet, once it has taken long enough to be
    /// worth saying so. The previous folder's numbers must not stand in for it meanwhile.
    private(set) var measuringPath: String?
    var isBusy: Bool { requestsInFlight > 0 }
    private var requestsInFlight = 0
    /// The most recent growth alert, shown at the top of the Watched view until dismissed.
    private(set) var growthAlert: WatchAlertEvent?
    private(set) var errorMessage: String?
    private(set) var lastScanAt: Date?

    private let launcher = DaemonLauncher()
    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    /// Bumped by every navigation, so an answer for a folder the user has since left is dropped.
    private var navigationToken = 0
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
            // The daemon only tells the client that asked which request a scan belongs to; scans for
            // other clients and the hourly re-measure are not this window's to report.
            guard progress.requestID != nil else { return }
            scanProgress = progress
        case .scanCompleted(let completed):
            guard completed.requestID != nil else { return }
            scanProgress = nil
            lastScanAt = Date()
        case .folderChanged(let changed):
            // Something moved underneath us. Re-read the folder on screen if it was affected, so the
            // window never shows a total that is known to be wrong. The daemon has already dropped
            // what changed from its cache, so this is a plain read, not a forced rescan.
            guard let folder = currentFolder else { return }
            let affected = changed.paths.contains { folder.path == $0 || folder.path.hasPrefix($0 + "/") || $0.hasPrefix(folder.path + "/") }
            guard affected else { return }
            Task { await self.reload(refresh: false) }
        case .watchUpdated(let updated):
            if let index = watchedFolders.firstIndex(where: { $0.path == updated.folder.path }) {
                watchedFolders[index] = updated.folder
            } else {
                watchedFolders.append(updated.folder)
            }
            watchedFolders.sort { $0.currentBytes > $1.currentBytes }
            refreshStarsInPlace()
        case .watchRemoved(let removed):
            watchedFolders.removeAll { $0.path == removed.path }
            refreshStarsInPlace()
        case .watchAlert(let alert):
            growthAlert = alert
        }
    }

    /// Re-reads the entry the inspector is showing and the listing's stars, so a star toggled from
    /// another client (or another window) changes here too.
    private func refreshStarsInPlace() {
        let watched = Set(watchedFolders.map(\.path))
        if var listing {
            for index in listing.children.indices {
                listing.children[index].isWatched = watched.contains(listing.children[index].path)
            }
            listing.folder.isWatched = watched.contains(listing.folder.path)
            self.listing = listing
        }
        if var selection {
            selection.isWatched = watched.contains(selection.path)
            self.selection = selection
        }
        if var report = suspectReport {
            for index in report.suspects.indices {
                report.suspects[index].isWatched = report.suspects[index].paths.allSatisfy(watched.contains)
            }
            suspectReport = report
        }
    }

    func dismissGrowthAlert() {
        growthAlert = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Navigation

    /// Navigates to `path`. A newer navigation supersedes this one: its request is cancelled, so the
    /// daemon stops measuring a folder nobody is waiting for, and a late answer is never shown.
    func open(path: String, pushHistory: Bool = true, refresh: Bool = false) async {
        guard let client else { return }
        navigationTask?.cancel()
        navigationToken += 1
        let token = navigationToken
        let departing = currentFolder?.path
        view = .spaceMap
        searchText = ""

        let task = Task {
            await self.whileMeasuring(path, token: token) {
                await self.run {
                    let listing = try await client.listFolder(path: path, refresh: refresh)
                    guard self.navigationToken == token else { return }
                    if pushHistory, let departing, departing != listing.folder.path {
                        self.history.append(departing)
                    }
                    self.show(listing)
                    // Land the selection on the biggest child, which is what the user came to look at.
                    self.selection = listing.children.first ?? listing.folder
                }
            }
        }
        navigationTask = task
        await task.value

        // The sidebar's coloured bar is derived from the home folder's measurement, so it only has
        // something to show once that measurement exists.
        if navigationToken == token, currentFolder?.path == homePath {
            await loadVolumeSummary()
        }
    }

    /// Runs `work`, and if it is still going after a moment marks `path` as being measured. Cleared
    /// whether the work succeeded, failed or was cancelled, so a failed scan never leaves the window
    /// saying it is still measuring.
    private func whileMeasuring(_ path: String, token: Int, _ work: () async -> Void) async {
        let reveal = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self.navigationToken == token else { return }
            self.measuringPath = path
        }
        await work()
        reveal.cancel()
        if navigationToken == token {
            measuringPath = nil
        }
    }

    private func show(_ listing: FolderListing) {
        self.listing = listing
        lastScanAt = listing.scannedAt
        rebuildBreadcrumb(for: listing)
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

    /// Re-reads the folder on screen in place: the view, the search and the selection stay as they
    /// are, apart from a selected item that no longer exists. A folder that has itself gone away hands
    /// over to its parent.
    func reload(refresh: Bool = true) async {
        guard let client, let folder = currentFolder else { return }
        let token = navigationToken
        var vanished = false
        await run {
            do {
                let listing = try await client.listFolder(path: folder.path, refresh: refresh)
                guard self.navigationToken == token, self.currentFolder?.path == folder.path else { return }
                self.show(listing)
                self.reselect(in: listing)
            } catch let failure as ProtocolFailure where failure.code == .notFound {
                vanished = true
            }
        }
        if vanished, navigationToken == token {
            await open(path: (folder.path as NSString).deletingLastPathComponent, pushHistory: false)
            selection = nil
            return
        }
        if refresh {
            await loadSuspects(refresh: true)
            await loadVolumeSummary(refresh: true)
        }
    }

    /// Swaps the selection for its fresh copy when it belongs to this listing, or drops it when it is
    /// gone. A selection from elsewhere, such as the suspects view, is left alone.
    private func reselect(in listing: FolderListing) {
        guard let selected = selection else { return }
        if selected.path == listing.folder.path {
            selection = listing.folder
        } else if (selected.path as NSString).deletingLastPathComponent == listing.folder.path {
            selection = listing.children.first { $0.path == selected.path }
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

    /// Moves the entry the user confirmed to the Trash. Only ever called from that confirmation, with
    /// the entry it showed — never whatever happens to be selected by the time the button is pressed.
    ///
    /// Nothing else is selected afterwards: an unrelated item must not slide under the same button.
    func moveToTrash(_ entry: Entry) async {
        guard let client else { return }
        var trashed = false
        await run {
            _ = try await client.moveToTrash(path: entry.path, confirmed: true)
            trashed = true
        }
        guard trashed else { return }

        let gone: (String) -> Bool = { $0 == entry.path || $0.hasPrefix(entry.path + "/") }
        if let selected = selection, gone(selected.path) { selection = nil }
        history.removeAll(where: gone)
        if let folder = currentFolder, gone(folder.path) {
            await open(path: (entry.path as NSString).deletingLastPathComponent, pushHistory: false)
            selection = nil
        } else {
            await reload(refresh: false)
        }
        await run {
            self.watchedFolders = try await client.watched()
            self.suspectReport = try await client.suspects()
        }
        volumeSummary = try? await client.volumeSummary(refresh: true)
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
    ///
    /// When the last piece of work finishes, any scan progress still showing is cleared: the daemon only
    /// announces a scan that completed, so one that failed or was cancelled would otherwise leave
    /// "Measuring…" up for good.
    private func run(_ work: () async throws -> Void) async {
        requestsInFlight += 1
        defer {
            requestsInFlight -= 1
            if requestsInFlight == 0 { scanProgress = nil }
        }
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
