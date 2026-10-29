import Foundation

/// A client for the daemon socket.
///
/// Lives in `JaagaProtocol` rather than in the app so that the app, the tests, and a future CLI or
/// MCP server all exercise the same client and the same framing. It is the reference implementation
/// of what `docs/protocol.md` describes.
///
/// One connection carries interleaved responses and events: `send` waits for the response with a
/// matching id, while events go to `events` as they arrive.
public actor DaemonClient {
    public enum ClientError: Error, Sendable, CustomStringConvertible {
        case notConnected
        case connectionFailed(path: String, errnoCode: Int32)
        case socketPathTooLong(path: String)
        case disconnected
        case timedOut(method: String)
        case unexpectedResponse(expected: Request.Method, got: Request.Method)

        public var description: String {
            switch self {
            case .notConnected:
                "Not connected to the Jaaga daemon"
            case .connectionFailed(let path, let code):
                "Could not connect to the Jaaga daemon at \(path): "
                    + "\(String(cString: strerror(code))) (errno \(code))"
            case .socketPathTooLong(let path):
                "Socket path is too long for a Unix domain socket address: \(path)"
            case .disconnected:
                "The Jaaga daemon closed the connection"
            case .timedOut(let method):
                "The Jaaga daemon did not answer '\(method)' in time"
            case .unexpectedResponse(let expected, let got):
                "Asked for '\(expected.rawValue)' but the daemon answered '\(got.rawValue)'"
            }
        }
    }

    public let socketPath: String
    /// How long to wait for a response. Generous, because a first scan of a large home folder can
    /// legitimately take minutes; progress events tell the client it is still alive meanwhile.
    public let timeout: Duration

    private var transport: Transport?
    private var nextRequestNumber = 0
    private var pending: [String: CheckedContinuation<Response, any Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    public init(socketPath: String, timeout: Duration = .seconds(600)) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public var isConnected: Bool { transport != nil }

    /// Connects and performs the version handshake, which is the point at which a mismatch surfaces.
    @discardableResult
    public func connect(clientName: String, clientVersion: String? = nil) async throws -> HelloResponse {
        if transport == nil {
            guard socketPath.utf8.count <= JaagaPaths.maximumSocketPathBytes else {
                throw ClientError.socketPathTooLong(path: socketPath)
            }
            let transport = try Transport(socketPath: socketPath)
            self.transport = transport
            transport.start(
                onFrame: { [weak self] data in
                    guard let self else { return }
                    Task { await self.received(data) }
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    Task { await self.connectionClosed() }
                }
            )
        }

        let response = try await send(
            .hello(HelloRequest(clientName: clientName, clientVersion: clientVersion))
        )
        guard case .hello(let hello) = response else {
            throw ClientError.unexpectedResponse(expected: .hello, got: response.method)
        }
        return hello
    }

    public func disconnect() {
        transport?.close()
        transport = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: ClientError.disconnected)
        }
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    /// Events pushed by the daemon. Each caller gets its own stream; all of them see every event.
    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeEventStream(id) }
            }
        }
    }

    private func removeEventStream(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    /// Sends a request and waits for its answer.
    ///
    /// Cancelling the calling task, or running out of `timeout`, sends `cancel` to the daemon, so an
    /// abandoned scan actually stops rather than running on in the background.
    public func send(_ request: Request) async throws -> Response {
        guard let transport else { throw ClientError.notConnected }

        nextRequestNumber += 1
        let id = String(nextRequestNumber)
        let frame = try Wire.frame(RequestFrame(id: id, request: request))

        let timer = Task { [timeout, weak self] in
            try await Task.sleep(for: timeout)
            await self?.abandon(id: id, because: ClientError.timedOut(method: request.method.rawValue))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await awaitResponse(id: id) {
                transport.send(frame)
            }
        } onCancel: {
            Task { await self.abandon(id: id, because: CancellationError()) }
        }
    }

    private func awaitResponse(
        id: String,
        afterRegistering send: @Sendable () -> Void
    ) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            // Register before writing: a fast daemon can answer before `send` returns.
            pending[id] = continuation
            send()
        }
    }

    /// Fails the wait for `id` with `error` and tells the daemon to stop working on a request nobody
    /// is waiting for any more.
    private func abandon(id: String, because error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
        guard let transport else { return }
        nextRequestNumber += 1
        let frame = try? Wire.frame(
            RequestFrame(id: String(nextRequestNumber), request: .cancel(CancelRequest(requestID: id)))
        )
        if let frame { transport.send(frame) }
    }

    private func received(_ data: Data) {
        guard let frame = try? Wire.decode(ServerFrame.self, from: data) else { return }
        switch frame {
        case .response(let id, let response):
            pending.removeValue(forKey: id)?.resume(returning: response)
        case .failure(let id, let failure):
            if let id, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: failure)
            }
        case .event(let event):
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }

    private func connectionClosed() {
        transport = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: ClientError.disconnected)
        }
    }
}

// MARK: - Typed convenience

extension DaemonClient {
    private func expect<T>(_ request: Request, _ extract: (Response) -> T?) async throws -> T {
        let response = try await send(request)
        guard let value = extract(response) else {
            throw ClientError.unexpectedResponse(expected: request.method, got: response.method)
        }
        return value
    }

    public func volumes() async throws -> VolumesResponse {
        try await expect(.volumes) { if case .volumes(let r) = $0 { r } else { nil } }
    }

    public func volumeSummary(mountPath: String? = nil, refresh: Bool = false) async throws -> VolumeSummary {
        try await expect(.volumeSummary(VolumeSummaryRequest(mountPath: mountPath, refresh: refresh))) {
            if case .volumeSummary(let r) = $0 { r } else { nil }
        }
    }

    public func listFolder(path: String, refresh: Bool = false) async throws -> FolderListing {
        try await expect(.listFolder(ListFolderRequest(path: path, refresh: refresh))) {
            if case .listFolder(let r) = $0 { r } else { nil }
        }
    }

    public func entry(path: String) async throws -> Entry {
        try await expect(.entry(PathRequest(path: path))) { if case .entry(let r) = $0 { r } else { nil } }
    }

    public func suspects(root: String? = nil, refresh: Bool = false) async throws -> SuspectReport {
        try await expect(.suspects(SuspectsRequest(root: root, refresh: refresh))) {
            if case .suspects(let r) = $0 { r } else { nil }
        }
    }

    public func watch(path: String) async throws -> WatchedFolder {
        try await expect(.watch(PathRequest(path: path))) { if case .watch(let r) = $0 { r } else { nil } }
    }

    public func unwatch(path: String) async throws -> Bool {
        try await expect(.unwatch(PathRequest(path: path))) {
            if case .unwatch(let r) = $0 { r.ok } else { nil }
        }
    }

    public func watched() async throws -> [WatchedFolder] {
        try await expect(.watched) { if case .watched(let r) = $0 { r.folders } else { nil } }
    }

    public func quickLook(path: String, limit: Int = QuickLookRequest.defaultLimit) async throws -> QuickLookReport {
        try await expect(.quickLook(QuickLookRequest(path: path, limit: limit))) {
            if case .quickLook(let r) = $0 { r } else { nil }
        }
    }

    public func reveal(path: String) async throws {
        _ = try await expect(.reveal(PathRequest(path: path))) {
            if case .reveal(let r) = $0 { r } else { nil }
        }
    }

    /// Moves a path to the Trash. `confirmed` must be true, and it is the caller's job to have asked
    /// a human first — the daemon refuses anything else.
    public func moveToTrash(path: String, confirmed: Bool) async throws -> TrashResponse {
        try await expect(.moveToTrash(TrashRequest(path: path, confirmed: confirmed))) {
            if case .moveToTrash(let r) = $0 { r } else { nil }
        }
    }
}

// MARK: - Socket transport

/// The blocking socket read loop, on its own thread so it never occupies Swift's cooperative pool.
private final class Transport: @unchecked Sendable {
    private let descriptor: Int32
    private let writeLock = NSLock()
    private var closed = false

    init(socketPath: String) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DaemonClient.ClientError.connectionFailed(path: socketPath, errnoCode: errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw DaemonClient.ClientError.connectionFailed(path: socketPath, errnoCode: code)
        }

        // A daemon that has gone away must fail a write, not kill the app with SIGPIPE.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        self.descriptor = descriptor
    }

    func start(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let thread = Thread { [self, descriptor] in
            // Responses are bounded by the filesystem, not by a request, so a folder with tens of
            // thousands of children must not trip the limit meant for requests to the daemon.
            var framer = LineFramer(maximumFrameBytes: .max)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard let frames = try? framer.push(Data(buffer[0..<count])) else { break }
                    for frame in frames { onFrame(frame) }
                    continue
                }
                if count == 0 { break }
                if errno == EINTR { continue }
                break
            }
            closeDescriptor()
            onClose()
        }
        thread.name = "com.jaaga.client"
        thread.start()
    }

    func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let written = write(descriptor, base.advanced(by: sent), raw.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                break
            }
        }
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(descriptor, SHUT_RDWR)
    }

    /// Marks the transport closed under the write lock before releasing the descriptor, so a send
    /// racing the reader's exit can never write to a descriptor number the process has reused.
    private func closeDescriptor() {
        writeLock.lock()
        defer { writeLock.unlock() }
        closed = true
        Darwin.close(descriptor)
    }
}
