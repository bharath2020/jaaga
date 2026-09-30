import Foundation

/// The wire protocol version. Bump only for a breaking change; additive fields do not need one.
public enum JaagaProtocolVersion {
    public static let current = 1
    /// Every version this build can still speak.
    public static let supported: [Int] = [1]
}

// MARK: - Request parameters

public struct HelloRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case clientName
        case clientVersion
        case protocolVersion
    }

    /// Free-form, for the daemon log: `"Jaaga.app"`, `"jaaga-cli"`, `"jaaga-mcp"`.
    public var clientName: String
    public var clientVersion: String?
    /// The version the client intends to speak. The daemon rejects anything it cannot honour.
    public var protocolVersion: Int

    public init(clientName: String, clientVersion: String? = nil, protocolVersion: Int = JaagaProtocolVersion.current) {
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
    }
}

public struct PathRequest: Codable, Sendable, Hashable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

public struct ListFolderRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case path
        case refresh
    }

    public var path: String
    /// Discard anything cached for this folder and measure it again.
    public var refresh: Bool

    public init(path: String, refresh: Bool = false) {
        self.path = path
        self.refresh = refresh
    }
}

public struct SuspectsRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case root
        case refresh
    }

    /// Where to look. Defaults to the user's home folder.
    public var root: String?
    public var refresh: Bool

    public init(root: String? = nil, refresh: Bool = false) {
        self.root = root
        self.refresh = refresh
    }
}

public struct VolumeSummaryRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case mountPath
        case refresh
    }

    /// Mount point, e.g. `/`. Defaults to the startup disk.
    public var mountPath: String?
    public var refresh: Bool

    public init(mountPath: String? = nil, refresh: Bool = false) {
        self.mountPath = mountPath
        self.refresh = refresh
    }
}

public struct QuickLookRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case path
        case limit
    }

    public var path: String
    /// How many items to return, largest first.
    public var limit: Int

    public init(path: String, limit: Int = QuickLookRequest.defaultLimit) {
        self.path = path
        self.limit = limit
    }
}

public struct CancelRequest: Codable, Sendable, Hashable {
    /// The `id` of the in-flight request to abandon.
    public var requestID: String

    public init(requestID: String) {
        self.requestID = requestID
    }
}

/// Moving to the Trash is the only destructive action in the protocol, so it will not proceed
/// unless the caller states that a human confirmed it. Nothing is ever deleted permanently.
public struct TrashRequest: Codable, Sendable, Hashable {
    public enum CodingKeys: String, CodingKey {
        case path
        case confirmed
    }

    public var path: String
    public var confirmed: Bool

    public init(path: String, confirmed: Bool) {
        self.path = path
        self.confirmed = confirmed
    }
}

// MARK: - Request

public enum Request: Sendable, Hashable {
    case hello(HelloRequest)
    case volumes
    case volumeSummary(VolumeSummaryRequest)
    case listFolder(ListFolderRequest)
    case entry(PathRequest)
    case suspects(SuspectsRequest)
    case watch(PathRequest)
    case unwatch(PathRequest)
    case watched
    case quickLook(QuickLookRequest)
    case reveal(PathRequest)
    case moveToTrash(TrashRequest)
    case cancel(CancelRequest)

    /// The `method` string this case travels as.
    public var method: Method {
        switch self {
        case .hello: .hello
        case .volumes: .volumes
        case .volumeSummary: .volumeSummary
        case .listFolder: .listFolder
        case .entry: .entry
        case .suspects: .suspects
        case .watch: .watch
        case .unwatch: .unwatch
        case .watched: .watched
        case .quickLook: .quickLook
        case .reveal: .reveal
        case .moveToTrash: .moveToTrash
        case .cancel: .cancel
        }
    }

    public enum Method: String, Codable, Sendable, CaseIterable {
        case hello
        case volumes
        case volumeSummary
        case listFolder
        case entry
        case suspects
        case watch
        case unwatch
        case watched
        case quickLook
        case reveal
        case moveToTrash
        case cancel
    }
}

// MARK: - Response payloads

public struct HelloResponse: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var supportedProtocolVersions: [Int]
    public var daemonVersion: String
    public var homePath: String
    public var socketPath: String

    public init(
        protocolVersion: Int,
        supportedProtocolVersions: [Int],
        daemonVersion: String,
        homePath: String,
        socketPath: String
    ) {
        self.protocolVersion = protocolVersion
        self.supportedProtocolVersions = supportedProtocolVersions
        self.daemonVersion = daemonVersion
        self.homePath = homePath
        self.socketPath = socketPath
    }
}

public struct VolumesResponse: Codable, Sendable {
    public var volumes: [VolumeInfo]
    public var homePath: String

    public init(volumes: [VolumeInfo], homePath: String) {
        self.volumes = volumes
        self.homePath = homePath
    }
}

public struct WatchedResponse: Codable, Sendable {
    public var folders: [WatchedFolder]

    public init(folders: [WatchedFolder]) {
        self.folders = folders
    }
}

public struct TrashResponse: Codable, Sendable {
    public var originalPath: String
    /// Where the item landed in the Trash, when the system reported it.
    public var trashedPath: String?
    public var reclaimedBytes: Int64

    public init(originalPath: String, trashedPath: String?, reclaimedBytes: Int64) {
        self.originalPath = originalPath
        self.trashedPath = trashedPath
        self.reclaimedBytes = reclaimedBytes
    }
}

public struct Acknowledgement: Codable, Sendable, Hashable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

// MARK: - Response

public enum Response: Sendable {
    case hello(HelloResponse)
    case volumes(VolumesResponse)
    case volumeSummary(VolumeSummary)
    case listFolder(FolderListing)
    case entry(Entry)
    case suspects(SuspectReport)
    case watch(WatchedFolder)
    case unwatch(Acknowledgement)
    case watched(WatchedResponse)
    case quickLook(QuickLookReport)
    case reveal(Acknowledgement)
    case moveToTrash(TrashResponse)
    case cancel(Acknowledgement)

    /// The method this response answers. Echoed on the wire so a dynamically typed client can
    /// decode `result` without keeping its own request bookkeeping.
    public var method: Request.Method {
        switch self {
        case .hello: .hello
        case .volumes: .volumes
        case .volumeSummary: .volumeSummary
        case .listFolder: .listFolder
        case .entry: .entry
        case .suspects: .suspects
        case .watch: .watch
        case .unwatch: .unwatch
        case .watched: .watched
        case .quickLook: .quickLook
        case .reveal: .reveal
        case .moveToTrash: .moveToTrash
        case .cancel: .cancel
        }
    }
}

// MARK: - Errors

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    /// The client asked for a protocol version this daemon does not speak.
    case unsupportedProtocolVersion
    case malformedFrame
    case unknownMethod
    case invalidParameters
    case notFound
    case notADirectory
    /// The path exists but could not be read. Usually a missing Full Disk Access grant.
    case notReadable
    case notPermitted
    case cancelled
    /// A destructive request arrived without `confirmed: true`.
    case confirmationRequired
    case internalError
}

public struct ProtocolFailure: Codable, Sendable, Hashable, Error {
    public var code: ErrorCode
    public var message: String
    public var path: String?
    public var errnoCode: Int32?

    public init(code: ErrorCode, message: String, path: String? = nil, errnoCode: Int32? = nil) {
        self.code = code
        self.message = message
        self.path = path
        self.errnoCode = errnoCode
    }
}
