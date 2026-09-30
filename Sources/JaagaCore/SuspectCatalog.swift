import Foundation
import JaagaProtocol

/// How a catalog rule finds the thing it describes.
public enum SuspectMatch: Sendable, Hashable {
    /// Exactly one path, relative to the scan root (or absolute if it starts with `/`).
    case path(String)
    /// Directories with a given name, found under any of `roots` down to `maxDepth`.
    /// This is how `node_modules` across a projects folder is caught.
    case directoryName(String, roots: [String], maxDepth: Int)
    /// Files with any of `extensions` directly inside `root`, optionally only ones untouched for a
    /// while. This is how old installers in Downloads are caught.
    case filesWithExtensions([String], root: String, minimumAgeDays: Int?)
}

/// One entry in the usual-suspects catalog: where it lives, what colour it wears, what Jaaga is
/// willing to say about deleting it, and why it got big.
public struct SuspectRule: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var kind: String
    public var category: UsageCategory
    public var verdict: Verdict
    public var reason: String
    /// What to show the user, e.g. `~/Developer/*/node_modules`. Derived from the match if absent.
    public var displayPath: String?
    public var match: SuspectMatch
    /// True when the rule sums many matched paths into one row.
    public var isAggregate: Bool

    public init(
        id: String,
        title: String,
        kind: String,
        category: UsageCategory,
        verdict: Verdict,
        reason: String,
        displayPath: String? = nil,
        match: SuspectMatch,
        isAggregate: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.category = category
        self.verdict = verdict
        self.reason = reason
        self.displayPath = displayPath
        self.match = match
        self.isAggregate = isAggregate
    }
}

/// The catalog of folders that grow quietly.
///
/// It is data, not code: the shipped rules live in `Resources/suspects.json` and a user can add
/// their own at `~/Library/Application Support/Jaaga/suspects.json`. Nothing in the daemon
/// hard-codes a path, so covering a new tool means editing JSON.
public struct SuspectCatalog: Sendable, Hashable {
    public var version: Int
    public var rules: [SuspectRule]

    public init(version: Int, rules: [SuspectRule]) {
        self.version = version
        self.rules = rules
    }

    public enum LoadError: Error, Sendable, Equatable, CustomStringConvertible {
        case resourceMissing(searched: [String])
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .resourceMissing(let searched):
                return "suspects.json was not found, so the daemon cannot classify usual suspects. "
                    + "Looked in:\n" + searched.map { "  \($0)" }.joined(separator: "\n")
            case .unsupportedVersion(let version):
                return "suspects.json declares version \(version); this build understands "
                    + "\(SuspectCatalog.supportedVersion)."
            }
        }
    }

    public static let supportedVersion = 1

    /// The catalog shipped with the build.
    public static func bundled() throws -> SuspectCatalog {
        let (url, searched) = CatalogLocation.find()
        guard let url else { throw LoadError.resourceMissing(searched: searched) }
        return try load(contentsOf: url)
    }

    public static func load(contentsOf url: URL) throws -> SuspectCatalog {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> SuspectCatalog {
        let document = try JSONDecoder().decode(CatalogDocument.self, from: data)
        guard document.version == supportedVersion else {
            throw LoadError.unsupportedVersion(document.version)
        }
        return SuspectCatalog(version: document.version, rules: document.rules.map(\.rule))
    }

    /// The shipped catalog, with any rules from `overrideURL` appended. A rule there with the same
    /// `id` as a shipped one replaces it, so a user can retune a verdict without forking the file.
    public static func resolved(overrideURL: URL?) throws -> SuspectCatalog {
        var catalog = try bundled()
        guard let overrideURL, FileManager.default.fileExists(atPath: overrideURL.path) else {
            return catalog
        }
        let extra = try load(contentsOf: overrideURL)
        var byID = Dictionary(catalog.rules.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var order = catalog.rules.map(\.id)
        for rule in extra.rules where byID.updateValue(rule, forKey: rule.id) == nil {
            order.append(rule.id)
        }
        catalog.rules = order.compactMap { byID[$0] }
        return catalog
    }
}

// MARK: - JSON shape

/// The on-disk form. Separate from `SuspectRule` so the file format can gain fields without the
/// in-memory model growing optionals it does not need.
private struct CatalogDocument: Decodable {
    var version: Int
    var rules: [RuleDocument]
}

private struct RuleDocument: Decodable {
    var id: String
    var title: String
    var kind: String
    var category: UsageCategory
    var verdict: Verdict
    var reason: String
    var displayPath: String?
    var aggregate: Bool?
    var match: MatchDocument

    var rule: SuspectRule {
        SuspectRule(
            id: id,
            title: title,
            kind: kind,
            category: category,
            verdict: verdict,
            reason: reason,
            displayPath: displayPath,
            match: match.resolved,
            isAggregate: aggregate ?? false
        )
    }
}

private struct MatchDocument: Decodable {
    enum Kind: String, Decodable {
        case path
        case directoryName
        case filesWithExtensions
    }

    var type: Kind
    var path: String?
    var name: String?
    var roots: [String]?
    var maxDepth: Int?
    var root: String?
    var extensions: [String]?
    var minimumAgeDays: Int?

    var resolved: SuspectMatch {
        switch type {
        case .path:
            .path(path ?? "")
        case .directoryName:
            .directoryName(name ?? "", roots: roots ?? [], maxDepth: maxDepth ?? 3)
        case .filesWithExtensions:
            .filesWithExtensions(extensions ?? [], root: root ?? "", minimumAgeDays: minimumAgeDays)
        }
    }
}
