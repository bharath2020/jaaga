import Foundation
import Testing

@testable import JaagaProtocol

@Suite("Request frames")
struct RequestFrameTests {
    private let decoder = Wire.makeDecoder()
    private let encoder = Wire.makeEncoder()

    private func roundTrip(_ frame: RequestFrame) throws -> RequestFrame {
        try decoder.decode(RequestFrame.self, from: encoder.encode(frame))
    }

    @Test("Every method survives a round trip", arguments: Request.Method.allCases)
    func everyMethodRoundTrips(method: Request.Method) throws {
        let request = Request.sample(for: method)
        let decoded = try roundTrip(RequestFrame(id: "abc", request: request))

        #expect(decoded.id == "abc")
        #expect(decoded.version == JaagaProtocolVersion.current)
        #expect(decoded.request == request)
        #expect(decoded.request.method == method)
    }

    @Test("A request is one line of JSON with the method spelled out")
    func wireShapeIsReadable() throws {
        let frame = RequestFrame(
            id: "7",
            request: .listFolder(ListFolderRequest(path: "/Users/me/Library", refresh: true))
        )

        let line = try Wire.frame(frame)
        let text = try #require(String(data: line, encoding: .utf8))

        #expect(text.hasSuffix("\n"), "frames are newline-delimited")
        #expect(text.dropLast().contains("\n") == false, "a frame never contains a bare newline")
        #expect(text.contains("\"method\":\"listFolder\""))
        #expect(text.contains("/Users/me/Library"), "slashes are not escaped, so paths stay readable")

        let object = try #require(
            try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        )
        #expect(object["v"] as? Int == 1)
        #expect(object["id"] as? String == "7")
    }

    @Test("Optional parameters may be left out, which is what their defaults are for")
    func optionalParametersMayBeOmitted() throws {
        let line = Data(#"{"v":1,"id":"1","method":"listFolder","params":{"path":"/tmp"}}"#.utf8)

        let frame = try decoder.decode(RequestFrame.self, from: line)

        guard case .listFolder(let request) = frame.request else {
            Issue.record("expected listFolder, got \(frame.request)")
            return
        }
        #expect(request.path == "/tmp")
        #expect(request.refresh == false)
    }

    @Test("Methods that take no parameters accept a frame with no params at all")
    func parameterlessMethodsNeedNoParams() throws {
        for line in [
            #"{"v":1,"id":"1","method":"volumes"}"#,
            #"{"v":1,"id":"2","method":"watched"}"#,
            #"{"v":1,"id":"3","method":"suspects"}"#,
            #"{"v":1,"id":"4","method":"volumeSummary"}"#,
        ] {
            let frame = try decoder.decode(RequestFrame.self, from: Data(line.utf8))
            #expect(frame.request.method.rawValue == frame.request.method.rawValue)
        }
    }

    @Test("A missing required parameter is an invalidParameters failure, not a crash")
    func missingRequiredParameterIsReported() throws {
        let line = Data(#"{"v":1,"id":"1","method":"listFolder","params":{}}"#.utf8)

        let failure = try #require(throws: ProtocolFailure.self) {
            _ = try decoder.decode(RequestFrame.self, from: line)
        }
        #expect(failure.code == .invalidParameters)
        #expect(failure.message.contains("listFolder"))
    }

    @Test("An unknown method is named in the failure so a client can see its typo")
    func unknownMethodIsNamed() throws {
        let line = Data(#"{"v":1,"id":"1","method":"listFolders","params":{"path":"/tmp"}}"#.utf8)

        let failure = try #require(throws: ProtocolFailure.self) {
            _ = try decoder.decode(RequestFrame.self, from: line)
        }
        #expect(failure.code == .unknownMethod)
        #expect(failure.message.contains("listFolders"))
    }

    @Test("Trash refuses to be confirmed by omission")
    func trashDefaultsToUnconfirmed() throws {
        let line = Data(#"{"v":1,"id":"1","method":"moveToTrash","params":{"path":"/tmp/x"}}"#.utf8)

        let frame = try decoder.decode(RequestFrame.self, from: line)

        guard case .moveToTrash(let request) = frame.request else {
            Issue.record("expected moveToTrash")
            return
        }
        #expect(request.confirmed == false, "forgetting the flag must never read as consent")
    }
}

@Suite("Server frames")
struct ServerFrameTests {
    private let decoder = Wire.makeDecoder()
    private let encoder = Wire.makeEncoder()

    @Test("A response carries the method it answers, so a client can decode it blind")
    func responsesNameTheirMethod() throws {
        let listing = FolderListing.sample
        let data = try encoder.encode(ServerFrame.response(id: "3", .listFolder(listing)))

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "response")
        #expect(object["method"] as? String == "listFolder")
        #expect(object["id"] as? String == "3")

        let decoded = try decoder.decode(ServerFrame.self, from: data)
        guard case .response(let id, .listFolder(let round)) = decoded else {
            Issue.record("expected a listFolder response, got \(decoded)")
            return
        }
        #expect(id == "3")
        #expect(round.folder == listing.folder)
        #expect(round.children == listing.children)
        #expect(round.unreadable == listing.unreadable)
    }

    @Test("Every response case survives a round trip", arguments: Request.Method.allCases)
    func everyResponseRoundTrips(method: Request.Method) throws {
        let response = Response.sample(for: method)
        let data = try encoder.encode(ServerFrame.response(id: "x", response))

        let decoded = try decoder.decode(ServerFrame.self, from: data)
        guard case .response(let id, let round) = decoded else {
            Issue.record("expected a response frame")
            return
        }
        #expect(id == "x")
        #expect(round.method == method)
    }

    @Test("A failure keeps the request id, the code and the path that caused it")
    func failuresAreCorrelatedAndSpecific() throws {
        let failure = ProtocolFailure(
            code: .notReadable,
            message: "Jaaga may need Full Disk Access.",
            path: "/Library/Application Support/com.apple.TCC",
            errnoCode: EACCES
        )

        let data = try encoder.encode(ServerFrame.failure(id: "9", failure))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "error")

        let decoded = try decoder.decode(ServerFrame.self, from: data)
        guard case .failure(let id, let round) = decoded else {
            Issue.record("expected a failure frame")
            return
        }
        #expect(id == "9")
        #expect(round == failure)
    }

    @Test("Every event survives a round trip", arguments: Event.Name.allCases)
    func everyEventRoundTrips(name: Event.Name) throws {
        let event = Event.sample(for: name)
        let data = try encoder.encode(ServerFrame.event(event))

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "event")
        #expect(object["event"] as? String == name.rawValue)
        #expect(object["id"] == nil, "events answer no request, so they carry no id")

        let decoded = try decoder.decode(ServerFrame.self, from: data)
        guard case .event(let round) = decoded else {
            Issue.record("expected an event frame")
            return
        }
        #expect(round.name == name)
    }

    @Test("Dates travel as epoch seconds, so no client needs a date format")
    func datesAreEpochSeconds() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var listing = FolderListing.sample
        listing.scannedAt = when

        let data = try encoder.encode(ServerFrame.response(id: "1", .listFolder(listing)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["scannedAt"] as? Double == 1_700_000_000)
    }
}

@Suite("Protocol versioning")
struct VersioningTests {
    @Test("The current version is one this build declares it supports")
    func currentVersionIsSupported() {
        #expect(JaagaProtocolVersion.supported.contains(JaagaProtocolVersion.current))
    }

    @Test("A frame states its version, and an old client's version is preserved as sent")
    func versionIsCarriedThrough() throws {
        let line = Data(#"{"v":1,"id":"1","method":"volumes"}"#.utf8)

        let frame = try Wire.makeDecoder().decode(RequestFrame.self, from: line)
        #expect(frame.version == 1)
    }

    @Test("A frame with a future version decodes so the daemon can refuse it with a clear message")
    func futureVersionsDecodeSoTheyCanBeRefused() throws {
        let line = Data(#"{"v":99,"id":"1","method":"volumes"}"#.utf8)

        let frame = try Wire.makeDecoder().decode(RequestFrame.self, from: line)

        #expect(frame.version == 99)
        #expect(
            !JaagaProtocolVersion.supported.contains(frame.version),
            "the daemon checks this and answers unsupportedProtocolVersion"
        )
    }

    @Test("A frame with no version at all is read as the current one")
    func versionDefaultsToCurrent() throws {
        let line = Data(#"{"id":"1","method":"volumes"}"#.utf8)

        let frame = try Wire.makeDecoder().decode(RequestFrame.self, from: line)
        #expect(frame.version == JaagaProtocolVersion.current)
    }

    @Test("Unknown fields are ignored, so a newer daemon can add some without breaking clients")
    func unknownFieldsAreIgnored() throws {
        let line = Data(
            #"{"v":1,"id":"1","method":"listFolder","params":{"path":"/tmp","somethingNew":true},"extra":42}"#.utf8
        )

        let frame = try Wire.makeDecoder().decode(RequestFrame.self, from: line)
        #expect(frame.request == .listFolder(ListFolderRequest(path: "/tmp")))
    }
}

@Suite("Line framing")
struct LineFramerTests {
    @Test("Frames are split on newlines")
    func splitsOnNewlines() throws {
        var framer = LineFramer()

        let frames = try framer.push(Data("one\ntwo\nthree\n".utf8))

        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["one", "two", "three"])
        #expect(framer.pendingByteCount == 0)
    }

    @Test("A frame split across reads is held until it is whole")
    func reassemblesSplitFrames() throws {
        var framer = LineFramer()

        #expect(try framer.push(Data(#"{"id":"#.utf8)).isEmpty)
        #expect(framer.pendingByteCount > 0)
        let frames = try framer.push(Data("\"1\"}\n".utf8))

        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == [#"{"id":"1"}"#])
        #expect(framer.pendingByteCount == 0)
    }

    @Test("Blank lines are dropped rather than decoded as empty frames")
    func dropsBlankLines() throws {
        var framer = LineFramer()

        let frames = try framer.push(Data("\n\nreal\n\n".utf8))

        #expect(frames.count == 1)
    }

    @Test("An unterminated frame past the limit is refused instead of buffered forever")
    func refusesOversizedFrames() throws {
        var framer = LineFramer(maximumFrameBytes: 64)

        #expect(throws: LineFramer.FramingError.self) {
            _ = try framer.push(Data(repeating: 0x41, count: 128))
        }
        #expect(framer.pendingByteCount == 0, "the buffer is dropped so the connection can be closed")
    }

    @Test("A frame exactly at the limit is fine")
    func acceptsFramesAtTheLimit() throws {
        var framer = LineFramer(maximumFrameBytes: 8)

        let frames = try framer.push(Data("12345678\n".utf8))
        #expect(frames.count == 1)
    }
}

// MARK: - Samples

extension Request {
    /// One representative value per method, so the round-trip tests cover the whole surface and a new
    /// method cannot be added without a sample for it.
    static func sample(for method: Method) -> Request {
        switch method {
        case .hello: .hello(HelloRequest(clientName: "Jaaga.app", clientVersion: "1.0.0"))
        case .volumes: .volumes
        case .volumeSummary: .volumeSummary(VolumeSummaryRequest(mountPath: "/", refresh: true))
        case .listFolder: .listFolder(ListFolderRequest(path: "/Users/me/Movies", refresh: true))
        case .entry: .entry(PathRequest(path: "/Users/me/Movies"))
        case .suspects: .suspects(SuspectsRequest(root: "/Users/me", refresh: false))
        case .watch: .watch(PathRequest(path: "/Users/me/Library/Caches"))
        case .unwatch: .unwatch(PathRequest(path: "/Users/me/Library/Caches"))
        case .watched: .watched
        case .quickLook: .quickLook(QuickLookRequest(path: "/Users/me/Downloads", limit: 9))
        case .reveal: .reveal(PathRequest(path: "/Users/me/Downloads/Thing.dmg"))
        case .moveToTrash: .moveToTrash(TrashRequest(path: "/Users/me/Downloads/Thing.dmg", confirmed: true))
        case .cancel: .cancel(CancelRequest(requestID: "17"))
        }
    }
}

extension Response {
    static func sample(for method: Request.Method) -> Response {
        switch method {
        case .hello:
            .hello(
                HelloResponse(
                    protocolVersion: 1,
                    supportedProtocolVersions: [1],
                    daemonVersion: "1.0.0",
                    homePath: "/Users/me",
                    socketPath: "/Users/me/Library/Application Support/Jaaga/jaagad.sock"
                )
            )
        case .volumes: .volumes(VolumesResponse(volumes: [.sample], homePath: "/Users/me"))
        case .volumeSummary:
            .volumeSummary(
                VolumeSummary(
                    volume: .sample,
                    segments: [CategorySegment(label: "Code", category: .dev, bytes: 74_500_000_000)],
                    accountedBytes: 74_500_000_000,
                    measuredAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        case .listFolder: .listFolder(.sample)
        case .entry: .entry(.sample)
        case .suspects:
            .suspects(
                SuspectReport(
                    suspects: [.sample],
                    totalBytes: 38_600_000_000,
                    safeToClearBytes: 38_600_000_000,
                    scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    unreadable: []
                )
            )
        case .watch: .watch(.sample)
        case .unwatch: .unwatch(Acknowledgement())
        case .watched: .watched(WatchedResponse(folders: [.sample]))
        case .quickLook:
            .quickLook(
                QuickLookReport(
                    entry: .sample,
                    items: [
                        QuickLookItem(
                            name: "Render Files",
                            path: "/Users/me/Movies/Trip.fcpbundle/Render Files",
                            isDirectory: true,
                            allocatedBytes: 38_200_000_000
                        )
                    ],
                    truncated: true,
                    prefersSystemPreview: false
                )
            )
        case .reveal: .reveal(Acknowledgement())
        case .moveToTrash:
            .moveToTrash(
                TrashResponse(
                    originalPath: "/Users/me/Downloads/Thing.dmg",
                    trashedPath: "/Users/me/.Trash/Thing.dmg",
                    reclaimedBytes: 1_900_000_000
                )
            )
        case .cancel: .cancel(Acknowledgement(ok: false))
        }
    }
}

extension Event {
    static func sample(for name: Name) -> Event {
        switch name {
        case .scanProgress:
            .scanProgress(
                ScanProgressEvent(
                    requestID: "4",
                    root: "/Users/me",
                    currentPath: "/Users/me/Library/Caches/Spotify",
                    itemsScanned: 120_400,
                    bytesScanned: 9_800_000_000
                )
            )
        case .scanCompleted:
            .scanCompleted(
                ScanCompletedEvent(
                    requestID: "4",
                    root: "/Users/me",
                    allocatedBytes: 508_200_000_000,
                    itemCount: 1_284_019,
                    durationSeconds: 12.4,
                    unreadableCount: 2
                )
            )
        case .folderChanged: .folderChanged(FolderChangedEvent(paths: ["/Users/me/Downloads"]))
        case .watchUpdated: .watchUpdated(WatchUpdatedEvent(folder: .sample))
        case .watchAlert:
            .watchAlert(
                WatchAlertEvent(
                    folder: .sample,
                    accelerationFactor: 3.1,
                    message: "DerivedData is growing 3.1× faster than usual"
                )
            )
        }
    }
}

extension Entry {
    static let sample = Entry(
        path: "/Users/me/Library/Developer/Xcode/DerivedData",
        name: "DerivedData",
        isDirectory: true,
        allocatedBytes: 38_600_000_000,
        itemCount: 412_380,
        directChildCount: 9,
        category: .dev,
        verdict: .safeToClear,
        reason: "Xcode rebuilds this the next time you build.",
        kind: "Xcode build cache",
        lastOpened: Date(timeIntervalSince1970: 1_700_000_000),
        contentModified: Date(timeIntervalSince1970: 1_700_000_000),
        created: Date(timeIntervalSince1970: 1_600_000_000),
        isWatched: true
    )
}

extension FolderListing {
    static let sample = FolderListing(
        folder: .sample,
        children: [.sample],
        parentPath: "/Users/me/Library/Developer/Xcode",
        scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
        fromCache: false,
        complete: false,
        unreadable: [UnreadablePath(path: "/Users/me/Library/Mail", reason: "Permission denied", errnoCode: EACCES)]
    )
}

extension VolumeInfo {
    static let sample = VolumeInfo(
        name: "Macintosh HD",
        mountPath: "/",
        totalBytes: 994_700_000_000,
        freeBytes: 280_400_000_000,
        isStartupDisk: true,
        isInternal: true,
        isRemovable: false
    )
}

extension Suspect {
    static let sample = Suspect(
        id: "xcode-derived-data",
        title: "DerivedData",
        displayPath: "~/Library/Developer/Xcode/DerivedData",
        paths: ["/Users/me/Library/Developer/Xcode/DerivedData"],
        category: .dev,
        verdict: .safeToClear,
        reason: "Xcode rebuilds this the next time you build.",
        kind: "Xcode build cache",
        allocatedBytes: 38_600_000_000,
        itemCount: 412_380,
        isWatched: true,
        isAggregate: false
    )
}

extension WatchedFolder {
    static let sample = WatchedFolder(
        path: "/Users/me/Library/Developer/Xcode/DerivedData",
        name: "DerivedData",
        category: .dev,
        verdict: .safeToClear,
        addedAt: Date(timeIntervalSince1970: 1_600_000_000),
        currentBytes: 38_600_000_000,
        samples: [
            SizeSample(at: Date(timeIntervalSince1970: 1_699_000_000), bytes: 21_200_000_000),
            SizeSample(at: Date(timeIntervalSince1970: 1_700_000_000), bytes: 38_600_000_000),
        ],
        growth: GrowthSummary(
            deltaBytes: 17_400_000_000,
            windowSeconds: 1_000_000,
            recentBytesPerDay: 1_500_000_000,
            baselineBytesPerDay: 480_000_000,
            accelerationFactor: 3.1,
            isAlerting: true
        )
    )
}
