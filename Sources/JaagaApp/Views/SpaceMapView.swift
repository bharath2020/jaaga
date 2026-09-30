import JaagaLayout
import JaagaProtocol
import SwiftUI

/// The space map: the current folder's children as a colourful squarified treemap, with the same
/// children listed below it.
///
/// The map answers "what is big" at a glance; the list answers "how big, and when did I last touch it".
/// They show the same set in the same colours so moving between them costs no re-orientation.
struct SpaceMapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // While another folder is being measured, the previous folder's numbers would read as that
        // folder's; the placeholder stands in until the real ones arrive.
        if let listing = model.listing, model.measuringPath == nil {
            VStack(alignment: .leading, spacing: 16) {
                header(listing)
                hint
                SpaceMapCanvas(children: listing.children, shades: model.childShades)
                    .frame(minHeight: 220, idealHeight: 300, maxHeight: 340)
                if !listing.unreadable.isEmpty {
                    UnreadableNotice(unreadable: listing.unreadable)
                }
                ChildrenList()
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            FirstScanPlaceholder()
        }
    }

    private func header(_ listing: FolderListing) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle(for: listing))
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                Text(listing.folder.name)
                    .font(Theme.text(28, weight: .bold))
                    .tracking(-0.6)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if !listing.folder.isComplete {
                    Text("At least")
                        .font(Theme.text(12, weight: .semibold))
                        .foregroundStyle(Theme.alertBodyInk)
                }
                BigSize(bytes: listing.folder.allocatedBytes, numberSize: 34, unitSize: 16)
                Text(diskShare(listing.folder.allocatedBytes))
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func subtitle(for listing: FolderListing) -> String {
        let folders = listing.children.filter(\.isDirectory).count
        let files = listing.children.count - folders
        var parts = [listing.folder.kind]
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        return parts.joined(separator: " · ")
    }

    private func diskShare(_ bytes: Int64) -> String {
        guard let volume = model.startupVolume else { return "" }
        return "\(Present.percentage(model.shareOfDisk(bytes))) of \(volume.name)"
    }

    private var hint: some View {
        HStack(spacing: 12) {
            let inside = model.suspectsInsideCurrentFolder
            if inside.count > 0 {
                Button { model.view = .suspects } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                        Text(
                            "\(inside.count) usual suspect\(inside.count == 1 ? "" : "s") inside · "
                                + Present.size(inside.bytes)
                        )
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(Theme.text(12, weight: .semibold))
                    .foregroundStyle(Theme.suspectBadgeInk)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.suspectChipBackground, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            Text("Click a block to inspect it, double-click to open it.")
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
        }
        .frame(height: 28)
    }
}

/// The treemap itself.
private struct SpaceMapCanvas: View {
    @Environment(AppModel.self) private var model
    let children: [Entry]
    let shades: [String: Int]

    var body: some View {
        GeometryReader { geometry in
            let tiles = SpaceMapCanvas.layout(children, in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(tiles, id: \.element.path) { tile in
                    Tile(
                        entry: tile.element,
                        shade: shades[tile.element.path] ?? 1,
                        isSelected: model.selection?.path == tile.element.path,
                        size: tile.frame.size
                    )
                    .frame(width: tile.frame.width, height: tile.frame.height)
                    .offset(x: tile.frame.minX, y: tile.frame.minY)
                }
            }
        }
        .background(Theme.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Space map")
    }

    static func layout(_ children: [Entry], in size: CGSize) -> [Treemap.Tile<Entry>] {
        Treemap.squarify(
            children,
            weight: { Double($0.allocatedBytes) },
            in: CGRect(origin: .zero, size: size)
        )
    }
}

/// One block. What it can show depends on how much room it got: below a certain size a name would be
/// an ellipsis and a number would be unreadable, so they are dropped rather than crammed in.
private struct Tile: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let shade: Int
    let isSelected: Bool
    let size: CGSize

    private var background: Color { Theme.color(for: entry.category, shade: shade) }
    private var foreground: Color { Theme.foreground(onCategory: entry.category, shade: shade) }
    private var showsName: Bool { size.width >= 64 && size.height >= 36 }
    private var showsSize: Bool { size.width >= 64 && size.height >= 64 }
    private var isRoomy: Bool { size.width >= 190 && size.height >= 120 }

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(background)
            .overlay(alignment: .topLeading) { label }
            .overlay(alignment: .topTrailing) {
                if entry.isWatched, showsName {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(foreground.opacity(0.9))
                        .padding(10)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.95), lineWidth: 3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .inset(by: 3)
                                .strokeBorder(.black.opacity(0.18), lineWidth: 2)
                        }
                }
            }
            .padding(2)
            .contentShape(.rect)
            .onTapGesture(count: 2) { Task { await model.openFolder(entry) } }
            .onTapGesture { model.select(entry) }
            .help("\(entry.name) · \(Present.size(entry.allocatedBytes))")
            .accessibilityElement()
            .accessibilityLabel("\(entry.name), \(Present.size(entry.allocatedBytes))")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.select(entry) }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsName {
                Text(entry.name)
                    .font(Theme.text(isRoomy ? 16 : 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.trailing, entry.isWatched ? 16 : 0)
            }
            Spacer(minLength: 0)
            if showsSize {
                Text(entry.isComplete ? Present.size(entry.allocatedBytes) : "≥ " + Present.size(entry.allocatedBytes))
                    .font(Theme.number(isRoomy ? 28 : 15))
                    .tracking(-0.4)
                if isSelected, isRoomy, entry.isDirectory {
                    Text("Double-click to open")
                        .font(Theme.text(11, weight: .medium))
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The list under the map: the same children, with the details the map has no room for.
private struct ChildrenList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Inside \(model.currentFolder?.name ?? "")")
                    .font(Theme.text(13, weight: .semibold))
                Spacer()
                SegmentedChoice(
                    options: [(.largest, "Largest"), (.leastUsed, "Least used")],
                    selection: Binding(get: { model.sort }, set: { model.sort = $0 })
                )
            }
            .frame(height: 28)
            .padding(.horizontal, 8)

            if model.visibleChildren.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleChildren) { child in
                            ChildRow(entry: child, shade: model.childShades[child.path] ?? 1)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.searchText.isEmpty ? "This folder is empty." : "Nothing here matches “\(model.searchText)”.")
                .font(Theme.text(13, weight: .semibold))
                .foregroundStyle(Theme.labelInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var model
    let entry: Entry
    let shade: Int

    private var isSelected: Bool { model.selection?.path == entry.path }
    private var color: Color { Theme.color(for: entry.category, shade: shade) }

    private var fraction: Double {
        guard let largest = model.listing?.children.first?.allocatedBytes, largest > 0 else { return 0 }
        return Double(entry.allocatedBytes) / Double(largest)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.select(entry)
            } label: {
                HStack(spacing: 10) {
                    if entry.isDirectory {
                        FolderGlyph(color: color)
                    } else {
                        FileGlyph(
                            extensionName: (entry.name as NSString).pathExtension,
                            color: color,
                            width: 15,
                            height: 19
                        )
                        .frame(width: 20)
                    }
                    Text(entry.name)
                        .font(Theme.text(13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.verdict == .safeToClear {
                        VerdictPill(verdict: entry.verdict, size: 10.5)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: Theme.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { Task { await model.openFolder(entry) } }
            )

            SizeBar(fraction: fraction, color: color).frame(width: 150)

            HStack(spacing: 4) {
                if !entry.isComplete {
                    IncompleteMarker(unreadableCount: entry.unreadableDescendantCount)
                }
                Text(Present.size(entry.allocatedBytes))
                    .font(Theme.text(13, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 76, alignment: .trailing)

            Text(Present.relativeDay(entry.lastOpened))
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)

            StarButton(isWatched: entry.isWatched, name: entry.name) {
                Task { await model.toggleWatch(path: entry.path) }
            }

            if entry.isDirectory {
                Button { Task { await model.openFolder(entry) } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryInk)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open \(entry.name)")
            } else {
                Spacer().frame(width: 32)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .background(
            isSelected ? Theme.selectedRow : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contextMenu {
            Button("Open") { Task { await model.openFolder(entry) } }
                .disabled(!entry.isDirectory)
            Button("Quick Look") { Task { await model.loadQuickLook(for: entry) } }
            Button("Reveal in Finder") { Task { await model.reveal(path: entry.path) } }
            Divider()
            Button(entry.isWatched ? "Stop Watching" : "Watch") {
                Task { await model.toggleWatch(path: entry.path) }
            }
        }
    }
}

/// What the map shows before the first measurement finishes.
///
/// A whole home folder can take a couple of minutes to measure honestly the first time, and an empty
/// window for that long looks broken. This says what is happening and why it is worth the wait.
private struct FirstScanPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            Text(model.measuringPath.map { "Measuring \(displayName($0))" } ?? "Measuring your folders")
                .font(Theme.text(15, weight: .bold))
            if let progress = model.scanProgress {
                Text("\(Present.itemCount(progress.itemsScanned)) so far · \(Present.size(progress.bytesScanned))")
                    .font(Theme.text(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryInk)
                Text(abbreviated(progress.currentPath))
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(Theme.tertiaryInk)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 420)
            }
            Text(
                "Jaaga counts what each folder actually occupies on disk, which takes a moment the "
                    + "first time. After that, moving around is instant."
            )
            .font(Theme.text(12))
            .foregroundStyle(Theme.secondaryInk)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func abbreviated(_ path: String) -> String {
        guard path.hasPrefix(model.homePath) else { return path }
        return "~" + path.dropFirst(model.homePath.count)
    }

    private func displayName(_ path: String) -> String {
        path == model.homePath ? "Home" : (path as NSString).lastPathComponent
    }
}

/// Says plainly that a total is short, and why.
struct UnreadableNotice: View {
    let unreadable: [UnreadablePath]

    private var needsFullDiskAccess: Bool {
        unreadable.contains { $0.errnoCode == EACCES || $0.errnoCode == EPERM }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.alertBodyInk)
                .frame(width: 20, height: 20)
                .background(Theme.suspectBadgeBackground, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    unreadable.count == 1
                        ? "1 folder could not be read, so this total is a lower bound."
                        : "\(unreadable.count) folders could not be read, so this total is a lower bound."
                )
                .font(Theme.text(12, weight: .semibold))
                .foregroundStyle(Theme.alertTitleInk)
                if needsFullDiskAccess {
                    Text("Grant Jaaga Full Disk Access in System Settings › Privacy & Security to measure them.")
                        .font(Theme.text(11))
                        .foregroundStyle(Theme.alertBodyInk)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.alertBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(unreadable.prefix(8).map(\.path).joined(separator: "\n"))
    }
}
