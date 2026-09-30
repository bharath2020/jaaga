import AppKit
import Foundation
import JaagaProtocol

/// The two things Jaaga does *to* the filesystem rather than merely reading it.
///
/// Both live in the daemon so that the app, a CLI and an MCP server all get the same behaviour and
/// the same guard rails, rather than three implementations of "delete".
public struct FileActions: Sendable {
    public init() {}

    /// Moves `path` to the Trash. Never deletes anything permanently.
    ///
    /// `NSFileManager.trashItem` is the only deletion Jaaga performs: it is undoable from the Finder,
    /// it triggers no confirmation of its own, and it fails rather than silently recursing if the
    /// item is protected. A caller that has not confirmed with a human is refused outright.
    public func moveToTrash(path: String, confirmed: Bool, knownBytes: Int64?) throws -> TrashResponse {
        guard confirmed else {
            throw ProtocolFailure(
                code: .confirmationRequired,
                message: "moveToTrash needs confirmed: true. Jaaga never removes anything a human has not agreed to.",
                path: path
            )
        }

        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ProtocolFailure(
                code: .notFound,
                message: "Nothing to move: \(url.path) does not exist.",
                path: url.path,
                errnoCode: errno
            )
        }

        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        } catch {
            let nsError = error as NSError
            let code: ErrorCode = nsError.code == NSFileWriteNoPermissionError ? .notPermitted : .internalError
            throw ProtocolFailure(
                code: code,
                message: "Could not move \(url.lastPathComponent) to the Trash: \(nsError.localizedDescription)",
                path: url.path
            )
        }

        return TrashResponse(
            originalPath: url.path,
            trashedPath: (resultingURL as URL?)?.path,
            reclaimedBytes: knownBytes ?? Int64(info.st_blocks) * 512
        )
    }

    /// Selects `path` in the Finder.
    public func reveal(path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProtocolFailure(
                code: .notFound,
                message: "Nothing to reveal: \(url.path) does not exist.",
                path: url.path
            )
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
