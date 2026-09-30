import JaagaLayout
import JaagaProtocol
import SwiftUI

/// Everything known about the selection, and the four things you can do with it.
///
/// The verdict and its reason come from the daemon, in the daemon's words. The app does not soften or
/// re-word them: "safe to clear" has to mean the same thing everywhere it appears.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    /// The entry the confirmation was opened for, captured then. The dialog's title, its message and
    /// its button all read this, never the live selection, which a background reload can change while
    /// the dialog is up.
    @State private var pendingTrash: Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = model.selection {
                // The description scrolls; the four actions stay put, so Move to Trash never slides
                // off the bottom in a short window or behind a long path.
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(entry)
                        size(entry)
                        verdict(entry)
                        metadata(entry)
                        if let biggest = biggestInside(entry), !biggest.isEmpty {
                            biggestInsideSection(biggest, of: entry)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .frame(maxHeight: .infinity)

                actions(entry)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
                    .padding(.top, 2)
            } else {
                Spacer()
                Text("Select something to inspect it.")
                    .font(Theme.text(13))
                    .foregroundStyle(Theme.secondaryInk)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(width: Theme.inspectorWidth)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.divider).frame(width: 1)
        }
        .confirmationDialog(
            "Move “\(pendingTrash?.name ?? "")” to the Trash?",
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { entry in
            Button("Move to Trash", role: .destructive) {
                Task { await model.moveToTrash(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(trashExplanation(entry))
        }
    }

    /// The confirmation says what will be freed and where the item goes, because "are you sure" on its
    /// own tells the user nothing they did not already know.
    private func trashExplanation(_ entry: Entry) -> String {
        var lines = [
            "\(Present.size(entry.allocatedBytes)) will move to the Trash. "
                + "Nothing is deleted until you empty it."
        ]
        if entry.isDirectory, entry.itemCount > 0 {
            lines.append("\(Present.itemCount(entry.itemCount)) inside.")
        }
        if entry.verdict == .yourData {
            lines.append("Jaaga thinks this is your own data, not something that comes back on its own.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func header(_ entry: Entry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if entry.isDirectory {
                FolderGlyph(color: color(for: entry), size: 52)
            } else {
                FileGlyph(
                    extensionName: (entry.name as NSString).pathExtension,
                    color: color(for: entry),
                    width: 42,
                    height: 52
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(Theme.text(18, weight: .bold))
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(abbreviated(entry.path))
                    .font(Theme.monospacedSmall)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let link = link(for: entry) {
                    Button(link.title) { Task { await link.action() } }
                        .buttonStyle(.plain)
                        .font(Theme.text(12, weight: .semibold))
                        .foregroundStyle(Theme.link)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func link(for entry: Entry) -> (title: String, action: () async -> Void)? {
        if model.view != .spaceMap {
            return ("Show in map →", { await model.locate(path: entry.path) })
        }
        if entry.isDirectory, entry.path != model.currentFolder?.path {
            return ("Open folder →", { await model.openFolder(entry) })
        }
        return nil
    }

    private func size(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // "At least" whenever part of the subtree could not be read. The big number is what
            // people act on, so it is the one place a lower bound must never pass for a total.
            if !entry.isComplete {
                Text("At least")
                    .font(Theme.text(12, weight: .semibold))
                    .foregroundStyle(Theme.alertBodyInk)
            }
            BigSize(bytes: entry.allocatedBytes, numberSize: 40, unitSize: 17)
            SizeBar(fraction: model.shareOfDisk(entry.allocatedBytes), color: color(for: entry))
            Text(shareText(entry))
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.isComplete {
                LowerBoundNote(unreadableCount: entry.unreadableDescendantCount)
            }
        }
    }

    private func shareText(_ entry: Entry) -> String {
        var parts: [String] = []
        if let volume = model.startupVolume {
            parts.append("\(Present.percentage(model.shareOfDisk(entry.allocatedBytes))) of \(volume.name)")
        }
        // Share of the enclosing folder, which is often the number that decides whether it is worth
        // opening: 90% of a folder in one child means there is only one thing to look at.
        if let parent = model.currentFolder, parent.path != entry.path, parent.allocatedBytes > 0 {
            let share = Double(entry.allocatedBytes) / Double(parent.allocatedBytes)
            parts.append("\(Present.percentage(share)) of \(parent.name)")
        }
        return parts.joined(separator: " · ")
    }

    private func verdict(_ entry: Entry) -> some View {
        let style = Theme.style(for: entry.verdict)
        return VStack(alignment: .leading, spacing: 8) {
            VerdictPill(verdict: entry.verdict)
            Text(entry.reason)
                .font(Theme.text(13))
                .lineSpacing(2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metadata(_ entry: Entry) -> some View {
        MetadataGrid(
            rows: [
                ("Kind", entry.kind, false),
                ("Items", entry.isDirectory ? Present.itemCount(entry.itemCount) : "—", false),
                ("Last opened", Present.relativeDay(entry.lastOpened), false),
                ("Modified", Present.timestamp(entry.contentModified), false),
                ("Created", Present.timestamp(entry.created), false),
            ]
        )
    }

    /// The largest things one level down, which is where to look next.
    private func biggestInside(_ entry: Entry) -> [Entry]? {
        guard entry.isDirectory else { return nil }
        if entry.path == model.currentFolder?.path {
            return Array((model.listing?.children ?? []).prefix(3))
        }
        // For a selected child the app has no listing of its own contents; Quick Look fetches that.
        return nil
    }

    private func biggestInsideSection(_ children: [Entry], of entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biggest inside")
                .font(Theme.text(11, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
            ForEach(children) { child in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(child.name)
                            .font(Theme.text(12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(Present.size(child.allocatedBytes))
                            .font(Theme.text(12, weight: .semibold))
                            .monospacedDigit()
                    }
                    SizeBar(
                        fraction: entry.allocatedBytes > 0
                            ? Double(child.allocatedBytes) / Double(entry.allocatedBytes)
                            : 0,
                        color: Theme.color(for: child.category, shade: model.childShades[child.path] ?? 1),
                        height: 4
                    )
                }
            }
        }
    }

    private func actions(_ entry: Entry) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await model.loadQuickLook(for: entry) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye").font(.system(size: 13, weight: .semibold))
                        Text("Quick Look").font(Theme.text(13, weight: .semibold))
                        Text("Space")
                            .font(Theme.text(10.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    Task { await model.reveal(path: entry.path) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 36)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Theme.controlBorder, lineWidth: 1)
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }

            HStack(spacing: 8) {
                Button {
                    Task { await model.toggleWatch(path: entry.path) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: entry.isWatched ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(entry.isWatched ? Theme.star : Theme.secondaryInk)
                        Text(entry.isWatched ? "Watching" : "Watch").font(Theme.text(13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        entry.isWatched ? Theme.watchingBackground : Theme.control,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                entry.isWatched ? Theme.watchingBorder : Theme.controlBorder,
                                lineWidth: 1
                            )
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                Button {
                    pendingTrash = entry
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash").font(.system(size: 13, weight: .medium))
                        Text("Move to Trash…").font(Theme.text(13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.destructiveInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        Theme.destructiveBackground,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(entry.path == model.homePath || entry.path == "/")
            }
        }
    }

    private func color(for entry: Entry) -> Color {
        Theme.color(for: entry.category, shade: model.childShades[entry.path] ?? 1)
    }

    private func abbreviated(_ path: String) -> String {
        guard path.hasPrefix(model.homePath) else { return path }
        return "~" + path.dropFirst(model.homePath.count)
    }
}
