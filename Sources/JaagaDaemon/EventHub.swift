import Foundation
import JaagaProtocol

/// Fans events out to every connected client.
///
/// Every client sees every event. There is no subscription filter because the event volume is small
/// (scan progress at a few per second, growth alerts at a few per day) and a filter would be one more
/// thing a future CLI or MCP server has to get right before it works at all.
///
/// A request id is only meaningful to the client that chose it, so an event raised for a request
/// carries its `requestID` only in the copy sent to that client; everyone else gets it without one.
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

    public func publish(_ event: Event, requestedBy owner: UUID? = nil) {
        lock.lock()
        let targets = Array(connections.values)
        // The encoder is not thread-safe, so framing happens under the same lock as the snapshot.
        let ownerFrame = try? Wire.frame(ServerFrame.event(event), encoder: encoder)
        let othersFrame = try? Wire.frame(ServerFrame.event(Self.withoutRequestID(event)), encoder: encoder)
        lock.unlock()

        for connection in targets {
            guard let frame = connection.id == owner ? ownerFrame : othersFrame else { continue }
            connection.send(frame)
        }
    }

    private static func withoutRequestID(_ event: Event) -> Event {
        switch event {
        case .scanProgress(var payload):
            payload.requestID = nil
            return .scanProgress(payload)
        case .scanCompleted(var payload):
            payload.requestID = nil
            return .scanCompleted(payload)
        default:
            return event
        }
    }
}
