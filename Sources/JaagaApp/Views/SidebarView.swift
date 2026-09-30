import JaagaLayout
import JaagaProtocol
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            title
            views
            watching
            locations
            Spacer(minLength: 8)
            if let summary = model.volumeSummary ?? model.startupVolume.map({
                VolumeSummary(volume: $0, segments: [], accountedBytes: 0, measuredAt: nil)
            }) {
                DiskCard(summary: summary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: Theme.sidebarWidth - 16)
        .background(Theme.sidebarBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.sidebarBorder, lineWidth: 1)
        }
        .padding(.leading, 8)
        .padding(.vertical, 8)
    }

    private var title: some View {
        HStack(spacing: 10) {
            AppMark()
            VStack(alignment: .leading, spacing: 0) {
                Text("Jaaga")
                    .font(Theme.text(15, weight: .bold))
                    .tracking(-0.2)
                Text("Disk space explorer")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .padding(.horizontal, 6)
    }

    private var views: some View {
        VStack(spacing: 2) {
            NavigationRow(
                title: "Space map",
                systemImage: "square.split.2x1",
                iconColor: Color.hex(0x0A66E0),
                isSelected: model.view == .spaceMap
            ) {
                model.view = .spaceMap
            }
            NavigationRow(
                title: "Usual suspects",
                systemImage: "sparkles",
                iconColor: Color.hex(0xC25E00),
                isSelected: model.view == .suspects,
                badge: model.suspectReport.map { Present.compactSize($0.totalBytes) },
                badgeInk: Theme.suspectBadgeInk,
                badgeBackground: Theme.suspectBadgeBackground
            ) {
                model.view = .suspects
            }
            NavigationRow(
                title: "Watched",
                systemImage: "star.fill",
                iconColor: Theme.star,
                isSelected: model.view == .watched,
                badge: model.watchedFolders.isEmpty ? nil : String(model.watchedFolders.count),
                badgeInk: Theme.countBadgeInk,
                badgeBackground: Theme.countBadgeBackground
            ) {
                model.view = .watched
            }
        }
    }

    private var watching: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Watching")
            if model.watchedFolders.isEmpty {
                Text("Star a folder to keep an eye on it.")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.watchedFolders.prefix(6)) { folder in
                    Button {
                        Task { await model.locate(path: folder.path) }
                    } label: {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Theme.color(for: folder.category))
                                .frame(width: 10, height: 10)
                            Text(folder.name)
                                .font(Theme.text(13))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(shortDelta(folder))
                                .font(Theme.text(11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(
                                    folder.growth.deltaBytes > 0 ? Theme.alertAccent : Theme.secondaryInk
                                )
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(folder.path)
                }
            }
        }
    }

    private func shortDelta(_ folder: WatchedFolder) -> String {
        let delta = folder.growth.deltaBytes
        guard delta > 50_000_000 else { return "—" }
        return "+" + Present.compactSize(delta)
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Locations")
            LocationRow(
                title: "Home",
                systemImage: "house",
                trailing: model.currentHomeSize,
                isSelected: model.currentFolder?.path == model.homePath
            ) {
                Task { await model.open(path: model.homePath) }
            }
            ForEach(model.volumes) { volume in
                LocationRow(
                    title: volume.name,
                    systemImage: volume.isStartupDisk
                        ? "internaldrive"
                        : (volume.isRemovable ? "externaldrive" : "internaldrive"),
                    trailing: Present.compactSize(volume.totalBytes),
                    isSelected: model.currentFolder?.path == volume.mountPath
                ) {
                    Task { await model.open(path: volume.mountPath) }
                }
            }
        }
    }
}

extension AppModel {
    /// The home folder's measured size, when it happens to be what is on screen or cached.
    var currentHomeSize: String? {
        if let folder = currentFolder, folder.path == homePath {
            return Present.compactSize(folder.allocatedBytes)
        }
        return nil
    }
}

/// Jaaga's mark: four blocks in four of the palette's hues — a treemap, in miniature.
private struct AppMark: View {
    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                block(Color.hex(0xB05300)).gridCellColumns(1)
                block(Color.hex(0xCC2C6C))
            }
            GridRow {
                block(Color.hex(0x7253F0))
                block(Color.hex(0x22803D))
            }
        }
        .padding(2)
        .frame(width: 30, height: 30)
        .background(.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
        .accessibilityHidden(true)
    }

    private func block(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color)
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.text(11, weight: .semibold))
            .foregroundStyle(Theme.secondaryInk)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

private struct NavigationRow: View {
    let title: String
    let systemImage: String
    let iconColor: Color
    let isSelected: Bool
    var badge: String?
    var badgeInk: Color = Theme.countBadgeInk
    var badgeBackground: Color = Theme.countBadgeBackground
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // No Spacer between the title and the badge: at this width every point counts, and
            // "Usual suspects" has to fit beside its total without truncating.
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.text(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badge {
                    Text(badge)
                        .font(Theme.text(11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(badgeInk)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeBackground, in: .capsule)
                        // Natural width, so the title truncates rather than the row wrapping.
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                isSelected ? Theme.selectedNav : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct LocationRow: View {
    let title: String
    let systemImage: String
    var trailing: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.labelInk)
                    .frame(width: 16)
                Text(title)
                    .font(Theme.text(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(Theme.text(11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                isSelected ? Theme.selectedNav : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Free space plus a bar of what is using the rest.
///
/// When the daemon has not measured enough to explain the used space, the bar shows one neutral block
/// for "used" rather than a colourful breakdown that would imply knowledge Jaaga does not have.
private struct DiskCard: View {
    let summary: VolumeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.volume.name)
                    .font(Theme.text(12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("of \(Present.size(summary.volume.totalBytes))")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.secondaryInk)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Present.sizeParts(summary.volume.freeBytes).value)
                    .font(Theme.number(22))
                    .tracking(-0.4)
                Text("\(Present.sizeParts(summary.volume.freeBytes).unit) free")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
            }

            SegmentedBar(segments: segments)

            if !summary.segments.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(summary.segments.prefix(8)) { segment in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Theme.color(for: segment.category))
                                .frame(width: 7, height: 7)
                            Text(segment.label)
                                .font(Theme.text(11))
                                .foregroundStyle(Theme.labelInk)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            } else {
                Text("Scan your home folder to see what is using the space.")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }

    private var segments: [SegmentedBar.Segment] {
        guard !summary.segments.isEmpty else {
            return [
                SegmentedBar.Segment(
                    id: "used",
                    bytes: summary.volume.usedBytes,
                    color: Theme.color(for: .system, shade: 2),
                    label: "Used"
                )
            ]
        }
        return summary.segments.map {
            SegmentedBar.Segment(
                id: $0.label,
                bytes: $0.bytes,
                color: Theme.color(for: $0.category),
                label: $0.label
            )
        }
    }
}
