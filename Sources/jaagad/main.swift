import Foundation
import JaagaDaemon
import JaagaProtocol

// The Jaaga daemon. Normally started as a per-user LaunchAgent that the app registers with
// SMAppService; it can also be run straight from a terminal during development, which is what the
// README's fallback describes.
//
// Everything interesting lives in JaagaDaemon; this is only the process wrapper: parse a couple of
// flags, bring the server up, and keep a run loop alive so AppKit's Finder reveal and the FSEvents
// stream have somewhere to run.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("jaagad: " + message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var overriddenHome: String?
var watchesFileSystem = true

while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--version":
        print("jaagad \(JaagaDaemonVersion.current) (protocol \(JaagaProtocolVersion.current))")
        exit(0)
    case "--print-socket-path":
        print(JaagaPaths.current.socketPath)
        exit(0)
    case "--home":
        guard let value = arguments.first else { fail("--home needs a path") }
        arguments.removeFirst()
        overriddenHome = value
    case "--no-fsevents":
        watchesFileSystem = false
    case "--help", "-h":
        print("""
        jaagad — the Jaaga scanning daemon

        Usage: jaagad [options]

          --home <path>          Treat <path> as the user's home folder (state and socket go under it)
          --no-fsevents          Do not watch the filesystem; only re-measure on the timer
          --print-socket-path    Print where clients should connect, then exit
          --version              Print the daemon and protocol versions, then exit

        The protocol is documented in docs/protocol.md.
        """)
        exit(0)
    default:
        fail("unknown option '\(argument)'. Try --help.")
    }
}

// --home wins, then JAAGA_HOME, then the real home.
let home = overriddenHome.map { ($0 as NSString).expandingTildeInPath } ?? JaagaPaths.currentHome
let configuration = DaemonConfiguration(
    paths: JaagaPaths(home: URL(fileURLWithPath: home, isDirectory: true)),
    home: home,
    watchesFileSystem: watchesFileSystem
)

guard configuration.paths.socketPathFitsAddress else {
    fail(
        "the socket path is too long for a Unix domain socket address "
            + "(\(configuration.paths.socketPath.utf8.count) bytes, limit \(JaagaPaths.maximumSocketPathBytes)): "
            + configuration.paths.socketPath
    )
}

let daemon: JaagaDaemon
do {
    daemon = try JaagaDaemon(configuration: configuration)
} catch {
    fail("could not start: \(error)")
}

// SIGPIPE would kill the process when a client disconnects mid-write; the socket code checks the
// write result instead.
signal(SIGPIPE, SIG_IGN)

let shutdown = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
shutdown.setEventHandler {
    Task {
        await daemon.stop()
        exit(0)
    }
}
shutdown.resume()
signal(SIGTERM, SIG_IGN)

Task {
    do {
        try await daemon.start()
        FileHandle.standardError.write(
            Data("jaagad \(JaagaDaemonVersion.current) listening on \(daemon.socketPath)\n".utf8)
        )
    } catch {
        fail("could not listen on \(configuration.paths.socketPath): \(error)")
    }
}

// AppKit's reveal-in-Finder and the FSEvents dispatch source both need a live run loop.
RunLoop.main.run()
