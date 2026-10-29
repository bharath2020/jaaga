import JaagaLayout
import JaagaProtocol
import SwiftUI

/// The folders that grow quietly, with how much of the pile is safe to clear today.
struct SuspectsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folders that grow quietly and usually come back on their own")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                Text("Usual suspects")
                    .font(Theme.text(28, weight: .bold))
                    .tracking(-0.6)
            }

            if let report = model.suspectReport {
                summary(report)
                filters(report)
                if !report.unreadable.isEmpty {
                    UnreadableNotice(unreadable: report.unreadable)
                }
                rows
                    .frame(maxHeight: .infinity)
            } else {
                ProgressView("Looking in the usual places…")
                    .font(Theme.text(13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func summary(_ report: SuspectReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Present.sizeParts(report.totalBytes).value)
                        .font(Theme.number(40))
                        .tracking(-1.2)
                    Text(
                        "\(Present.sizeParts(report.totalBytes).unit) sitting in "
                            + "\(report.suspects.count) familiar place\(report.suspects.count == 1 ? "" : "s")"
                    )
                    .font(Theme.text(15))
                    .foregroundStyle(Theme.secondaryInk)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.style(for: .safeToClear).dot)
                        .frame(width: 8, height: 8)
                    Group {
                        Text(Present.size(report.safeToClearBytes)).fontWeight(.bold)
                            + Text(" is safe to clear today")
                    }
                    .font(Theme.text(13))
                }
            }

            SegmentedBar(
                segments: report.suspects.map {
                    SegmentedBar.Segment(
                        id: $0.id,
                        bytes: $0.allocatedBytes,
                        color: Theme.color(for: $0.category),
                        label: $0.title
                    )
                },
                height: 14,
                spacing: 3,
                cornerRadius: 4
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(Theme.quietPanel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func filters(_ report: SuspectReport) -> some View {
        let safe = report.suspects.count { $0.verdict == .safeToClear }
        let review = report.suspects.count { $0.verdict == .reviewFirst }
        return HStack(spacing: 8) {
            FilterChip(title: "All \(report.suspects.count)", isSelected: model.suspectFilter == .all) {
                model.suspectFilter = .all
            }
            FilterChip(title: "Safe to clear · \(safe)", isSelected: model.suspectFilter == .safeToClear) {
                model.suspectFilter = .safeToClear
            }
            FilterChip(title: "Review first · \(review)", isSelected: model.suspectFilter == .reviewFirst) {
                model.suspectFilter = .reviewFirst
            }
        }
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.filteredSuspects) { suspect in
                    SuspectRow(suspect: suspect)
                }
                if model.filteredSuspects.isEmpty {
                    Text("Nothing in this category.")
                        .font(Theme.text(13))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.vertical, 28)
                }
            }
        }
    }
}

private struct SuspectRow: View {
    @Environment(AppModel.self) private var model
    let suspect: Suspect

    private var isSelected: Bool { model.selection?.path == suspect.paths.first }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.color(for: suspect.category))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: suspect.isAggregate ? "square.stack.3d.up" : "folder")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.foreground(onCategory: suspect.category, shade: 1))
                }

            Button {
                Task { await model.selectSuspect(suspect) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suspect.title)
                        .font(Theme.text(14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(suspect.reason)
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(suspect.displayPath)

            VerdictPill(verdict: suspect.verdict)
                .frame(width: 112, alignment: .leading)

            Text(Present.size(suspect.allocatedBytes))
                .font(Theme.text(14, weight: .bold))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)

            StarButton(isWatched: suspect.isWatched, name: suspect.title) {
                Task {
                    // An aggregate covers many folders; watching them all is what the star means here.
                    for path in suspect.paths {
                        await model.toggleWatch(path: path)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(
            isSelected ? Theme.selectedRow : .clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contextMenu {
            Button("Show in Space Map") { Task { await model.locate(path: suspect.paths[0]) } }
            Button("Reveal in Finder") { Task { await model.reveal(path: suspect.paths[0]) } }
        }
    }
}

extension AppModel {
    /// Selects a suspect's folder so the inspector can describe it.
    ///
    /// An aggregate row stands for several folders, so the inspector describes the first — the list
    /// itself carries the total, and the inspector never claims to describe more than one place.
    func selectSuspect(_ suspect: Suspect) async {
        guard let first = suspect.paths.first else { return }
        await select(path: first)
    }
}
