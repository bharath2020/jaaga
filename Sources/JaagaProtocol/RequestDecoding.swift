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

extension Entry {
    private enum EntryKey: String, CodingKey {
        case path, name, isDirectory, isSymbolicLink, allocatedBytes, itemCount, directChildCount
        case category, verdict, reason, kind, lastOpened, contentModified, created, isWatched
        case unreadableDescendantCount
    }

    /// `unreadableDescendantCount` was added after version 1 shipped, so it decodes as optional and
    /// defaults to "nothing was missed" — an older daemon simply had no way to say otherwise.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: EntryKey.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            name: try container.decode(String.self, forKey: .name),
            isDirectory: try container.decode(Bool.self, forKey: .isDirectory),
            isSymbolicLink: try container.decodeIfPresent(Bool.self, forKey: .isSymbolicLink) ?? false,
            allocatedBytes: try container.decode(Int64.self, forKey: .allocatedBytes),
            itemCount: try container.decode(Int.self, forKey: .itemCount),
            directChildCount: try container.decodeIfPresent(Int.self, forKey: .directChildCount),
            category: try container.decode(UsageCategory.self, forKey: .category),
            verdict: try container.decode(Verdict.self, forKey: .verdict),
            reason: try container.decode(String.self, forKey: .reason),
            kind: try container.decode(String.self, forKey: .kind),
            lastOpened: try container.decodeIfPresent(Date.self, forKey: .lastOpened),
            contentModified: try container.decodeIfPresent(Date.self, forKey: .contentModified),
            created: try container.decodeIfPresent(Date.self, forKey: .created),
            isWatched: try container.decodeIfPresent(Bool.self, forKey: .isWatched) ?? false,
            unreadableDescendantCount: try container.decodeIfPresent(
                Int.self,
                forKey: .unreadableDescendantCount
            ) ?? 0
        )
    }
}
