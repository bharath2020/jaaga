import Foundation
import JaagaProtocol

/// One client connected over the socket.
///
/// Reads happen on the connection's own thread. Writes may come from anywhere (a response from a
/// request handler, an event from a scan thread) and never block their caller: they are queued and
/// written in order on the connection's own writer queue, so one client that stops reading can only
/// ever stall itself, never a scan or the other clients.
public final class SocketConnection: @unchecked Sendable, Identifiable, Hashable {
    public let id = UUID()

    /// Queued output a client may leave unread before it is dropped as stuck.
    static let maximumQueuedBytes = 64 * 1024 * 1024
    /// How long one write may wait on a full socket buffer before the client is dropped as stuck.
    static let writeTimeoutSeconds = 30

    private let descriptor: Int32
    private let writeLock = NSLock()
    private let writer = DispatchQueue(label: "com.jaaga.connection.writer")
    private var closed = false
    private var queuedBytes = 0

    /// Set before the read loop starts.
    var onFrame: (@Sendable (SocketConnection, Data) -> Void)?
    var onClose: (@Sendable (SocketConnection) -> Void)?

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: Self.writeTimeoutSeconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Queues one already-framed message and returns at once. A failed or timed-out write, or a
    /// backlog past `maximumQueuedBytes`, closes the connection: a client that has gone away or
    /// stopped reading should not keep the daemon holding its output.
    public func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        guard queuedBytes + data.count <= Self.maximumQueuedBytes else {
            closeLocked()
            return
        }
        queuedBytes += data.count
        writer.async { [self] in
            let complete = write(data)
            writeLock.lock()
            defer { writeLock.unlock() }
            queuedBytes -= data.count
            if !complete { closeLocked() }
        }
    }

    /// Writes all of `data` on the writer queue, or reports that the peer is gone or stuck.
    private func write(_ data: Data) -> Bool {
        writeLock.lock()
        let isClosed = closed
        writeLock.unlock()
        guard !isClosed else { return false }

        var sent = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: sent), raw.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                break
            }
        }
        return sent == data.count
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        // Wake the read loop, which then reports the close.
        shutdown(descriptor, SHUT_RDWR)
    }

    /// Runs the blocking read loop on the calling thread until the peer disconnects.
    func readUntilClosed() {
        var framer = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        loop: while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                do {
                    for frame in try framer.push(Data(buffer[0..<count])) {
                        onFrame?(self, frame)
                    }
                } catch {
                    // An oversized frame means the client is not speaking this protocol. Say so and
                    // hang up rather than buffering forever.
                    send(Self.framedFramingFailure(error))
                    break loop
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            break
        }

        // Closed behind whatever is already queued — the framing failure above included — so the
        // descriptor number is never reused under a write still in flight.
        writer.async { [self] in
            writeLock.lock()
            closed = true
            writeLock.unlock()
            Darwin.close(descriptor)
        }
        onClose?(self)
    }

    private static func framedFramingFailure(_ error: any Error) -> Data {
        let failure = ProtocolFailure(
            code: .malformedFrame,
            message: "Frame exceeded the maximum size: \(error)"
        )
        return (try? Wire.frame(ServerFrame.failure(id: nil, failure))) ?? Data()
    }

    public static func == (lhs: SocketConnection, rhs: SocketConnection) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A Unix domain socket server.
///
/// Thread-per-connection with blocking reads. The daemon serves a handful of local clients — an app
/// window, maybe a CLI — so a thread each is simpler and more predictable than an event loop, and it
/// keeps the blocking reads off Swift's cooperative thread pool where they would starve tasks.
public final class UnixSocketServer: @unchecked Sendable {
    public enum StartError: Error, Sendable, CustomStringConvertible {
        case pathTooLong(path: String, limit: Int)
        case alreadyRunning(path: String)
        case systemCallFailed(String, errnoCode: Int32)

        public var description: String {
            switch self {
            case .pathTooLong(let path, let limit):
                "Socket path is \(path.utf8.count) bytes, over the \(limit)-byte limit for a Unix "
                    + "domain socket address: \(path)"
            case .alreadyRunning(let path):
                "Another Jaaga daemon is already listening on \(path)"
            case .systemCallFailed(let call, let code):
                "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    public let socketPath: String

    private let onConnection: @Sendable (SocketConnection) -> Void
    private let stateLock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var running = false

    public init(socketPath: String, onConnection: @escaping @Sendable (SocketConnection) -> Void) {
        self.socketPath = socketPath
        self.onConnection = onConnection
    }

    public func start() throws {
        guard socketPath.utf8.count <= JaagaPaths.maximumSocketPathBytes else {
            throw StartError.pathTooLong(path: socketPath, limit: JaagaPaths.maximumSocketPathBytes)
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            // The socket carries a user's whole filesystem layout, so the directory is theirs alone.
            attributes: [.posixPermissions: 0o700]
        )

        // A socket file left behind by a crashed daemon would block bind. Probe it first: if someone
        // answers, they own this path and we must not remove it.
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.isSocketAlive(at: socketPath) {
                throw StartError.alreadyRunning(path: socketPath)
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw StartError.systemCallFailed("socket", errnoCode: errno)
        }

        var address = Self.makeAddress(socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw StartError.systemCallFailed("bind", errnoCode: code)
        }

        // Only this user may connect. The protocol exposes the user's entire directory tree and can
        // move files to the Trash, so the file permissions are the access control.
        chmod(socketPath, 0o600)

        guard listen(descriptor, 32) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw StartError.systemCallFailed("listen", errnoCode: code)
        }

        stateLock.lock()
        listenDescriptor = descriptor
        running = true
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "com.jaaga.accept"
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        let descriptor = listenDescriptor
        running = false
        listenDescriptor = -1
        stateLock.unlock()

        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop(_ listenDescriptor: Int32) {
        while isRunning {
            let descriptor = accept(listenDescriptor, nil, nil)
            guard descriptor >= 0 else {
                // A failed accept is about that one connection, or a momentary shortage of
                // descriptors; only `stop` ends the loop, or the daemon would stay up but unreachable.
                let code = errno
                if code == ECONNABORTED || code == EINTR { continue }
                if isRunning { Thread.sleep(forTimeInterval: 0.1) }
                continue
            }
            guard isRunning else {
                Darwin.close(descriptor)
                break
            }

            let connection = SocketConnection(descriptor: descriptor)
            onConnection(connection)

            let thread = Thread { connection.readUntilClosed() }
            thread.name = "com.jaaga.connection"
            thread.start()
        }
    }

    // MARK: - Address helpers

    static func makeAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: address.sun_path), "socket path too long")
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// True when something is listening on `path` right now.
    static func isSocketAlive(at path: String) -> Bool {
        guard path.utf8.count <= JaagaPaths.maximumSocketPathBytes else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = makeAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
