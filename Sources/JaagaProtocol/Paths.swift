import Foundation

/// Where the daemon keeps its socket and its durable state.
///
/// Both the app and any future CLI or MCP server resolve these the same way, so the only thing a
/// client needs in order to find a running daemon is the user's home directory.
public struct JaagaPaths: Sendable, Hashable {
    /// `~/Library/Application Support/Jaaga`
    public let supportDirectory: URL
    public let socketPath: String
    /// Durable watched-folder list and size history.
    public let watchStatePath: URL
    /// Optional user override for the usual-suspects catalog.
    public let catalogOverridePath: URL

    public static let directoryName = "Jaaga"
    public static let socketFileName = "jaagad.sock"
    /// `sockaddr_un.sun_path` is a fixed 104-byte field on Darwin, including its terminator.
    public static let maximumSocketPathBytes = 103

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.socketPath = supportDirectory.appendingPathComponent(Self.socketFileName).path
        self.watchStatePath = supportDirectory.appendingPathComponent("watched.json")
        self.catalogOverridePath = supportDirectory.appendingPathComponent("suspects.json")
    }

    /// The real per-user location. `home` is injectable so tests never touch the user's own state.
    public init(home: URL) {
        self.init(
            supportDirectory: home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    /// The environment variable that points Jaaga at a different home folder.
    ///
    /// `NSHomeDirectory()` ignores `$HOME` for a GUI app, so developing the app against a throwaway
    /// tree — rather than scanning your real home every time you rebuild — needs its own switch. This
    /// is the app-side equivalent of `jaagad --home`, and the launcher passes it through to the
    /// daemon it starts.
    public static let homeOverrideVariable = "JAAGA_HOME"

    public static var current: JaagaPaths {
        JaagaPaths(home: URL(fileURLWithPath: Self.currentHome, isDirectory: true))
    }

    public static var currentHome: String {
        if let override = ProcessInfo.processInfo.environment[homeOverrideVariable], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return NSHomeDirectory()
    }

    /// True when `socketPath` fits in `sockaddr_un`. A pathological home directory can break this,
    /// and a caller needs a clear message rather than a truncated bind.
    public var socketPathFitsAddress: Bool {
        socketPath.utf8.count <= Self.maximumSocketPathBytes
    }
}
