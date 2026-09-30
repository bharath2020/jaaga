import Foundation
import JaagaProtocol

public struct Classification: Sendable, Hashable {
    public var category: UsageCategory
    public var verdict: Verdict
    public var reason: String
    public var kind: String
    /// The catalog rule that produced this, when one did.
    public var ruleID: String?

    public init(category: UsageCategory, verdict: Verdict, reason: String, kind: String, ruleID: String? = nil) {
        self.category = category
        self.verdict = verdict
        self.reason = reason
        self.kind = kind
        self.ruleID = ruleID
    }
}

/// Gives every folder a colour, a verdict and one sentence of plain language.
///
/// Three passes, most specific first:
///
/// 1. A usual-suspects catalog rule whose path this is, or sits inside.
/// 2. A well-known folder name (`node_modules`, `DerivedData`, `.build`, `Caches`).
/// 3. Where it lives — `~/Movies` is media, `~/Downloads` is downloads, `~/Library` is cache.
///
/// The default verdict is `yourData`. Jaaga only upgrades to "safe to clear" when it recognises
/// something specific, because the cost of being wrong in that direction is somebody's work.
public struct Classifier: Sendable {
    public let home: String
    public let catalog: SuspectCatalog

    /// Catalog rules with a single concrete path, resolved and indexed for lookup.
    private let rulesByPath: [String: SuspectRule]
    /// Rules that match on a directory name, e.g. `node_modules`.
    private let rulesByDirectoryName: [String: SuspectRule]

    public init(home: String, catalog: SuspectCatalog) {
        self.home = (home as NSString).standardizingPath
        self.catalog = catalog

        var byPath: [String: SuspectRule] = [:]
        var byName: [String: SuspectRule] = [:]
        for rule in catalog.rules {
            switch rule.match {
            case .path(let relative):
                byPath[Classifier.absolute(relative, home: self.home)] = rule
            case .directoryName(let name, _, _):
                byName[name] = rule
            case .filesWithExtensions:
                break
            }
        }
        self.rulesByPath = byPath
        self.rulesByDirectoryName = byName
    }

    static func absolute(_ path: String, home: String) -> String {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return (home as NSString).appendingPathComponent(path)
    }

    public func classify(path: String, isDirectory: Bool) -> Classification {
        let standardized = (path as NSString).standardizingPath
        let name = (standardized as NSString).lastPathComponent

        if let rule = rulesByPath[standardized] {
            return Classification(
                category: rule.category,
                verdict: rule.verdict,
                reason: rule.reason,
                kind: rule.kind,
                ruleID: rule.id
            )
        }

        if isDirectory, let rule = rulesByDirectoryName[name] {
            return Classification(
                category: rule.category,
                verdict: rule.verdict,
                reason: rule.reason,
                kind: rule.kind,
                ruleID: rule.id
            )
        }

        // Inside a catalogued folder: inherit its category and verdict, because a child of
        // DerivedData is just as rebuildable as DerivedData itself. The reason stays generic so we
        // never claim more about the child than we know.
        if let ancestor = nearestCatalogAncestor(of: standardized) {
            return Classification(
                category: ancestor.category,
                verdict: ancestor.verdict,
                reason: "Inside \(ancestor.title). \(ancestor.reason)",
                kind: ancestor.kind,
                ruleID: ancestor.id
            )
        }

        if let known = Self.knownFolders[name] {
            return known
        }

        return locationBased(standardized, name: name, isDirectory: isDirectory)
    }

    private func nearestCatalogAncestor(of path: String) -> SuspectRule? {
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            if let rule = rulesByPath[current] { return rule }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Folder names that mean the same thing wherever they turn up.
    private static let knownFolders: [String: Classification] = [
        "node_modules": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Dependencies npm install brings back in seconds. Nothing you wrote lives in here.",
            kind: "Dependencies"
        ),
        "DerivedData": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Xcode rebuilds this the next time you build.",
            kind: "Xcode build cache"
        ),
        "Caches": Classification(
            category: .cache,
            verdict: .safeToClear,
            reason: "Temporary copies apps keep so they load faster. Apps rebuild what they need.",
            kind: "Cache folder"
        ),
        ".build": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Swift build output. Regenerated by the next build.",
            kind: "Build output"
        ),
        "build": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Build output. Regenerated by the next build.",
            kind: "Build output"
        ),
        "target": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Cargo build output. Regenerated by the next build.",
            kind: "Build output"
        ),
        "dist": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "Packaged build output. Regenerated by the next build.",
            kind: "Build output"
        ),
        ".venv": Classification(
            category: .dev,
            verdict: .safeToClear,
            reason: "A Python virtual environment. Recreated from your requirements file.",
            kind: "Virtual environment"
        ),
        ".Trash": Classification(
            category: .system,
            verdict: .safeToClear,
            reason: "Items you already chose to delete. Emptying the Trash is what frees the space.",
            kind: "Deleted items"
        ),
        ".git": Classification(
            category: .dev,
            verdict: .yourData,
            reason: "Your repository's entire history. Deleting it loses every commit that is not pushed.",
            kind: "Git repository"
        ),
    ]

    /// The fallback: category from where it sits, verdict left at `yourData`.
    private func locationBased(_ path: String, name: String, isDirectory: Bool) -> Classification {
        let kind = isDirectory ? "Folder" : fileKind(for: name)

        // Only look at the part of the path below home; `/Users/me/Movies` is media, but a folder
        // called "Movies" buried in a project is not.
        guard path.hasPrefix(home + "/") || path == home else {
            if path.hasPrefix("/Applications") {
                return Classification(
                    category: .apps,
                    verdict: .yourData,
                    reason: "An installed application. Remove it from the Applications folder if you no longer use it.",
                    kind: "Application"
                )
            }
            return Classification(
                category: .system,
                verdict: .yourData,
                reason: "Part of macOS or another user's space. Jaaga leaves this alone.",
                kind: kind
            )
        }

        if path == home {
            return Classification(
                category: .system,
                verdict: .yourData,
                reason: "Everything you own lives here. Pick a coloured block to see what is inside it.",
                kind: "Home folder"
            )
        }

        let relative = String(path.dropFirst(home.count + 1))
        let top = relative.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relative

        switch top {
        case "Library":
            return Classification(
                category: .cache,
                verdict: .reviewFirst,
                reason: "Where apps keep caches, support files and simulators. Most of the usual suspects live in here.",
                kind: isDirectory ? "System folder" : kind
            )
        case "Movies", "Music":
            return Classification(
                category: .media,
                verdict: .yourData,
                reason: "Your media. Big files, but only you know which ones still matter.",
                kind: isDirectory ? "Media folder" : kind
            )
        case "Pictures":
            return Classification(
                category: .photos,
                verdict: .yourData,
                reason: "Mostly your photo library. Turn on Optimize Mac Storage in Photos rather than deleting here.",
                kind: isDirectory ? "Media folder" : kind
            )
        case "Downloads":
            return Classification(
                category: .downloads,
                verdict: .reviewFirst,
                reason: "A drop zone that never empties. Installers and archives are usually safe once you have used them.",
                kind: isDirectory ? "Folder" : kind
            )
        case "Documents", "Desktop":
            return Classification(
                category: .docs,
                verdict: .yourData,
                reason: "Your documents. Rarely the problem, often the thing to protect.",
                kind: isDirectory ? "Folder" : kind
            )
        case "Applications":
            return Classification(
                category: .apps,
                verdict: .yourData,
                reason: "Applications you installed for yourself.",
                kind: isDirectory ? "Applications folder" : kind
            )
        case "Developer", "Projects", "Code", "code", "src", "repos", "Sites", "work":
            return Classification(
                category: .dev,
                verdict: .yourData,
                reason: "Your code. The weight is usually tooling that can reinstall itself.",
                kind: isDirectory ? "Projects folder" : kind
            )
        default:
            return Classification(
                category: .system,
                verdict: .yourData,
                reason: "Jaaga does not recognise this one, so it assumes it is yours.",
                kind: kind
            )
        }
    }

    private func fileKind(for name: String) -> String {
        let extensionName = (name as NSString).pathExtension
        guard !extensionName.isEmpty else { return "File" }
        return extensionName.uppercased() + " file"
    }
}
