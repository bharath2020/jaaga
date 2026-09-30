import Foundation
import JaagaCore
import JaagaProtocol

/// The daemon: a socket server in front of `DaemonService`.
///
/// Nothing above this type knows about sockets, and nothing below it knows about clients, so the same
/// service answers the app today and a CLI or MCP server tomorrow with no change here.
public final class JaagaDaemon: @unchecked Sendable {
    public let configuration: DaemonConfiguration
    private let eventHub = EventHub()
    private let service: DaemonService
    private let server: UnixSocketServer

    public init(configuration: DaemonConfiguration) throws {
        self.configuration = configuration
        let hub = eventHub
        let service = try DaemonService(configuration: configuration, eventHub: hub)
        self.service = service

        // Captured before `self` exists, so the server's callbacks never need a weak dance.
        self.server = UnixSocketServer(socketPath: configuration.paths.socketPath) { connection in
            hub.add(connection)
            connection.onFrame = { connection, frame in
                Task { await service.accept(frame: frame, from: connection) }
            }
            connection.onClose = { connection in
                hub.remove(connection)
            }
        }
    }

    public var socketPath: String { configuration.paths.socketPath }

    public func start() async throws {
        try server.start()
        await service.start()
    }

    public func stop() async {
        server.stop()
        await service.stop()
    }

    /// For tests and for a future in-process client: answer a request without going through a socket.
    public func respond(to request: Request) async throws -> Response {
        try await service.respond(to: request)
    }

    /// Re-measures the watched folders now rather than waiting for the timer.
    public func sampleWatchedFoldersNow() async {
        await service.sampleWatchedFolders()
    }
}
