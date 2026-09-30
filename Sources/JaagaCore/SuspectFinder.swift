import Foundation
import JaagaProtocol

/// A catalog rule matched against this machine: which concrete paths it turned out to cover.
public struct SuspectMatchResult: Sendable, Hashable {
    public var rule: SuspectRule
    /// Every path the rule matched. One entry unless the rule aggregates.
    public var paths: [String]
    public var displayPath: String
    /// True for the folder-scan kinds. False when `paths` are individual files whose sizes should
    /// be added up rather than scanned as trees.
    public var pathsAreDirectories: Bool

    public init(rule: SuspectRule, paths: [String], displayPath: String, pathsAreDirectories: Bool) {
        self.rule = rule
        self.paths = paths
        self.displayPath = displayPath
        self.pathsAreDirectories = pathsAreDirectories
    }
}

/// Turns the catalog into a list of paths that actually exist here.
///
/// Discovery is deliberately separate from measurement: finding `node_modules` in eleven projects is
/// a cheap shallow walk, while measuring them is the expensive part, and the daemon wants to route
/// that through its cache.
public struct SuspectFinder: Sendable {
    public let catalog: SuspectCatalog

    public init(catalog: SuspectCatalog) {
        self.catalog = catalog
    }

    /// Resolves every rule against `root` (normally the user's home folder).
    ///
    /// Rules that match nothing are dropped, so a Mac without Docker never shows a Docker row.
    public func discover(root: String, now: Date = Date()) -> [SuspectMatchResult] {
        let base = (root as NSString).standardizingPath
        return catalog.rules.compactMap { rule in
            switch rule.match {
            case .path(let relative):
                let absolute = Classifier.absolute(relative, home: base)
                guard let isDirectory = kind(of: absolute) else { return nil }
                return SuspectMatchResult(
                    rule: rule,
                    paths: [absolute],
                    displayPath: rule.displayPath ?? abbreviate(absolute, home: base),
                    pathsAreDirectories: isDirectory
                )

            case .directoryName(let name, let roots, let maxDepth):
                let found = findDirectories(named: name, under: roots, base: base, maxDepth: maxDepth)
                guard !found.isEmpty else { return nil }
                return SuspectMatchResult(
                    rule: rule,
                    paths: found,
                    displayPath: rule.displayPath ?? "\(abbreviate(base, home: base))/…/\(name)",
                    pathsAreDirectories: true
                )

            case .filesWithExtensions(let extensions, let relativeRoot, let minimumAgeDays):
                let searchRoot = Classifier.absolute(relativeRoot, home: base)
                let found = findFiles(
                    withExtensions: extensions,
                    in: searchRoot,
                    minimumAgeDays: minimumAgeDays,
                    now: now
                )
                guard !found.isEmpty else { return nil }
                return SuspectMatchResult(
                    rule: rule,
                    paths: found,
                    displayPath: rule.displayPath ?? abbreviate(searchRoot, home: base),
                    pathsAreDirectories: false
                )
            }
        }
    }

    /// `nil` when nothing is there; otherwise whether it is a directory. Never follows a symlink,
    /// so a link pointing at a huge tree is not mistaken for the tree.
    private func kind(of path: String) -> Bool? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let mode = info.st_mode & S_IFMT
        if mode == S_IFLNK { return nil }
        return mode == S_IFDIR
    }

    /// Breadth-first search for directories with a given name, not descending into ones it finds.
    ///
    /// Not descending matters: a `node_modules` containing a nested `node_modules` should be counted
    /// once, by its outermost folder, or the total would double-count.
    private func findDirectories(named name: String, under roots: [String], base: String, maxDepth: Int) -> [String] {
        var found: [String] = []
        var queue: [(path: String, depth: Int)] = roots.compactMap { relative in
            let absolute = Classifier.absolute(relative, home: base)
            return kind(of: absolute) == true ? (absolute, 0) : nil
        }

        while let (path, depth) = queue.first {
            queue.removeFirst()
            guard depth <= maxDepth else { continue }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { continue }

            for entry in names {
                let childPath = (path as NSString).appendingPathComponent(entry)
                guard kind(of: childPath) == true else { continue }
                if entry == name {
                    found.append(childPath)
                } else if depth < maxDepth {
                    queue.append((childPath, depth + 1))
                }
            }
        }
        return found.sorted()
    }

    private func findFiles(
        withExtensions extensions: [String],
        in root: String,
        minimumAgeDays: Int?,
        now: Date
    ) -> [String] {
        guard kind(of: root) == true,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root)
        else { return [] }

        let wanted = Set(extensions.map { $0.lowercased() })
        let cutoff = minimumAgeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }

        return names.compactMap { name -> String? in
            guard wanted.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            let path = (root as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            if let cutoff {
                // Judge by modification time, not access time: Spotlight and backups touch atime.
                guard let modified = date(info.st_mtimespec), modified <= cutoff else { return nil }
            }
            return path
        }
        .sorted()
    }

    /// `/Users/me/Downloads` → `~/Downloads`.
    private func abbreviate(_ path: String, home: String) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

extension SuspectRule {
    /// Fills the placeholders in a reason so an aggregate rule can say how many places it found:
    /// `{count}` becomes the number, and `{s}` becomes a plural "s" unless the count is one, which
    /// keeps "Found in 1 project" from reading like a bug.
    public func reason(matchCount: Int) -> String {
        reason
            .replacingOccurrences(of: "{count}", with: String(matchCount))
            .replacingOccurrences(of: "{s}", with: matchCount == 1 ? "" : "s")
    }
}
