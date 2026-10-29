import Foundation
import JaagaProtocol

/// How Jaaga writes sizes, dates and growth. Kept out of the views so it can be tested and so the
/// daemon's numbers are never reformatted twice in two different ways.
public enum Present {
    /// Sizes in the base-10 units the Finder and the rest of macOS use, so Jaaga's "38.6 GB"
    /// matches what About This Mac says rather than disagreeing by 7%.
    ///
    /// Below a gigabyte the design shows whole megabytes ("412 MB"); at or above it, one decimal
    /// ("38.6 GB").
    public static func size(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        switch value {
        case ..<1_000:
            return "\(Int(value)) bytes"
        case ..<1_000_000:
            return "\(Int((value / 1_000).rounded())) KB"
        case ..<1_000_000_000:
            return "\(Int((value / 1_000_000).rounded())) MB"
        case ..<1_000_000_000_000:
            return String(format: "%.1f GB", value / 1_000_000_000)
        default:
            return String(format: "%.2f TB", value / 1_000_000_000_000)
        }
    }

    /// The same string split for the design's two-part number: a big rounded numeral and a unit.
    public static func sizeParts(_ bytes: Int64) -> (value: String, unit: String) {
        let whole = size(bytes)
        guard let separator = whole.lastIndex(of: " ") else { return (whole, "") }
        return (String(whole[whole.startIndex..<separator]), String(whole[whole.index(after: separator)...]))
    }

    /// A compact size for badges and sidebar rows: "220 GB", "38 GB", "412 MB".
    public static func compactSize(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        switch value {
        case ..<1_000_000:
            return "\(Int((value / 1_000).rounded())) KB"
        case ..<1_000_000_000:
            return "\(Int((value / 1_000_000).rounded())) MB"
        case ..<1_000_000_000_000:
            return "\(Int((value / 1_000_000_000).rounded())) GB"
        default:
            return String(format: "%.1f TB", value / 1_000_000_000_000)
        }
    }

    /// A signed delta, for growth figures: "+4.2 GB", "−180 MB", "Steady".
    public static func delta(_ bytes: Int64, steadyBelow: Int64 = 50_000_000) -> String {
        if abs(bytes) < steadyBelow { return "Steady" }
        return bytes > 0 ? "+\(size(bytes))" : "−\(size(-bytes))"
    }

    /// "Today", "Yesterday", "3 days ago", "2 weeks ago", "5 months ago", "2 years ago".
    ///
    /// Vaguer the further back it goes, which is exactly how precise the decision needs to be:
    /// "5 months ago" is enough to know nobody will miss it.
    public static func relativeDay(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Unknown" }
        if date > now { return "Today" }

        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case ..<7: return "\(days) days ago"
        case ..<30:
            let weeks = Int((Double(days) / 7).rounded())
            return weeks <= 1 ? "Last week" : "\(weeks) weeks ago"
        case ..<365:
            let months = Int((Double(days) / 30).rounded())
            return months <= 1 ? "Last month" : "\(months) months ago"
        default:
            let years = Int((Double(days) / 365).rounded())
            return years <= 1 ? "Last year" : "\(years) years ago"
        }
    }

    /// "Today, 9:41" for recent timestamps; "Mar 2, 2021" for older ones.
    public static func timestamp(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Unknown" }
        if calendar.isDateInToday(date) {
            return "Today, " + date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday, " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// "2 min ago" for the toolbar's last-scan label.
    public static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) h ago"
        default: return relativeDay(date, now: now).lowercased()
        }
    }

    /// "1,284,019 items".
    public static func itemCount(_ count: Int) -> String {
        let formatted = count.formatted(.number.grouping(.automatic))
        return count == 1 ? "1 item" : "\(formatted) items"
    }

    /// A share of something, shown to one decimal below 10% and whole numbers above.
    public static func percentage(_ fraction: Double) -> String {
        guard fraction.isFinite, fraction > 0 else { return "0%" }
        let percent = fraction * 100
        if percent < 0.1 { return "<0.1%" }
        return percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    /// "3.1× usual pace" for an accelerating watched folder.
    public static func pace(_ factor: Double?) -> String {
        guard let factor, factor.isFinite, factor > 1 else { return "Faster than usual" }
        return factor >= 10 ? "\(Int(factor.rounded()))× usual pace" : String(format: "%.1f× usual pace", factor)
    }

    public static func label(for verdict: Verdict) -> String {
        switch verdict {
        case .safeToClear: "Safe to clear"
        case .reviewFirst: "Review first"
        case .yourData: "Your data"
        }
    }
}

/// Assigns each sibling a tonal rank within its category, so a folder's children read as shades of
/// one hue: the largest `dev` child takes the deepest purple, the next the one below it.
///
/// This is what keeps the map colourful without turning it into confetti — hue tells you *what kind*
/// of thing it is, shade tells you *how big* it is among its own kind.
public enum ShadeRank {
    /// Ranks entries largest-first inside each category. Returns a rank per path, `0` being deepest.
    public static func ranks(for entries: [Entry], shadesPerCategory: Int = 4) -> [String: Int] {
        var nextRank: [UsageCategory: Int] = [:]
        var result: [String: Int] = [:]
        for entry in entries.sorted(by: { $0.allocatedBytes > $1.allocatedBytes }) {
            let used = nextRank[entry.category] ?? 0
            result[entry.path] = min(used, shadesPerCategory - 1)
            nextRank[entry.category] = used + 1
        }
        return result
    }
}
