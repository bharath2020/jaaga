import Foundation
import JaagaProtocol

/// Decides whether a watched folder is growing unusually fast *for itself*.
///
/// An absolute threshold would be useless here: `~/Library/Caches` gaining a gigabyte a week is
/// normal, while a project folder doing the same is a runaway build. So the comparison is always
/// against the folder's own earlier pace.
///
/// ```
///  bytes
///    │                                        ╭── recent window ──╮
///    │                          ╭─────────────┤   recentRate      │
///    │      ╭───────────────────┤  baseline   │                   │
///    └──────┴───────────────────┴─────────────┴───────────────────▶ time
///                                             alert when recentRate ≥ factor × baselineRate
/// ```
public struct GrowthAnalyzer: Sendable, Hashable {
    /// How far back "recently" reaches.
    public var recentWindow: TimeInterval
    /// How far back the comparison pace is measured from.
    public var baselineWindow: TimeInterval
    /// How many times the baseline pace counts as "much faster".
    public var alertFactor: Double
    /// Growth slower than this never alerts, however lopsided the ratio. Without it, a folder that
    /// crept up by two kilobytes after a month of stillness would look like a 100× emergency.
    public var minimumRecentBytesPerDay: Int64

    public init(
        recentWindow: TimeInterval = 14 * 86_400,
        baselineWindow: TimeInterval = 56 * 86_400,
        alertFactor: Double = 2.5,
        minimumRecentBytesPerDay: Int64 = 100_000_000
    ) {
        self.recentWindow = recentWindow
        self.baselineWindow = baselineWindow
        self.alertFactor = alertFactor
        self.minimumRecentBytesPerDay = minimumRecentBytesPerDay
    }

    public static let `default` = GrowthAnalyzer()

    /// Summarises `samples`, which need not be sorted.
    ///
    /// Fewer than two samples means there is nothing to compare yet, so the result is all zeroes
    /// and never alerting: a folder starred a minute ago has no history to be unusual against. The
    /// same goes for a folder with no samples from before the recent window: a missing baseline is
    /// not a flat one.
    public func summarize(samples: [SizeSample], now: Date = Date()) -> GrowthSummary {
        let ordered = samples.sorted { $0.at < $1.at }
        guard let oldest = ordered.first, let newest = ordered.last, ordered.count >= 2 else {
            return .none
        }

        let delta = newest.bytes - oldest.bytes
        let span = newest.at.timeIntervalSince(oldest.at)

        let recentStart = now.addingTimeInterval(-recentWindow)
        let baselineStart = now.addingTimeInterval(-baselineWindow)

        let recentRate = rate(in: ordered, from: recentStart, to: now) ?? 0
        let measuredBaseline = rate(in: ordered, from: baselineStart, to: recentStart)
        let baselineRate = measuredBaseline ?? 0

        var factor: Double?
        var alerting = false

        if measuredBaseline != nil, recentRate >= Double(minimumRecentBytesPerDay) {
            if baselineRate > 0 {
                factor = recentRate / baselineRate
                alerting = (factor ?? 0) >= alertFactor
            } else {
                // Flat, then suddenly growing fast. There is no ratio to quote, but it is exactly
                // the situation worth a word.
                alerting = true
            }
        }

        return GrowthSummary(
            deltaBytes: delta,
            windowSeconds: span,
            recentBytesPerDay: recentRate,
            baselineBytesPerDay: baselineRate,
            accelerationFactor: factor,
            isAlerting: alerting
        )
    }

    /// Bytes per day across `[start, end]`, measured from the samples bracketing that interval.
    ///
    /// The sample just *before* `start` is included when there is one, so the rate covers the whole
    /// window rather than only the growth between the first and last sample inside it. `nil` when
    /// there are not two samples spanning any of the window, so there is no rate to speak of.
    private func rate(in ordered: [SizeSample], from start: Date, to end: Date) -> Double? {
        let inside = ordered.filter { $0.at >= start && $0.at <= end }
        let anchor = ordered.last { $0.at < start }

        guard let last = inside.last else { return nil }
        guard let first = anchor ?? inside.first, first.at < last.at else { return nil }

        let days = last.at.timeIntervalSince(first.at) / 86_400
        guard days > 0 else { return nil }
        return Double(last.bytes - first.bytes) / days
    }

    /// The sentence the alert shows.
    public func alertMessage(name: String, summary: GrowthSummary) -> String {
        guard let factor = summary.accelerationFactor, factor.isFinite, factor > 1 else {
            return "\(name) started growing after a quiet spell"
        }
        let rounded = factor >= 10
            ? "\(Int(factor.rounded()))×"
            : String(format: "%.1f×", factor)
        return "\(name) is growing \(rounded) faster than usual"
    }
}
