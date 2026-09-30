import Foundation

// Swift's synthesised `Decodable` requires every non-optional property to be present, default value
// or not. That would make `{"path":"/Users/me"}` an error because it omits `refresh`, which is
// exactly the kind of papercut that makes a protocol miserable to write a client for.
//
// So each request with optional fields decodes them explicitly, and `docs/protocol.md` can honestly
// say the defaults are defaults. Required fields stay required: omitting `path` is a real mistake and
// should be reported as one.

extension HelloRequest {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            clientName: try container.decode(String.self, forKey: .clientName),
            clientVersion: try container.decodeIfPresent(String.self, forKey: .clientVersion),
            protocolVersion: try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
                ?? JaagaProtocolVersion.current
        )
    }
}

extension ListFolderRequest {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            refresh: try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
        )
    }
}

extension SuspectsRequest {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            root: try container.decodeIfPresent(String.self, forKey: .root),
            refresh: try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
        )
    }
}

extension VolumeSummaryRequest {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mountPath: try container.decodeIfPresent(String.self, forKey: .mountPath),
            refresh: try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? false
        )
    }
}

extension QuickLookRequest {
    public static let defaultLimit = 24

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit
        )
    }
}

extension TrashRequest {
    /// `confirmed` defaults to `false` rather than being required, so a client that forgets it gets
    /// the pointed `confirmationRequired` refusal instead of a decoding error about a missing key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            confirmed: try container.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        )
    }
}
