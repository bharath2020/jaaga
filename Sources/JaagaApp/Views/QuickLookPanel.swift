import JaagaLayout
import JaagaProtocol
import QuickLookUI
import SwiftUI

/// What is inside the selection, largest first, with a bar of where the space went.
///
/// For a file, the system previewer is the right tool and gets handed the path — Jaaga has no business
/// trying to render a video. For a folder, which the system previewer shows as a generic icon, this
/// panel shows the thing you actually wanted to know: what inside it is big.
struct QuickLookPanel: View {
    @Environment(AppModel.self) private var model
    let report: QuickLookReport

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .onTapGesture { model.closeQuickLook() }

            VStack(spacing: 0) {
                titleBar
                Divider().overlay(Theme.divider)
                HStack(spacing: 0) {
                    contents
                    Divider().overlay(Theme.divider)
                    details
                }
            }
            .frame(width: 880, height: 600)
            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.38), radius: 45, y: 30)
        }
        .transition(.opacity)
    }

    private var titleBar: some View {
        HStack(spacing: 12) {
            Button { model.closeQuickLook() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.labelInk)
                    .frame(width: 30, height: 30)
                    .background(Theme.divider, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close Quick Look")

            if report.entry.isDirectory {
                FolderGlyph(color: color, size: 22)
            } else {
                FileGlyph(
                    extensionName: (report.entry.name as NSString).pathExtension,
                    color: color,
                    width: 18,
                    height: 22
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(report.entry.name)
                    .font(Theme.text(15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Button {
                Task { await model.toggleWatch(path: report.entry.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: report.entry.isWatched ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(report.entry.isWatched ? Theme.star : Theme.secondaryInk)
                    Text(report.entry.isWatched ? "Watching" : "Watch")
                        .font(Theme.text(12, weight: .semibold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    report.entry.isWatched ? Theme.watchingBackground : Theme.control,
                    in: .capsule
                )
                .overlay {
                    Capsule().strokeBorder(
                        report.entry.isWatched ? Theme.watchingBorder : Theme.controlBorder,
                        lineWidth: 1
                    )
                }
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)

            if report.prefersSystemPreview {
                Button("Preview") { SystemPreview.show(path: report.entry.path) }
                    .buttonStyle(.plain)
                    .font(Theme.text(12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Theme.accent, in: .capsule)
                    .help("Open in the system previewer")
            }

            Button("Open in Finder") { Task { await model.reveal(path: report.entry.path) } }
                .buttonStyle(.plain)
                .font(Theme.text(12, weight: .semibold))
                .foregroundStyle(report.prefersSystemPreview ? Theme.ink : .white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    report.prefersSystemPreview ? Theme.control : Theme.accent,
                    in: .capsule
                )
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .frame(height: 56)
    }

    private var subtitle: String {
        var parts = [Present.size(report.entry.allocatedBytes)]
        if report.entry.isDirectory {
            parts.append(Present.itemCount(report.entry.itemCount))
        }
        if report.truncated {
            parts.append("showing the largest \(report.items.count)")
        }
        return parts.joined(separator: " · ")
    }

    private var contents: some View {
        Group {
            if report.items.isEmpty {
                singleItem
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    SegmentedBar(
                        segments: report.items.map {
                            SegmentedBar.Segment(
                                id: $0.path,
                                bytes: $0.allocatedBytes,
                                color: itemColor($0),
                                label: $0.name
                            )
                        },
                        height: 10,
                        spacing: 2,
                        cornerRadius: 5
                    )
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(report.items) { item in
                                ItemTile(item: item, color: itemColor(item))
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A file with nothing to list: a disk image, a single video. Say what it is and why it is big.
    private var singleItem: some View {
        VStack(spacing: 14) {
            FileGlyph(
                extensionName: (report.entry.name as NSString).pathExtension,
                color: color,
                width: 96,
                height: 116
            )
            Text(report.entry.name)
                .font(Theme.text(15, weight: .bold))
                .multilineTextAlignment(.center)
            Text(report.entry.reason)
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if report.prefersSystemPreview {
                Button("Open the system preview") { SystemPreview.show(path: report.entry.path) }
                    .buttonStyle(.plain)
                    .font(Theme.text(12, weight: .semibold))
                    .foregroundStyle(Theme.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Theme.tilePanel)
        .padding(20)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                BigSize(bytes: report.entry.allocatedBytes, numberSize: 34, unitSize: 15)
                Text(share)
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
            }

            MetadataGrid(
                rows: [
                    ("Kind", report.entry.kind, false),
                    ("Items", report.entry.isDirectory ? Present.itemCount(report.entry.itemCount) : "—", false),
                    ("Created", Present.timestamp(report.entry.created), false),
                    ("Modified", Present.timestamp(report.entry.contentModified), false),
                    ("Last opened", Present.relativeDay(report.entry.lastOpened), false),
                    ("Where", report.entry.path, true),
                ],
                labelWidth: 84
            )

            VStack(alignment: .leading, spacing: 6) {
                VerdictPill(verdict: report.entry.verdict)
                Text(report.entry.reason)
                    .font(Theme.text(12))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.style(for: report.entry.verdict).cardBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            Spacer(minLength: 0)
            Text("Escape closes")
                .font(Theme.text(11))
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(20)
        .frame(width: 264)
        .background(Color.hex(0xFAFAFC))
    }

    private var share: String {
        guard let volume = model.startupVolume else { return "" }
        return "\(Present.percentage(model.shareOfDisk(report.entry.allocatedBytes))) of \(volume.name)"
    }

    private var color: Color { Theme.color(for: report.entry.category) }

    /// Items take tonal steps of the enclosing folder's hue, largest first, matching the map.
    private func itemColor(_ item: QuickLookItem) -> Color {
        let rank = report.items.firstIndex { $0.path == item.path } ?? 0
        return Theme.color(for: report.entry.category, shade: min(rank, 3))
    }
}

private struct ItemTile: View {
    let item: QuickLookItem
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if item.isDirectory {
                    FolderGlyph(color: color, size: 38)
                } else {
                    FileGlyph(extensionName: item.fileExtension ?? "", color: color)
                        .padding(.horizontal, 4)
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    if !item.isComplete {
                        IncompleteMarker(unreadableCount: item.unreadableDescendantCount, size: 10)
                    }
                    Text(item.isComplete ? Present.size(item.allocatedBytes) : "≥ " + Present.size(item.allocatedBytes))
                        .font(Theme.number(16))
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(Theme.text(12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Present.relativeDay(item.contentModified))
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.tilePanel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help("\(item.path)\n\(Present.size(item.allocatedBytes))")
    }
}

/// Hands a file to macOS's own previewer, which can actually render it.
@MainActor
enum SystemPreview {
    private final class Source: NSObject, QLPreviewPanelDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            url as NSURL
        }
    }

    /// Held for as long as the panel is up, since the panel does not retain its data source.
    private static var source: Source?

    static func show(path: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let source = Source(url: URL(fileURLWithPath: path))
        Self.source = source
        panel.dataSource = source
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
}
