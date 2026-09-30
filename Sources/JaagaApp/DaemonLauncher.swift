import Foundation
import JaagaProtocol
import ServiceManagement

/// Gets the daemon running and hands back a connected client.
///
/// The supported path is `SMAppService`: the app registers the LaunchAgent it carries in
/// `Contents/Library/LaunchAgents`, and launchd keeps it alive across logins from then on.
///
/// That needs a signed bundle, which a plain `swift build` does not produce, so there is a documented
/// development fallback: launch the bundled `jaagad` binary as a child process. The fallback is
/// announced in the interface rather than hidden, because a daemon that dies with the app behaves
/// differently from one launchd owns, and that difference should not be a surprise.
@MainActor
final class DaemonLauncher {
    enum Mode: Equatable {
        /// launchd owns the daemon; it survives the app quitting and starts again at login.
        case launchAgent
        /// The app owns the daemon; it stops when the app does.
        case childProcess

        var summary: String {
            switch self {
            case .launchAgent: "Background daemon registered with launchd"
            case .childProcess: "Daemon running as a child of this app (development build)"
            }
        }
    }

    enum LaunchError: Error, CustomStringConvertible {
        case daemonBinaryMissing(searched: [String])
        case didNotStart(socketPath: String, seconds: Double, detail: String?)

        var description: String {
            switch self {
            case .daemonBinaryMissing(let searched):
                return "Could not find the jaagad binary. Looked in:\n"
                    + searched.map { "  \($0)" }.joined(separator: "\n")
            case .didNotStart(let socketPath, let seconds, let detail):
                let opening = "The Jaaga daemon did not start listening on \(socketPath) "
                    + "within \(Int(seconds)) seconds."
                return [opening, detail].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    static let launchAgentIdentifier = "com.jaaga.daemon"
    static let launchAgentPlistName = "com.jaaga.daemon.plist"

    private(set) var mode: Mode?
    /// Kept so the child process can be stopped when the app quits.
    private var childProcess: Process?
    private let paths = JaagaPaths.current

    /// Starts the daemon if it is not already listening, then connects.
    func start() async throws -> (client: DaemonClient, hello: HelloResponse, mode: Mode) {
        // Already running — from a previous launch, from launchd, or from a terminal.
        if let connected = try? await connect() {
            mode = registeredLaunchAgentIsEnabled ? .launchAgent : .childProcess
            return (connected.client, connected.hello, mode!)
        }

        var launchAgentFailure: String?
        if let service = launchAgentService {
            do {
                if service.status != .enabled {
                    try service.register()
                }
                let connected = try await waitForDaemon(seconds: 10)
                mode = .launchAgent
                return (connected.client, connected.hello, .launchAgent)
            } catch {
                // Unsigned development builds are refused by SMAppService; fall through rather than
                // leaving the app with nothing to talk to.
                launchAgentFailure = "Registering the LaunchAgent failed: \(error.localizedDescription)"
            }
        } else {
            launchAgentFailure = "This build is not an app bundle with a LaunchAgent, "
                + "so the daemon is started directly."
        }

        try startChildProcess()
        let connected = try await waitForDaemon(seconds: 15, detail: launchAgentFailure)
        mode = .childProcess
        return (connected.client, connected.hello, .childProcess)
    }

    /// Stops a daemon this app started itself. A launchd-owned daemon is left alone: it is meant to
    /// outlive the app, and tearing it down here would defeat watching folders in the background.
    func stopChildProcessIfAny() {
        childProcess?.terminate()
        childProcess = nil
    }

    /// Unregisters the LaunchAgent, for a "stop watching in the background" affordance.
    func unregisterLaunchAgent() throws {
        guard let service = launchAgentService, service.status == .enabled else { return }
        try service.unregister()
    }

    var launchAgentStatusDescription: String {
        guard let service = launchAgentService else { return "Not an app bundle" }
        return switch service.status {
        case .notRegistered: "Not registered"
        case .enabled: "Enabled"
        case .requiresApproval: "Waiting for approval in System Settings › General › Login Items"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    // MARK: - Details

    private var launchAgentService: SMAppService? {
        guard bundledLaunchAgentPlistURL != nil else { return nil }
        return SMAppService.agent(plistName: Self.launchAgentPlistName)
    }

    private var registeredLaunchAgentIsEnabled: Bool {
        launchAgentService?.status == .enabled
    }

    private var bundledLaunchAgentPlistURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(Self.launchAgentPlistName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func connect() async throws -> (client: DaemonClient, hello: HelloResponse) {
        let client = DaemonClient(socketPath: paths.socketPath)
        let hello = try await client.connect(
            clientName: "Jaaga.app",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        return (client, hello)
    }

    private func waitForDaemon(
        seconds: Double,
        detail: String? = nil
    ) async throws -> (client: DaemonClient, hello: HelloResponse) {
        let deadline = Date().addingTimeInterval(seconds)
        var lastError: (any Error)?
        while Date() < deadline {
            do {
                return try await connect()
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        var explanation = detail
        if let lastError {
            explanation = [detail, String(describing: lastError)].compactMap { $0 }.joined(separator: "\n")
        }
        throw LaunchError.didNotStart(socketPath: paths.socketPath, seconds: seconds, detail: explanation)
    }

    private func startChildProcess() throws {
        let candidates = daemonBinaryCandidates()
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LaunchError.daemonBinaryMissing(searched: candidates)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = []
        // The daemon's log goes where the app's does, which for a development build is the terminal.
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        childProcess = process
    }

    /// Where `jaagad` might be: beside the app executable inside a bundle, or beside it in a
    /// `swift build` products directory.
    private func daemonBinaryCandidates() -> [String] {
        var candidates: [String] = []
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        candidates.append(executableDirectory.appendingPathComponent("jaagad").path)
        candidates.append(
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jaagad").path
        )
        if let resource = Bundle.main.url(forAuxiliaryExecutable: "jaagad") {
            candidates.append(resource.path)
        }
        return candidates.reduced()
    }
}

extension Array where Element: Hashable {
    /// Removes duplicates while keeping the first occurrence's position.
    func reduced() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
