import JaagaLayout
import JaagaProtocol
import SwiftUI

/// The star that turns watching on and off. It appears in the map, in both lists, in the inspector and
/// in Quick Look, so it is one view with one hit area everywhere.
struct StarButton: View {
    let isWatched: Bool
    let name: String
    var size: CGFloat = 16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isWatched ? "star.fill" : "star")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isWatched ? Theme.star : Theme.starOff)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(isWatched ? "Stop watching \(name)" : "Watch \(name)")
        .accessibilityLabel(isWatched ? "Stop watching \(name)" : "Watch \(name)")
    }
}

/// A verdict as the design's rounded pill.
struct VerdictPill: View {
    let verdict: Verdict
    var size: CGFloat = 11

    var body: some View {
        let style = Theme.style(for: verdict)
        Text(style.label)
            .font(Theme.text(size, weight: .semibold))
            .foregroundStyle(style.pillInk)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(style.pillBackground, in: .capsule)
            .fixedSize()
    }
}

/// A folder's size as a proportion of the largest thing beside it.
struct SizeBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.trackBackground)
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geometry.size.width * clamped))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}

/// The design's segmented bar: one stripe per category, widths proportional to bytes.
struct SegmentedBar: View {
    struct Segment: Identifiable {
        let id: String
        let bytes: Int64
        let color: Color
        let label: String
    }

    let segments: [Segment]
    var height: CGFloat = 8
    var spacing: CGFloat = 2
    var cornerRadius: CGFloat = 4

    private var total: Double {
        max(1, segments.reduce(0.0) { $0 + Double($1.bytes) })
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(0, geometry.size.width - spacing * CGFloat(max(0, segments.count - 1)))
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(segment.color)
                        .frame(width: available * (Double(segment.bytes) / total))
                        .help("\(segment.label) · \(Present.size(segment.bytes))")
                }
            }
        }
        .frame(height: height)
        .background(Theme.sidebarBorder, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(
            segments.map { "\($0.label), \(Present.size($0.bytes))" }.joined(separator: "; ")
        )
    }
}

/// The folder glyph the design draws: a tab, a body, and a lighter face over the lower half.
struct FolderGlyph: View {
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size * 0.86))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A file as a small coloured page with its extension on it, as in the design's Quick Look tiles.
struct FileGlyph: View {
    let extensionName: String
    let color: Color
    var width: CGFloat = 30
    var height: CGFloat = 36

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 6,
            bottomLeadingRadius: 6,
            bottomTrailingRadius: 6,
            topTrailingRadius: 12,
            style: .continuous
        )
        .fill(color)
        .frame(width: width, height: height)
        .overlay(alignment: .bottom) {
            Text(extensionName.isEmpty ? "FILE" : extensionName.uppercased())
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(0.3)
                .foregroundStyle(.white)
                .padding(.bottom, 5)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }
}

/// The eight-week trend line on a watched folder's card.
struct Sparkline: View {
    let samples: [SizeSample]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .position(points[points.count - 1])
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Scaled to the range the samples actually cover, so a folder that grew 5% still shows a slope.
    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let values = samples.map { Double($0.bytes) }
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 1
        let range = highest - lowest
        let inset: CGFloat = 4

        return values.enumerated().map { index, value in
            let x = inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = range > 0 ? (value - lowest) / range : 0.5
            let y = size.height - inset - (size.height - inset * 2) * CGFloat(normalized)
            return CGPoint(x: x, y: y)
        }
    }
}

/// A rounded toolbar-style button, the design's pill with a border.
struct PillButton: View {
    let title: String
    let systemImage: String?
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(Theme.text(13))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .foregroundStyle(isProminent ? Color.white : Theme.ink)
            .background(isProminent ? Theme.accent : Theme.control, in: .capsule)
            .overlay {
                if !isProminent {
                    Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The design's small segmented control (Largest / Least used, and the suspect filters).
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if selection == option.value {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A filter chip that fills in when it is the active one.
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.text(12, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Theme.ink)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(isSelected ? Theme.ink : Color.white, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(isSelected ? Theme.ink : Color.hex(0xE0E0E5), lineWidth: 1)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// The design's two-part figure: a big rounded numeral and a smaller unit beside it.
struct BigSize: View {
    let bytes: Int64
    var numberSize: CGFloat = 34
    var unitSize: CGFloat = 16
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        let parts = Present.sizeParts(bytes)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(parts.value)
                .font(Theme.number(numberSize))
                .tracking(numberSize > 30 ? -1 : -0.4)
            Text(parts.unit)
                .font(Theme.text(unitSize, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
        }
        .accessibilityElement()
        .accessibilityLabel(Present.size(bytes))
    }
}

/// A key/value grid, as in the inspector's metadata block.
struct MetadataGrid: View {
    let rows: [(label: String, value: String, isMonospaced: Bool)]
    var labelWidth: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .font(Theme.text(12))
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(row.value)
                        .font(row.isMonospaced ? Theme.monospacedSmall : Theme.text(12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}


/// Says that a size is short, by how many folders, and what to do about it.
///
/// It deliberately does not guess how many bytes are missing: the whole reason they are missing is
/// that nobody could measure them, and inventing a figure would be worse than admitting the gap.
struct LowerBoundNote: View {
    let unreadableCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.alertBodyInk)
                .frame(width: 18, height: 18)
                .background(Theme.suspectBadgeBackground, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    unreadableCount == 1
                        ? "1 folder inside could not be read, so the real size is larger."
                        : "\(unreadableCount) folders inside could not be read, so the real size is larger."
                )
                .font(Theme.text(11, weight: .semibold))
                .foregroundStyle(Theme.alertTitleInk)
                Text("Grant Jaaga Full Disk Access in System Settings › Privacy & Security to measure them.")
                    .font(Theme.text(11))
                    .foregroundStyle(Theme.alertBodyInk)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.alertBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A small lock beside a size that is a lower bound, for the places with no room for a sentence.
struct IncompleteMarker: View {
    let unreadableCount: Int
    var size: CGFloat = 9

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Theme.alertAccent)
            .help(
                unreadableCount == 1
                    ? "1 folder inside could not be read, so this is a lower bound"
                    : "\(unreadableCount) folders inside could not be read, so this is a lower bound"
            )
            .accessibilityLabel(
                unreadableCount == 1
                    ? "Lower bound: 1 folder could not be read"
                    : "Lower bound: \(unreadableCount) folders could not be read"
            )
    }
}
