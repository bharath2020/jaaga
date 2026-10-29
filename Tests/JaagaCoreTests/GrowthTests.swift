import Foundation
import JaagaProtocol
import Testing

@testable import JaagaCore

@Suite("Growth and alerts")
struct GrowthAnalyzerTests {
    /// A fixed "now" keeps these tests from drifting with the clock.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gigabyte: Int64 = 1_000_000_000

    /// Weekly samples, oldest first, in gigabytes, ending at `now`.
    private func weeklySamples(_ gigabytes: [Double]) -> [SizeSample] {
        let count = gigabytes.count
        return gigabytes.enumerated().map { index, value in
            SizeSample(
                at: now.addingTimeInterval(-Double(count - 1 - index) * 7 * 86_400),
                bytes: Int64(value * 1_000_000_000)
            )
        }
    }

    @Test("A folder with no history has nothing to report")
    func noHistoryMeansNoGrowth() {
        #expect(GrowthAnalyzer.default.summarize(samples: [], now: now) == .none)
        #expect(
            GrowthAnalyzer.default.summarize(
                samples: [SizeSample(at: now, bytes: gigabyte)],
                now: now
            ) == .none,
            "one measurement is a size, not a trend"
        )
    }

    @Test("Delta spans the whole retained history")
    func reportsTotalDelta() {
        let summary = GrowthAnalyzer.default.summarize(
            samples: weeklySamples([21.2, 23.0, 24.1, 26.8, 29.5, 31.0, 35.2, 38.6]),
            now: now
        )

        #expect(summary.deltaBytes == Int64(17.4 * 1_000_000_000))
        #expect(summary.windowSeconds == 7 * 7 * 86_400)
    }

    @Test("Steady growth is not an alert, however much it adds up to")
    func steadyGrowthDoesNotAlert() throws {
        // A gigabyte a week, every week. Large, but not a surprise.
        let steady = weeklySamples([10, 11, 12, 13, 14, 15, 16, 17])

        let summary = GrowthAnalyzer.default.summarize(samples: steady, now: now)

        #expect(summary.deltaBytes > 0)
        #expect(!summary.isAlerting, "the point of the alert is a change of pace, not a big number")
        let factor = try #require(summary.accelerationFactor)
        #expect(abs(factor - 1) < 0.2, "steady means the recent pace matches the baseline")
    }

    @Test("A folder that suddenly speeds up alerts, with the factor to quote")
    func accelerationAlerts() throws {
        // Crept up by ~0.5 GB a week for six weeks, then added 6 GB in the last two.
        let accelerating = weeklySamples([20.0, 20.5, 21.0, 21.5, 22.0, 22.5, 26.0, 32.0])

        let summary = GrowthAnalyzer.default.summarize(samples: accelerating, now: now)

        #expect(summary.isAlerting)
        let factor = try #require(summary.accelerationFactor)
        #expect(factor > 2.5)
        #expect(summary.recentBytesPerDay > summary.baselineBytesPerDay)
    }

    @Test("A folder that was flat and then grows fast alerts without quoting a ratio")
    func flatThenGrowingAlertsWithoutAFactor() {
        let wokenUp = weeklySamples([10, 10, 10, 10, 10, 10, 14, 20])

        let summary = GrowthAnalyzer.default.summarize(samples: wokenUp, now: now)

        #expect(summary.isAlerting)
        #expect(summary.baselineBytesPerDay == 0)
        #expect(summary.accelerationFactor == nil, "dividing by a flat baseline would be meaningless")
    }

    @Test("A folder starred days ago has no baseline yet, so fast growth is not called unusual")
    func newlyWatchedFolderDoesNotAlert() {
        let justStarred = [
            SizeSample(at: now.addingTimeInterval(-3 * 86_400), bytes: 10 * gigabyte),
            SizeSample(at: now.addingTimeInterval(-2 * 86_400), bytes: 11 * gigabyte),
            SizeSample(at: now, bytes: 13 * gigabyte),
        ]

        let summary = GrowthAnalyzer.default.summarize(samples: justStarred, now: now)

        #expect(!summary.isAlerting, "there is no earlier pace for this to be faster than")
        #expect(summary.recentBytesPerDay > 0, "the growth itself is still reported")
    }

    @Test("A tiny folder with a lopsided ratio does not alert")
    func ignoresTrivialGrowth() {
        // 1 KB in the baseline, 40 KB recently: a 40× ratio over nothing at all.
        let trivial = [
            SizeSample(at: now.addingTimeInterval(-50 * 86_400), bytes: 1_000_000),
            SizeSample(at: now.addingTimeInterval(-20 * 86_400), bytes: 1_001_000),
            SizeSample(at: now.addingTimeInterval(-1 * 86_400), bytes: 1_041_000),
        ]

        let summary = GrowthAnalyzer.default.summarize(samples: trivial, now: now)

        #expect(!summary.isAlerting, "40× of nothing is still nothing")
    }

    @Test("A shrinking folder never alerts")
    func shrinkingNeverAlerts() {
        let cleared = weeklySamples([38.6, 35.0, 30.0, 24.0, 18.0, 12.0, 6.0, 1.0])

        let summary = GrowthAnalyzer.default.summarize(samples: cleared, now: now)

        #expect(summary.deltaBytes < 0)
        #expect(!summary.isAlerting)
        #expect(summary.recentBytesPerDay < 0)
    }

    @Test("Samples out of order are sorted before anything is computed")
    func toleratesUnorderedSamples() {
        let ordered = weeklySamples([10, 12, 14, 16, 20, 26, 34, 44])
        let shuffled = ordered.shuffled()

        #expect(
            GrowthAnalyzer.default.summarize(samples: shuffled, now: now)
                == GrowthAnalyzer.default.summarize(samples: ordered, now: now)
        )
    }

    @Test("The alert sentence names the folder and the pace")
    func alertMessageReadsWell() {
        let analyzer = GrowthAnalyzer.default
        let summary = analyzer.summarize(
            samples: weeklySamples([20.0, 20.5, 21.0, 21.5, 22.0, 22.5, 26.0, 32.0]),
            now: now
        )

        let message = analyzer.alertMessage(name: "DerivedData", summary: summary)
        #expect(message.hasPrefix("DerivedData is growing "))
        #expect(message.hasSuffix(" faster than usual"))
        #expect(message.contains("×"))
    }

    @Test("A folder with no ratio still gets a sentence that makes sense")
    func alertMessageWithoutAFactor() {
        let analyzer = GrowthAnalyzer.default
        let summary = analyzer.summarize(samples: weeklySamples([10, 10, 10, 10, 10, 10, 14, 20]), now: now)

        #expect(analyzer.alertMessage(name: "Downloads", summary: summary)
            == "Downloads started growing after a quiet spell")
    }

    @Test("A stricter threshold is respected")
    func thresholdIsConfigurable() {
        let samples = weeklySamples([20.0, 20.5, 21.0, 21.5, 22.0, 22.5, 26.0, 32.0])
        let lenient = GrowthAnalyzer(alertFactor: 50)

        #expect(!lenient.summarize(samples: samples, now: now).isAlerting)
        #expect(GrowthAnalyzer(alertFactor: 1.2).summarize(samples: samples, now: now).isAlerting)
    }
}

@Suite("Watched folder storage")
struct WatchStoreTests {
    @Test("Starring a folder survives a restart")
    func persistsAcrossInstances() async throws {
        let tree = try TemporaryTree()
        let file = tree.root.appendingPathComponent("watched.json")

        let first = WatchStore(fileURL: file)
        try await first.watch(path: "/Users/tester/Library/Caches", currentBytes: 1_000)

        let second = WatchStore(fileURL: file)
        #expect(await second.isWatched("/Users/tester/Library/Caches"))
        let record = try #require(await second.record(for: "/Users/tester/Library/Caches"))
        #expect(record.samples.count == 1)
        #expect(record.latestBytes == 1_000)
    }

    @Test("Starring an already-watched folder keeps its history")
    func keepsHistoryWhenStarredAgain() async throws {
        let tree = try TemporaryTree()
        let store = WatchStore(fileURL: tree.root.appendingPathComponent("watched.json"))
        let path = "/Users/tester/Downloads"
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.watch(path: path, at: start, currentBytes: 100)
        try await store.addSample(path: path, bytes: 200, at: start.addingTimeInterval(86_400))
        try await store.watch(path: path, at: start.addingTimeInterval(2 * 86_400), currentBytes: 300)

        let record = try #require(await store.record(for: path))
        #expect(record.samples.count == 3)
        #expect(record.addedAt == start, "the original star date is not reset")
    }

    @Test("Unwatching forgets the folder and reports whether it was there")
    func unwatchReportsWhetherItRemovedAnything() async throws {
        let tree = try TemporaryTree()
        let store = WatchStore(fileURL: tree.root.appendingPathComponent("watched.json"))

        try await store.watch(path: "/tmp/a", currentBytes: 1)
        #expect(try await store.unwatch(path: "/tmp/a"))
        #expect(try await store.unwatch(path: "/tmp/a") == false)
        #expect(await store.isWatched("/tmp/a") == false)
    }

    @Test("A trailing slash is the same folder")
    func normalisesPaths() async throws {
        let tree = try TemporaryTree()
        let store = WatchStore(fileURL: tree.root.appendingPathComponent("watched.json"))

        try await store.watch(path: "/tmp/somewhere/", currentBytes: 1)
        #expect(await store.isWatched("/tmp/somewhere"))
        #expect(await store.watchedPaths == ["/tmp/somewhere"])
    }

    @Test("A sample taken moments after the last one replaces it instead of adding noise")
    func coalescesRapidSamples() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = [SizeSample(at: base, bytes: 100)]

        let result = WatchStore.appending(SizeSample(at: base.addingTimeInterval(5), bytes: 150), to: existing)

        #expect(result.count == 1)
        #expect(result[0].bytes == 150)
    }

    @Test("History stays bounded, keeping the oldest and newest points")
    func thinsOldSamples() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [SizeSample] = []
        // One a minute for a year's worth of points: far more than the cap.
        for index in 0..<(WatchStore.maximumSamples * 3) {
            samples = WatchStore.appending(
                SizeSample(at: base.addingTimeInterval(Double(index) * 120), bytes: Int64(index) * 1_000),
                to: samples
            )
        }

        #expect(samples.count <= WatchStore.maximumSamples)
        #expect(samples.first?.at == base, "the oldest point anchors the total delta")
        #expect(samples.last?.bytes == Int64(WatchStore.maximumSamples * 3 - 1) * 1_000)
        #expect(samples.map(\.at) == samples.map(\.at).sorted())
    }

    @Test("A corrupt state file is stepped over rather than crashing the daemon")
    func survivesCorruptState() async throws {
        let tree = try TemporaryTree()
        let file = tree.root.appendingPathComponent("watched.json")
        try Data("this is not json".utf8).write(to: file)

        let store = WatchStore(fileURL: file)
        #expect(await store.watchedPaths.isEmpty)

        // And it can still be written to afterwards.
        try await store.watch(path: "/tmp/fresh", currentBytes: 5)
        #expect(await store.isWatched("/tmp/fresh"))

        // Without losing what was there: history a later version wrote must survive the next save.
        let kept = try FileManager.default.contentsOfDirectory(at: tree.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "watched.json" }
            .compactMap { try? Data(contentsOf: $0) }
        #expect(kept.contains(Data("this is not json".utf8)), "the unreadable file was overwritten")
    }
}
