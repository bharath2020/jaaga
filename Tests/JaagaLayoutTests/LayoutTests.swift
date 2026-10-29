import CoreGraphics
import Foundation
import JaagaProtocol
import Testing

@testable import JaagaLayout

@Suite("Squarified treemap")
struct TreemapTests {
    private let bounds = CGRect(x: 0, y: 0, width: 824, height: 300)

    private func tiles(_ weights: [Double], in rect: CGRect? = nil) -> [Treemap.Tile<Double>] {
        Treemap.squarify(weights, weight: { $0 }, in: rect ?? bounds)
    }

    @Test("Every tile fits inside the bounds it was given")
    func tilesStayInBounds() {
        for tile in tiles([220.4, 96.2, 74.5, 41.7, 38.9, 22.1, 9.8, 4.6]) {
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(tile.frame), "\(tile.frame) escaped \(bounds)")
        }
    }

    @Test("The tiles fill the whole area, with no gaps or overlaps")
    func tilesTileTheArea() {
        let weights = [220.4, 96.2, 74.5, 41.7, 38.9, 22.1, 9.8, 4.6]

        let total = tiles(weights).reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }

        #expect(abs(total - Double(bounds.width * bounds.height)) < 1.0)
    }

    @Test("A tile's area is proportional to its weight")
    func areaFollowsWeight() {
        let weights = [100.0, 50.0, 25.0]
        let laid = tiles(weights)

        let areas = laid.map { Double($0.frame.width * $0.frame.height) }
        let totalArea = areas.reduce(0, +)
        let totalWeight = weights.reduce(0, +)

        for (index, area) in areas.enumerated() {
            let expected = weights[index] / totalWeight * totalArea
            #expect(abs(area - expected) / expected < 0.001)
        }
    }

    @Test("The largest item comes first, so the eye lands on what matters")
    func largestFirst() {
        let laid = tiles([10, 220, 96, 4])

        #expect(laid.first?.element == 220)
        #expect(laid.map(\.element) == [220, 96, 10, 4])
    }

    @Test("Tiles are roughly square rather than slivers")
    func tilesAreSquarish() {
        // Eight similar-sized items: slice-and-dice would make eight 103pt-wide slivers.
        let laid = tiles(Array(repeating: 40.0, count: 8))

        for tile in laid {
            let ratio = Double(max(tile.frame.width, tile.frame.height) / min(tile.frame.width, tile.frame.height))
            #expect(ratio < 2.2, "aspect ratio \(ratio) is too elongated to compare by eye")
        }
    }

    @Test("Zero-sized items are dropped rather than given a sliver")
    func dropsEmptyItems() {
        let laid = tiles([100, 0, 50, 0, -5])

        #expect(laid.map(\.element) == [100, 50])
    }

    @Test("An empty list, or a zero-sized frame, lays out nothing")
    func handlesDegenerateInput() {
        #expect(tiles([]).isEmpty)
        #expect(tiles([100, 50], in: .zero).isEmpty)
        #expect(tiles([100, 50], in: CGRect(x: 0, y: 0, width: 100, height: 0)).isEmpty)
    }

    @Test("A single item takes the whole frame")
    func singleItemFillsTheFrame() {
        let laid = tiles([42])

        #expect(laid.count == 1)
        // Within floating-point noise: the area is divided by a scale factor, so the last tile's
        // edge lands a fraction of a point short of the bound.
        #expect(abs(laid[0].frame.width - bounds.width) < 0.001)
        #expect(abs(laid[0].frame.height - bounds.height) < 0.001)
        #expect(laid[0].frame.origin == bounds.origin)
    }

    @Test("A tall frame is filled as readily as a wide one")
    func worksInEitherOrientation() {
        let tall = CGRect(x: 0, y: 0, width: 300, height: 824)
        let laid = tiles([220.4, 96.2, 74.5, 41.7], in: tall)

        let area = laid.reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }
        #expect(abs(area - Double(tall.width * tall.height)) < 1.0)
        for tile in laid {
            #expect(tall.insetBy(dx: -0.01, dy: -0.01).contains(tile.frame))
        }
    }

    @Test("One dominant item and many small ones still lays out cleanly")
    func handlesLopsidedInput() {
        let laid = tiles([1_000] + Array(repeating: 1.0, count: 40))

        #expect(laid.count == 41)
        let area = laid.reduce(0.0) { $0 + Double($1.frame.width * $1.frame.height) }
        #expect(abs(area - Double(bounds.width * bounds.height)) < 1.0)
        for tile in laid {
            #expect(tile.frame.width > 0 && tile.frame.height > 0)
        }
    }
}

@Suite("Shade ranking")
struct ShadeRankTests {
    private func entry(_ name: String, _ bytes: Int64, _ category: UsageCategory) -> Entry {
        Entry(
            path: "/Users/me/\(name)",
            name: name,
            isDirectory: true,
            allocatedBytes: bytes,
            itemCount: 1,
            directChildCount: 0,
            category: category,
            verdict: .yourData,
            reason: "",
            kind: "Folder"
        )
    }

    @Test("Within a category, the largest folder takes the deepest shade")
    func ranksBySizeWithinCategory() {
        let entries = [
            entry("small-dev", 10, .dev),
            entry("big-dev", 100, .dev),
            entry("mid-dev", 50, .dev),
        ]

        let ranks = ShadeRank.ranks(for: entries)

        #expect(ranks["/Users/me/big-dev"] == 0)
        #expect(ranks["/Users/me/mid-dev"] == 1)
        #expect(ranks["/Users/me/small-dev"] == 2)
    }

    @Test("Each category ranks independently, so hue still means kind")
    func categoriesRankSeparately() {
        let entries = [
            entry("huge-media", 900, .media),
            entry("big-dev", 100, .dev),
            entry("small-media", 5, .media),
        ]

        let ranks = ShadeRank.ranks(for: entries)

        #expect(ranks["/Users/me/big-dev"] == 0, "the only dev folder takes dev's deepest shade")
        #expect(ranks["/Users/me/huge-media"] == 0)
        #expect(ranks["/Users/me/small-media"] == 1)
    }

    @Test("Ranks stop at the last available shade rather than running off the palette")
    func clampsToAvailableShades() {
        let entries = (0..<10).map { entry("dev-\($0)", Int64(100 - $0), .dev) }

        let ranks = ShadeRank.ranks(for: entries)

        #expect(ranks.values.max() == 3, "four shades per hue, so rank 3 is the lightest")
        #expect(ranks["/Users/me/dev-9"] == 3)
    }
}

@Suite("How numbers and dates read")
struct PresentTests {
    @Test("Sizes use the base-10 units the rest of macOS uses")
    func sizesMatchTheFinder() {
        #expect(Present.size(38_600_000_000) == "38.6 GB")
        #expect(Present.size(412_000_000) == "412 MB")
        #expect(Present.size(1_200_000_000_000) == "1.20 TB")
        #expect(Present.size(4_096) == "4 KB")
        #expect(Present.size(512) == "512 bytes")
        #expect(Present.size(0) == "0 bytes")
    }

    @Test("A negative size never leaks into the interface")
    func clampsNegativeSizes() {
        #expect(Present.size(-1) == "0 bytes")
    }

    @Test("Sizes split into a numeral and a unit for the big display figures")
    func splitsSizeParts() {
        let parts = Present.sizeParts(38_600_000_000)

        #expect(parts.value == "38.6")
        #expect(parts.unit == "GB")
    }

    @Test("Compact sizes drop the decimal for badges")
    func compactSizes() {
        #expect(Present.compactSize(38_600_000_000) == "39 GB")
        #expect(Present.compactSize(220_400_000_000) == "220 GB")
        #expect(Present.compactSize(412_000_000) == "412 MB")
    }

    @Test("Growth reads as a signed delta, and small drift reads as steady")
    func deltas() {
        #expect(Present.delta(4_200_000_000) == "+4.2 GB")
        #expect(Present.delta(-180_000_000) == "−180 MB")
        #expect(Present.delta(1_000) == "Steady")
    }

    @Test("Dates get vaguer the further back they go")
    func relativeDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func ago(_ days: Double) -> String {
            Present.relativeDay(now.addingTimeInterval(-days * 86_400), now: now, calendar: calendar)
        }

        #expect(ago(0) == "Today")
        #expect(ago(1) == "Yesterday")
        #expect(ago(3) == "3 days ago")
        #expect(ago(21) == "3 weeks ago")
        #expect(ago(150) == "5 months ago")
        #expect(ago(800) == "2 years ago")
        #expect(Present.relativeDay(nil) == "Unknown")
    }

    @Test("Elapsed time reads the way the toolbar needs it")
    func elapsedTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(Present.elapsed(since: now.addingTimeInterval(-5), now: now) == "just now")
        #expect(Present.elapsed(since: now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(Present.elapsed(since: now.addingTimeInterval(-7_200), now: now) == "2 h ago")
    }

    @Test("Percentages keep a decimal only where it carries information")
    func percentages() {
        #expect(Present.percentage(0.0388) == "3.9%")
        #expect(Present.percentage(0.221) == "22%")
        #expect(Present.percentage(0.0001) == "<0.1%")
        #expect(Present.percentage(0) == "0%")
        #expect(Present.percentage(.nan) == "0%")
    }

    @Test("Pace reads as a multiple of the folder's own habit")
    func pace() {
        #expect(Present.pace(3.14) == "3.1× usual pace")
        #expect(Present.pace(12.6) == "13× usual pace")
        #expect(Present.pace(nil) == "Faster than usual")
    }

    @Test("Verdict labels are the design's words")
    func verdictLabels() {
        #expect(Present.label(for: .safeToClear) == "Safe to clear")
        #expect(Present.label(for: .reviewFirst) == "Review first")
        #expect(Present.label(for: .yourData) == "Your data")
    }

    @Test("Item counts are grouped and singular when there is one")
    func itemCounts() {
        #expect(Present.itemCount(1) == "1 item")
        #expect(Present.itemCount(1_284_019).hasSuffix("items"))
        #expect(Present.itemCount(1_284_019).contains(","))
    }
}
