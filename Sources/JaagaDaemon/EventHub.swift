import Foundation
import JaagaProtocol

/// Fans events out to every connected client.
///
/// Every client sees every event. There is no subscription filter because the event volume is small
/// (scan progress at a few per second, growth alerts at a few per day) and a filter would be one more
/// thing a future CLI or MCP server has to get right before it works at all.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: SocketConnection] = [:]
    private let encoder = Wire.makeEncoder()

    public init() {}

    public func add(_ connection: SocketConnection) {
        lock.lock()
        connections[connection.id] = connection
        lock.unlock()
    }

    public func remove(_ connection: SocketConnection) {
        lock.lock()
        connections.removeValue(forKey: connection.id)
        lock.unlock()
    }

    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    public func publish(_ event: Event) {
        lock.lock()
        let targets = Array(connections.values)
        // The encoder is not thread-safe, so framing happens under the same lock as the snapshot.
        let frame = try? Wire.frame(ServerFrame.event(event), encoder: encoder)
        lock.unlock()

        guard let frame else { return }
        for connection in targets {
            connection.send(frame)
        }
    }
}
