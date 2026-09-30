import Foundation
import JaagaCore
import JaagaProtocol

public struct DaemonConfiguration: Sendable {
    public var paths: JaagaPaths
    /// The folder Jaaga treats as "home": the default scan root and the base for catalog paths.
    /// Injectable so tests run against a temporary tree and never touch the user's own state.
    public var home: String
    public var daemonVersion: String
    public var scan: ScanConfiguration
    public var growth: GrowthAnalyzer
    public var cacheCapacity: Int
    public var cacheTimeToLive: TimeInterval
    /// How often watched folders are re-measured.
    public var samplingInterval: TimeInterval
    /// Whether to run an FSEvents stream over the watched folders. Off in tests, which drive the
    /// invalidation path directly rather than waiting on the filesystem.
    public var watchesFileSystem: Bool
    /// How many scans may run at once.
    public var scanConcurrency: Int

    public init(
        paths: JaagaPaths,
        home: String = NSHomeDirectory(),
        daemonVersion: String = JaagaDaemonVersion.current,
        scan: ScanConfiguration = .default,
        growth: GrowthAnalyzer = .default,
        cacheCapacity: Int = 4_096,
        cacheTimeToLive: TimeInterval = 15 * 60,
        samplingInterval: TimeInterval = 3_600,
        watchesFileSystem: Bool = true,
        scanConcurrency: Int = 2
    ) {
        self.paths = paths
        self.home = (home as NSString).standardizingPath
        self.daemonVersion = daemonVersion
        self.scan = scan
        self.growth = growth
        self.cacheCapacity = cacheCapacity
        self.cacheTimeToLive = cacheTimeToLive
        self.samplingInterval = samplingInterval
        self.watchesFileSystem = watchesFileSystem
        self.scanConcurrency = scanConcurrency
    }

    /// The real per-user configuration.
    public static func current() -> DaemonConfiguration {
        DaemonConfiguration(paths: .current, home: NSHomeDirectory())
    }
}

public enum JaagaDaemonVersion {
    public static let current = "1.0.0"
}
