import JaagaLayout
import JaagaProtocol
import SwiftUI

/// Starred folders, their size, how they have grown, and a word when one speeds up.
struct WatchedView: View {
    @Environment(AppModel.self) private var model

    private let columns = [
        GridItem(.flexible(minimum: 260), spacing: 16),
        GridItem(.flexible(minimum: 260), spacing: 16),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Jaaga re-measures these in the background and tells you when one speeds up")
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.secondaryInk)
                Text("Watched folders")
                    .font(Theme.text(28, weight: .bold))
                    .tracking(-0.6)
            }

            if let alert = model.growthAlert ?? impliedAlert {
                GrowthAlertBanner(alert: alert)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.watchedFolders) { folder in
                        WatchedCard(folder: folder)
                    }
                    AddWatchCard()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A folder can already be alerting when the view opens, before any event arrives.
    private var impliedAlert: WatchAlertEvent? {
        guard let folder = model.watchedFolders.first(where: { $0.growth.isAlerting }) else { return nil }
        return WatchAlertEvent(
            folder: folder,
            accelerationFactor: folder.growth.accelerationFactor,
            message: message(for: folder)
        )
    }

    private func message(for folder: WatchedFolder) -> String {
        guard let factor = folder.growth.accelerationFactor, factor.isFinite, factor > 1 else {
            return "\(folder.name) started growing after a quiet spell"
        }
        let rounded = factor >= 10 ? "\(Int(factor.rounded()))×" : String(format: "%.1f×", factor)
        return "\(folder.name) is growing \(rounded) faster than usual"
    }
}

private struct GrowthAlertBanner: View {
    @Environment(AppModel.self) private var model
    let alert: WatchAlertEvent

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.alertAccent, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.message)
                    .font(Theme.text(13, weight: .semibold))
                    .foregroundStyle(Theme.alertTitleInk)
                Text(detail)
                    .font(Theme.text(12))
                    .foregroundStyle(Theme.alertBodyInk)
            }
            Spacer(minLength: 8)

            Button("Inspect") {
                Task { await model.locate(path: alert.folder.path) }
            }
            .buttonStyle(.plain)
            .font(Theme.text(12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.alertAccent, in: .capsule)

            Button {
                model.dismissGrowthAlert()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.alertBodyInk)
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.alertBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detail: String {
        let growth = alert.folder.growth
        var parts: [String] = []
        if growth.deltaBytes > 0 {
            let weeks = Int((growth.windowSeconds / (7 * 86_400)).rounded())
            parts.append(
                weeks >= 1
                    ? "\(Present.delta(growth.deltaBytes)) in \(weeks) week\(weeks == 1 ? "" : "s")"
                    : Present.delta(growth.deltaBytes)
            )
        }
        if growth.recentBytesPerDay > 0 {
            parts.append("about \(Present.size(Int64(growth.recentBytesPerDay))) a day lately")
        }
        parts.append(Theme.style(for: alert.folder.verdict).label.lowercased() == "safe to clear"
            ? "It is safe to clear."
            : "Worth a look before clearing.")
        return parts.joined(separator: " · ")
    }
}

private struct WatchedCard: View {
    @Environment(AppModel.self) private var model
    let folder: WatchedFolder

    private var color: Color { Theme.color(for: folder.category) }
    private var isAlerting: Bool { folder.growth.isAlerting }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(color)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "folder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.foreground(onCategory: folder.category, shade: 1))
                    }

                Button {
                    Task { await model.locate(path: folder.path) }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.name)
                            .font(Theme.text(14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(abbreviated(folder.path))
                            .font(Theme.monospacedSmall)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if isAlerting {
                    Text(Present.pace(folder.growth.accelerationFactor))
                        .font(Theme.text(11, weight: .semibold))
                        .foregroundStyle(Theme.suspectBadgeInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.suspectBadgeBackground, in: .capsule)
                        .fixedSize()
                }

                StarButton(isWatched: true, name: folder.name, size: 15) {
                    Task { await model.toggleWatch(path: folder.path) }
                }
                .frame(width: 30, height: 30)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Present.size(folder.currentBytes))
                        .font(Theme.number(26))
                        .tracking(-0.6)
                    Text(growthSummary)
                        .font(Theme.text(12, weight: .semibold))
                        .foregroundStyle(
                            folder.growth.deltaBytes > 0 ? Theme.alertAccent : Theme.secondaryInk
                        )
                }
                Spacer(minLength: 8)
                Sparkline(samples: folder.samples, color: color)
                    .frame(width: 160, height: 52)
            }
        }
        .padding(.leading, 16)
        .padding([.top, .trailing, .bottom], 14)
        .frame(height: 150)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isAlerting ? Theme.alertBorder : Color.hex(0xE8E8ED), lineWidth: 1)
        }
        .shadow(color: isAlerting ? Theme.alertBorder.opacity(0.18) : .clear, radius: 3)
        .contextMenu {
            Button("Show in Space Map") { Task { await model.locate(path: folder.path) } }
            Button("Reveal in Finder") { Task { await model.reveal(path: folder.path) } }
            Divider()
            Button("Stop Watching") { Task { await model.toggleWatch(path: folder.path) } }
        }
    }

    /// The history is only worth a sentence once there are two points to compare.
    private var growthSummary: String {
        guard folder.samples.count > 1 else { return "Measuring — no history yet" }
        let weeks = Int((folder.growth.windowSeconds / (7 * 86_400)).rounded())
        let span: String
        if weeks >= 1 {
            span = "in \(weeks) week\(weeks == 1 ? "" : "s")"
        } else {
            let days = max(1, Int((folder.growth.windowSeconds / 86_400).rounded()))
            span = "in \(days) day\(days == 1 ? "" : "s")"
        }
        return "\(Present.delta(folder.growth.deltaBytes)) \(span)"
    }

    private func abbreviated(_ path: String) -> String {
        guard path.hasPrefix(model.homePath) else { return path }
        return "~" + path.dropFirst(model.homePath.count)
    }
}

private struct AddWatchCard: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "star")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.placeholderIcon)
            Text("Star any folder to watch it")
                .font(Theme.text(13, weight: .semibold))
                .foregroundStyle(Theme.labelInk)
            Text("From the map, a suspect, or the inspector")
                .font(Theme.text(12))
                .foregroundStyle(Theme.secondaryInk)
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Theme.dashedBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        }
    }
}
