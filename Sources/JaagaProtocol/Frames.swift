import Foundation

/// One message from a client to the daemon.
///
/// On the wire: `{"v":1,"id":"7","method":"listFolder","params":{"path":"/Users/me"}}`
/// `params` may be omitted for methods that take none (`volumes`, `watched`).
public struct RequestFrame: Sendable, Hashable {
    public var version: Int
    /// Client-chosen correlation id. Echoed on the response and on `cancel`.
    public var id: String
    public var request: Request

    public init(version: Int = JaagaProtocolVersion.current, id: String, request: Request) {
        self.version = version
        self.id = id
        self.request = request
    }
}

/// One message from the daemon. Responses, failures and events share the connection, so every
/// frame carries a `type` a client can switch on before decoding anything else.
public enum ServerFrame: Sendable {
    case response(id: String, Response)
    case failure(id: String?, ProtocolFailure)
    case event(Event)

    public var version: Int { JaagaProtocolVersion.current }
}

// MARK: - RequestFrame coding

extension RequestFrame: Codable {
    private enum Key: String, CodingKey {
        case v
        case id
        case method
        case params
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        version = try container.decodeIfPresent(Int.self, forKey: .v) ?? JaagaProtocolVersion.current
        id = try container.decode(String.self, forKey: .id)

        let rawMethod = try container.decode(String.self, forKey: .method)
        guard let method = Request.Method(rawValue: rawMethod) else {
            throw ProtocolFailure(code: .unknownMethod, message: "Unknown method '\(rawMethod)'")
        }

        func params<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try container.decode(type, forKey: .params)
            } catch {
                throw ProtocolFailure(
                    code: .invalidParameters,
                    message: "Method '\(rawMethod)' needs params it did not get: \(error)"
                )
            }
        }

        request = switch method {
        case .hello: .hello(try params(HelloRequest.self))
        case .volumes: .volumes
        case .volumeSummary: .volumeSummary(
            try container.decodeIfPresent(VolumeSummaryRequest.self, forKey: .params) ?? VolumeSummaryRequest()
        )
        case .listFolder: .listFolder(try params(ListFolderRequest.self))
        case .entry: .entry(try params(PathRequest.self))
        case .suspects: .suspects(
            try container.decodeIfPresent(SuspectsRequest.self, forKey: .params) ?? SuspectsRequest()
        )
        case .watch: .watch(try params(PathRequest.self))
        case .unwatch: .unwatch(try params(PathRequest.self))
        case .watched: .watched
        case .quickLook: .quickLook(try params(QuickLookRequest.self))
        case .reveal: .reveal(try params(PathRequest.self))
        case .moveToTrash: .moveToTrash(try params(TrashRequest.self))
        case .cancel: .cancel(try params(CancelRequest.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(version, forKey: .v)
        try container.encode(id, forKey: .id)
        try container.encode(request.method, forKey: .method)

        switch request {
        case .hello(let p): try container.encode(p, forKey: .params)
        case .volumes: break
        case .volumeSummary(let p): try container.encode(p, forKey: .params)
        case .listFolder(let p): try container.encode(p, forKey: .params)
        case .entry(let p): try container.encode(p, forKey: .params)
        case .suspects(let p): try container.encode(p, forKey: .params)
        case .watch(let p): try container.encode(p, forKey: .params)
        case .unwatch(let p): try container.encode(p, forKey: .params)
        case .watched: break
        case .quickLook(let p): try container.encode(p, forKey: .params)
        case .reveal(let p): try container.encode(p, forKey: .params)
        case .moveToTrash(let p): try container.encode(p, forKey: .params)
        case .cancel(let p): try container.encode(p, forKey: .params)
        }
    }
}

// MARK: - ServerFrame coding

extension ServerFrame: Codable {
    private enum Key: String, CodingKey {
        case v
        case type
        case id
        case method
        case result
        case error
        case event
        case payload
    }

    private enum Kind: String, Codable {
        case response
        case error
        case event
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .error:
            self = .failure(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                try container.decode(ProtocolFailure.self, forKey: .error)
            )

        case .response:
            let id = try container.decode(String.self, forKey: .id)
            let rawMethod = try container.decode(String.self, forKey: .method)
            guard let method = Request.Method(rawValue: rawMethod) else {
                throw ProtocolFailure(code: .unknownMethod, message: "Unknown method '\(rawMethod)' in response")
            }
            func result<T: Decodable>(_ type: T.Type) throws -> T {
                try container.decode(type, forKey: .result)
            }
            let response: Response = switch method {
            case .hello: .hello(try result(HelloResponse.self))
            case .volumes: .volumes(try result(VolumesResponse.self))
            case .volumeSummary: .volumeSummary(try result(VolumeSummary.self))
            case .listFolder: .listFolder(try result(FolderListing.self))
            case .entry: .entry(try result(Entry.self))
            case .suspects: .suspects(try result(SuspectReport.self))
            case .watch: .watch(try result(WatchedFolder.self))
            case .unwatch: .unwatch(try result(Acknowledgement.self))
            case .watched: .watched(try result(WatchedResponse.self))
            case .quickLook: .quickLook(try result(QuickLookReport.self))
            case .reveal: .reveal(try result(Acknowledgement.self))
            case .moveToTrash: .moveToTrash(try result(TrashResponse.self))
            case .cancel: .cancel(try result(Acknowledgement.self))
            }
            self = .response(id: id, response)

        case .event:
            let rawName = try container.decode(String.self, forKey: .event)
            guard let name = Event.Name(rawValue: rawName) else {
                throw ProtocolFailure(code: .invalidParameters, message: "Unknown event '\(rawName)'")
            }
            func payload<T: Decodable>(_ type: T.Type) throws -> T {
                try container.decode(type, forKey: .payload)
            }
            let event: Event = switch name {
            case .scanProgress: .scanProgress(try payload(ScanProgressEvent.self))
            case .scanCompleted: .scanCompleted(try payload(ScanCompletedEvent.self))
            case .folderChanged: .folderChanged(try payload(FolderChangedEvent.self))
            case .watchUpdated: .watchUpdated(try payload(WatchUpdatedEvent.self))
            case .watchRemoved: .watchRemoved(try payload(WatchRemovedEvent.self))
            case .watchAlert: .watchAlert(try payload(WatchAlertEvent.self))
            }
            self = .event(event)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(version, forKey: .v)

        switch self {
        case .failure(let id, let failure):
            try container.encode(Kind.error, forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(failure, forKey: .error)

        case .response(let id, let response):
            try container.encode(Kind.response, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(response.method, forKey: .method)
            switch response {
            case .hello(let r): try container.encode(r, forKey: .result)
            case .volumes(let r): try container.encode(r, forKey: .result)
            case .volumeSummary(let r): try container.encode(r, forKey: .result)
            case .listFolder(let r): try container.encode(r, forKey: .result)
            case .entry(let r): try container.encode(r, forKey: .result)
            case .suspects(let r): try container.encode(r, forKey: .result)
            case .watch(let r): try container.encode(r, forKey: .result)
            case .unwatch(let r): try container.encode(r, forKey: .result)
            case .watched(let r): try container.encode(r, forKey: .result)
            case .quickLook(let r): try container.encode(r, forKey: .result)
            case .reveal(let r): try container.encode(r, forKey: .result)
            case .moveToTrash(let r): try container.encode(r, forKey: .result)
            case .cancel(let r): try container.encode(r, forKey: .result)
            }

        case .event(let event):
            try container.encode(Kind.event, forKey: .type)
            try container.encode(event.name, forKey: .event)
            switch event {
            case .scanProgress(let e): try container.encode(e, forKey: .payload)
            case .scanCompleted(let e): try container.encode(e, forKey: .payload)
            case .folderChanged(let e): try container.encode(e, forKey: .payload)
            case .watchUpdated(let e): try container.encode(e, forKey: .payload)
            case .watchRemoved(let e): try container.encode(e, forKey: .payload)
            case .watchAlert(let e): try container.encode(e, forKey: .payload)
            }
        }
    }
}
