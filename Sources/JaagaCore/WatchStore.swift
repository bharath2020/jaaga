import Foundation
import JaagaProtocol

/// One watched folder as it is stored on disk.
public struct WatchRecord: Sendable, Hashable, Codable {
    public var path: String
    public var addedAt: Date
    /// Oldest first.
    public var samples: [SizeSample]

    public init(path: String, addedAt: Date, samples: [SizeSample] = []) {
        self.path = path
        self.addedAt = addedAt
        self.samples = samples
    }

    public var latestBytes: Int64 { samples.last?.bytes ?? 0 }
}

/// The durable list of starred folders and their size history.
///
/// This is the one piece of Jaaga's state that must survive a restart: the history *is* the
/// feature. Writes go through a temporary file and an atomic rename, so an interrupted write leaves
/// the previous history intact rather than a half-written file.
public actor WatchStore {
    /// Keep roughly a year of hourly samples, thinned as they age. Enough for the eight-week trend
    /// the design shows, with room to spot a slower drift.
    public static let maximumSamples = 400
    /// Samples closer together than this are thinned out of the older history.
    public static let thinningInterval: TimeInterval = 3_600

    private let fileURL: URL
    private var records: [String: WatchRecord]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.records = Self.read(from: fileURL)
    }

    public var watchedPaths: [String] {
        records.keys.sorted()
    }

    public func record(for path: String) -> WatchRecord? {
        records[Self.normalize(path)]
    }

    public func allRecords() -> [WatchRecord] {
        records.values.sorted { $0.addedAt < $1.addedAt }
    }

    public func isWatched(_ path: String) -> Bool {
        records[Self.normalize(path)] != nil
    }

    /// Starts watching `path`. Already-watched paths keep their history rather than losing it to a
    /// second star.
    @discardableResult
    public func watch(path: String, at date: Date = Date(), currentBytes: Int64?) throws -> WatchRecord {
        let key = Self.normalize(path)
        var record = records[key] ?? WatchRecord(path: key, addedAt: date)
        if let currentBytes {
            record.samples = Self.appending(
                SizeSample(at: date, bytes: currentBytes),
                to: record.samples
            )
        }
        records[key] = record
        try persist()
        return record
    }

    @discardableResult
    public func unwatch(path: String) throws -> Bool {
        let key = Self.normalize(path)
        guard records.removeValue(forKey: key) != nil else { return false }
        try persist()
        return true
    }

    /// Records a fresh measurement. Returns the updated record, or nil if the path is not watched.
    @discardableResult
    public func addSample(path: String, bytes: Int64, at date: Date = Date()) throws -> WatchRecord? {
        let key = Self.normalize(path)
        guard var record = records[key] else { return nil }
        record.samples = Self.appending(SizeSample(at: date, bytes: bytes), to: record.samples)
        records[key] = record
        try persist()
        return record
    }

    // MARK: - Sample retention

    /// Appends a sample, then thins the history so it stays bounded.
    ///
    /// The newest samples are kept as they came in — they are what the growth figure is built from.
    /// Older ones are thinned to one per `thinningInterval`, and if that is still too many, every
    /// other older sample goes. The oldest sample is always kept so the total delta stays honest.
    static func appending(_ sample: SizeSample, to samples: [SizeSample]) -> [SizeSample] {
        var result = samples
        // A second measurement within the same minute replaces the first rather than adding noise.
        if let last = result.last, sample.at.timeIntervalSince(last.at) < 60 {
            result[result.count - 1] = sample
        } else {
            result.append(sample)
        }
        result.sort { $0.at < $1.at }

        guard result.count > maximumSamples else { return result }

        let cutoff = result.count / 2
        var thinned: [SizeSample] = []
        thinned.reserveCapacity(maximumSamples)
        var lastKept: Date?
        for (index, candidate) in result.enumerated() {
            let isRecent = index >= cutoff
            let isFirst = index == 0
            if isRecent || isFirst {
                thinned.append(candidate)
                lastKept = candidate.at
                continue
            }
            if let lastKept, candidate.at.timeIntervalSince(lastKept) < thinningInterval { continue }
            thinned.append(candidate)
            lastKept = candidate.at
        }

        // Still too many after thinning by time: drop every other one of the older half.
        if thinned.count > maximumSamples {
            let overflow = thinned.count - maximumSamples
            var dropped = 0
            var kept: [SizeSample] = [thinned[0]]
            for index in 1..<thinned.count {
                let inOlderHalf = index < thinned.count / 2
                if inOlderHalf, dropped < overflow, index % 2 == 1 {
                    dropped += 1
                    continue
                }
                kept.append(thinned[index])
            }
            thinned = kept
        }
        return thinned
    }

    // MARK: - Persistence

    private struct Document: Codable {
        var version: Int
        var records: [WatchRecord]
    }

    private static let documentVersion = 1

    private static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    private static func read(from url: URL) -> [String: WatchRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let document = try? decoder.decode(Document.self, from: data),
              document.version == documentVersion
        else {
            // An unreadable or future-versioned file is left untouched on disk; starting from an
            // empty list is better than refusing to run, and better than overwriting history we do
            // not understand.
            return [:]
        }
        return Dictionary(document.records.map { (normalize($0.path), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() throws {
        let document = Document(version: Self.documentVersion, records: allRecords())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: .atomic)
        // Replace, not write-in-place: a crash mid-write leaves the old history readable.
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
    }
}
