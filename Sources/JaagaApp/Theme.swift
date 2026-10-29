import JaagaProtocol
import SwiftUI

/// The approved design's palette and metrics, in one place.
///
/// Colours are the design's literal hex values rather than system colours, because the whole point of
/// the space map is that a hue means a *kind* of thing and a shade means how big it is among its own
/// kind. Substituting semantic system colours would lose that.
///
/// Jaaga ships light-only for now; the tokens are named so a dark set can be added beside them.
enum Theme {
    // MARK: - Category hues, deepest shade first

    /// Four tonal steps per category. Within a folder, siblings of the same category take
    /// successively lighter steps, largest first.
    static func shades(for category: UsageCategory) -> [Color] {
        switch category {
        case .cache: [.hex(0x8F3B00), .hex(0xB05300), .hex(0xF29B38), .hex(0xF9C98C)]
        case .media: [.hex(0xA3144C), .hex(0xCC2C6C), .hex(0xEC6F9E), .hex(0xF6B3CC)]
        case .dev: [.hex(0x5B3BD9), .hex(0x7253F0), .hex(0x9C86F7), .hex(0xC4B6FB)]
        case .apps: [.hex(0x004CA8), .hex(0x1869D1), .hex(0x6AA8F2), .hex(0xAFD0F8)]
        case .docs: [.hex(0x00606B), .hex(0x057F8D), .hex(0x4FC0CC), .hex(0x9BDDE4)]
        case .downloads: [.hex(0x17692F), .hex(0x22803D), .hex(0x6BC685), .hex(0xAEE2BC)]
        case .photos: [.hex(0x7A5A00), .hex(0x94700A), .hex(0xF2C230), .hex(0xF8DC85)]
        case .system: [.hex(0x48484D), .hex(0x636368), .hex(0x98989E), .hex(0xC7C7CC)]
        }
    }

    static func color(for category: UsageCategory, shade: Int = 1) -> Color {
        let palette = shades(for: category)
        return palette[min(max(shade, 0), palette.count - 1)]
    }

    /// The RGB the readability check works on, since SwiftUI's `Color` will not hand them back.
    static func components(for category: UsageCategory, shade: Int) -> (r: Double, g: Double, b: Double) {
        let hexes = hexValues(for: category)
        let value = hexes[min(max(shade, 0), hexes.count - 1)]
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private static func hexValues(for category: UsageCategory) -> [UInt32] {
        switch category {
        case .cache: [0x8F3B00, 0xB05300, 0xF29B38, 0xF9C98C]
        case .media: [0xA3144C, 0xCC2C6C, 0xEC6F9E, 0xF6B3CC]
        case .dev: [0x5B3BD9, 0x7253F0, 0x9C86F7, 0xC4B6FB]
        case .apps: [0x004CA8, 0x1869D1, 0x6AA8F2, 0xAFD0F8]
        case .docs: [0x00606B, 0x057F8D, 0x4FC0CC, 0x9BDDE4]
        case .downloads: [0x17692F, 0x22803D, 0x6BC685, 0xAEE2BC]
        case .photos: [0x7A5A00, 0x94700A, 0xF2C230, 0xF8DC85]
        case .system: [0x48484D, 0x636368, 0x98989E, 0xC7C7CC]
        }
    }

    /// White or near-black, whichever is more readable on the given tile.
    ///
    /// The light end of each hue (`F9C98C`, `AEE2BC`) needs dark text; the deep end needs white. The
    /// design picks per tile by contrast rather than per category, and so does this.
    static func foreground(onCategory category: UsageCategory, shade: Int) -> Color {
        let (r, g, b) = components(for: category, shade: shade)
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        let againstWhite = 1.05 / (luminance + 0.05)
        let againstInk = (luminance + 0.05) / (Self.inkLuminance + 0.05)
        return againstWhite >= againstInk ? .white : Self.tileInk
    }

    /// The near-black the design uses on light tiles (`#16161A`).
    static let tileInk = Color.hex(0x16161A)
    private static let inkLuminance = 0.0068

    // MARK: - Neutrals

    static let ink = Color.hex(0x1D1D1F)
    static let secondaryInk = Color.hex(0x6E6E73)
    static let tertiaryInk = Color.hex(0x8E8E93)
    static let labelInk = Color.hex(0x46464B)
    static let windowBackground = Color.white
    static let sidebarBackground = Color.hex(0xF3F3F6)
    static let sidebarBorder = Color.hex(0xE5E5EA)
    static let control = Color.hex(0xF3F3F6)
    static let controlBorder = Color.hex(0xE5E5EA)
    static let divider = Color.hex(0xEDEDF0)
    static let trackBackground = Color.hex(0xEFEFF3)
    static let selectedRow = Color.hex(0xEDF2FD)
    static let selectedNav = Color.hex(0xE3E3EA)
    static let quietPanel = Color.hex(0xF7F7FA)
    static let tilePanel = Color.hex(0xF6F6F9)
    static let accent = Color.hex(0x0A60D6)
    static let link = Color.hex(0x0A60D6)
    static let dashedBorder = Color.hex(0xD1D1D6)
    static let placeholderIcon = Color.hex(0xAEAEB2)

    static let star = Color.hex(0xF5B400)
    static let starBorder = Color.hex(0xD99A00)
    static let starOff = Color.hex(0xAEAEB2)
    static let watchingBackground = Color.hex(0xFFF6D9)
    static let watchingBorder = Color.hex(0xF5D77A)

    static let destructiveBackground = Color.hex(0xFDECEE)
    static let destructiveInk = Color.hex(0xB0001A)

    static let alertBackground = Color.hex(0xFFF4E3)
    static let alertAccent = Color.hex(0xB05300)
    static let alertTitleInk = Color.hex(0x5C3000)
    static let alertBodyInk = Color.hex(0x7F4300)
    static let alertBorder = Color.hex(0xF29B38)

    static let suspectBadgeBackground = Color.hex(0xFFE7C2)
    static let suspectBadgeInk = Color.hex(0x7F4300)
    static let suspectChipBackground = Color.hex(0xFFEFD6)
    static let countBadgeBackground = Color.hex(0xE4E4EA)
    static let countBadgeInk = Color.hex(0x46464B)

    // MARK: - Verdicts

    struct VerdictStyle {
        var label: String
        var pillBackground: Color
        var pillInk: Color
        var cardBackground: Color
        var dot: Color
    }

    static func style(for verdict: Verdict) -> VerdictStyle {
        switch verdict {
        case .safeToClear:
            VerdictStyle(
                label: "Safe to clear",
                pillBackground: .hex(0xE2F5E7),
                pillInk: .hex(0x12622B),
                cardBackground: .hex(0xF2FAF4),
                dot: .hex(0x22803D)
            )
        case .reviewFirst:
            VerdictStyle(
                label: "Review first",
                pillBackground: .hex(0xFFEFD6),
                pillInk: .hex(0x7F4300),
                cardBackground: .hex(0xFFF8EC),
                dot: .hex(0xB05300)
            )
        case .yourData:
            VerdictStyle(
                label: "Your data",
                pillBackground: .hex(0xECECF1),
                pillInk: .hex(0x46464B),
                cardBackground: .hex(0xF6F6F9),
                dot: .hex(0x636368)
            )
        }
    }

    // MARK: - Type

    /// The design's big figures are set in a rounded face with tabular digits, so a column of sizes
    /// lines up and a number never jitters as it counts up during a scan.
    static func number(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    // MARK: - Metrics

    static let sidebarWidth: CGFloat = 232
    static let inspectorWidth: CGFloat = 336
    static let toolbarHeight: CGFloat = 52
    static let rowHeight: CGFloat = 40
    static let windowSize = CGSize(width: 1_440, height: 900)
    static let minimumWindowSize = CGSize(width: 1_080, height: 680)
}

extension Color {
    /// A colour from the design's hex, in sRGB, so the app matches the mockup exactly.
    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
