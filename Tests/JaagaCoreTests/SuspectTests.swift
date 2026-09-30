import Foundation
import JaagaProtocol
import Testing

@testable import JaagaCore

@Suite("Usual suspects")
struct SuspectCatalogTests {
    @Test("The shipped catalog loads and covers the eight kinds the design names")
    func bundledCatalogCoversTheDesign() throws {
        let catalog = try SuspectCatalog.bundled()

        #expect(catalog.version == SuspectCatalog.supportedVersion)
        let ids = Set(catalog.rules.map(\.id))
        let required = [
            "xcode-derived-data",
            "core-simulator-devices",
            "ios-device-support",
            "user-caches",
            "docker-disk-image",
            "iphone-backups",
            "node-modules",
            "downloads-installers",
        ]
        for id in required {
            #expect(ids.contains(id), "the catalog is missing '\(id)'")
        }
    }

    @Test("Every rule says something useful about itself")
    func everyRuleIsDescribed() throws {
        for rule in try SuspectCatalog.bundled().rules {
            #expect(!rule.title.isEmpty, "\(rule.id) has no title")
            #expect(!rule.kind.isEmpty, "\(rule.id) has no kind")
            #expect(rule.reason.count > 20, "\(rule.id) needs a real sentence, not a label")
            #expect(rule.reason.hasSuffix(".") , "\(rule.id)'s reason should read as a sentence")
        }
    }

    @Test("A future catalog version is refused rather than half-read")
    func refusesUnknownVersion() throws {
        let data = Data(#"{"version": 99, "rules": []}"#.utf8)

        #expect(throws: SuspectCatalog.LoadError.unsupportedVersion(99)) {
            _ = try SuspectCatalog.decode(data)
        }
    }

    @Test("A user override replaces a shipped rule with the same id and appends new ones")
    func overrideMergesByID() throws {
        let tree = try TemporaryTree()
        let override = tree.root.appendingPathComponent("suspects.json")
        try Data(
            """
            {"version": 1, "rules": [
              {"id": "user-caches", "title": "My caches", "kind": "Cache folder", "category": "cache",
               "verdict": "review_first", "reason": "I want to look at these myself first.",
               "match": {"type": "path", "path": "Library/Caches"}},
              {"id": "my-own", "title": "Renders", "kind": "Render cache", "category": "media",
               "verdict": "safe_to_clear", "reason": "Regenerated on the next export.",
               "match": {"type": "path", "path": "Renders"}}
            ]}
            """.utf8
        ).write(to: override)

        let catalog = try SuspectCatalog.resolved(overrideURL: override)

        let caches = try #require(catalog.rules.first { $0.id == "user-caches" })
        #expect(caches.title == "My caches")
        #expect(caches.verdict == .reviewFirst, "the override wins over the shipped verdict")
        #expect(catalog.rules.contains { $0.id == "my-own" })
        #expect(catalog.rules.contains { $0.id == "xcode-derived-data" }, "shipped rules survive")
    }

    @Test("An override rule missing the path it matches is refused, not read as the home folder")
    func refusesARuleWithoutAPath() throws {
        let data = Data(
            """
            {"version": 1, "rules": [
              {"id": "typo", "title": "Oops", "kind": "Folder", "category": "cache",
               "verdict": "safe_to_clear", "reason": "A rule whose path was misspelled.",
               "match": {"type": "path", "pth": "Library/Oops"}}
            ]}
            """.utf8
        )

        #expect(throws: SuspectCatalog.LoadError.invalidRule(id: "typo", missing: "match.path")) {
            _ = try SuspectCatalog.decode(data)
        }
    }

    @Test("A rule that matches by name or extension alone cannot claim safe to clear")
    func capsNameOnlyRules() throws {
        let data = Data(
            """
            {"version": 1, "rules": [
              {"id": "pods", "title": "Pods", "kind": "Dependencies", "category": "dev",
               "verdict": "safe_to_clear", "reason": "CocoaPods dependencies, reinstalled by pod install.",
               "match": {"type": "directoryName", "name": "Pods", "roots": ["Developer"]}},
              {"id": "zips", "title": "Archives", "kind": "Archives", "category": "downloads",
               "verdict": "safe_to_clear", "reason": "Archives you probably already unpacked.",
               "match": {"type": "filesWithExtensions", "extensions": ["zip"], "root": "Downloads"}}
            ]}
            """.utf8
        )

        let catalog = try SuspectCatalog.decode(data)

        #expect(catalog.rules.allSatisfy { $0.verdict == .reviewFirst })
    }

    @Test("Gradle's own settings are never offered up; only its download caches are")
    func gradleIsNarrowedToItsCaches() throws {
        let tree = try TemporaryTree()
        try tree.file(".gradle/gradle.properties", bytes: 200)
        try tree.file(".gradle/init.d/company.gradle", bytes: 200)
        try tree.file(".gradle/caches/modules-2/blob.jar", bytes: 4_000)
        try tree.file(".gradle/wrapper/dists/gradle-8.10-bin/gradle.zip", bytes: 4_000)
        let subject = Classifier(home: tree.path, catalog: try SuspectCatalog.bundled())

        for path in [".gradle", ".gradle/gradle.properties", ".gradle/init.d"] {
            let absolute = tree.root.appendingPathComponent(path).path
            let verdict = subject.classify(path: absolute, isDirectory: !path.hasSuffix(".properties")).verdict
            #expect(verdict != .safeToClear, "\(path) holds settings and credentials")
        }
        for path in [".gradle/caches", ".gradle/wrapper/dists"] {
            let absolute = tree.root.appendingPathComponent(path).path
            #expect(subject.classify(path: absolute, isDirectory: true).verdict == .safeToClear)
        }

        let matches = SuspectFinder(catalog: try SuspectCatalog.bundled()).discover(root: tree.path)
        let offered = matches.filter { $0.rule.verdict == .safeToClear }.flatMap(\.paths)
        #expect(!offered.contains(tree.root.appendingPathComponent(".gradle").path))
    }
}

@Suite("Finding suspects on disk")
struct SuspectFinderTests {
    private func catalog() throws -> SuspectCatalog { try SuspectCatalog.bundled() }

    @Test("A catalogued folder that exists is found; one that does not is left out")
    func findsOnlyWhatExists() throws {
        let tree = try TemporaryTree()
        try tree.directory("Library/Caches")
        try tree.file("Library/Caches/app/blob.bin", bytes: 4_096)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let caches = try #require(matches.first { $0.rule.id == "user-caches" })
        #expect(caches.paths == [tree.root.appendingPathComponent("Library/Caches").path])
        #expect(caches.pathsAreDirectories)
        #expect(
            !matches.contains { $0.rule.id == "docker-disk-image" },
            "no Docker installed here, so no Docker row"
        )
    }

    @Test("node_modules is found across several projects and aggregated into one row")
    func aggregatesNodeModulesAcrossProjects() throws {
        let tree = try TemporaryTree()
        for project in ["Developer/ledger-web", "Developer/marketing-site", "Projects/old-thing"] {
            try tree.file("\(project)/package.json", bytes: 100)
            try tree.file("\(project)/node_modules/dep/index.js", bytes: 2_000)
        }
        // Not a match: it is the project's own source, not a dependency tree.
        try tree.file("Developer/ledger-web/src/main.ts", bytes: 500)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let nodeModules = try #require(matches.first { $0.rule.id == "node-modules" })
        #expect(nodeModules.paths.count == 3)
        #expect(nodeModules.rule.isAggregate)
        #expect(nodeModules.paths.allSatisfy { $0.hasSuffix("/node_modules") })
    }

    @Test("A node_modules inside another node_modules is counted once, by the outer one")
    func doesNotDescendIntoAMatchItAlreadyFound() throws {
        let tree = try TemporaryTree()
        try tree.file("Developer/app/package.json", bytes: 100)
        try tree.file("Developer/app/node_modules/pkg/package.json", bytes: 100)
        try tree.file("Developer/app/node_modules/pkg/node_modules/dep/index.js", bytes: 1_000)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let nodeModules = try #require(matches.first { $0.rule.id == "node-modules" })
        #expect(
            nodeModules.paths == [tree.root.appendingPathComponent("Developer/app/node_modules").path],
            "counting the nested one too would double-count its bytes"
        )
    }

    @Test("Old installers in Downloads are found; a fresh download is left alone")
    func findsOnlyStaleInstallers() throws {
        let tree = try TemporaryTree()
        let old = try tree.file("Downloads/Xcode_26.xip", bytes: 5_000)
        let alsoOld = try tree.file("Downloads/Docker.dmg", bytes: 4_000)
        let fresh = try tree.file("Downloads/JustDownloaded.dmg", bytes: 3_000)
        try tree.file("Downloads/notes.pdf", bytes: 1_000)

        let longAgo = Date().addingTimeInterval(-120 * 86_400)
        try tree.setModificationDate(longAgo, of: old)
        try tree.setModificationDate(longAgo, of: alsoOld)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let installers = try #require(matches.first { $0.rule.id == "downloads-installers" })
        #expect(Set(installers.paths) == Set([old.path, alsoOld.path]))
        #expect(!installers.paths.contains(fresh.path), "something downloaded today may still be needed")
        #expect(!installers.pathsAreDirectories, "these are files, to be stat'd rather than walked")
        #expect(
            installers.rule.verdict == .reviewFirst,
            "nothing checks that the app each installer belongs to is installed"
        )

        let subject = Classifier(home: tree.path, catalog: try catalog())
        let single = subject.classify(path: old.path, isDirectory: false)
        #expect(single.verdict == installers.rule.verdict, "the row and the inspector must agree")
        #expect(single.ruleID == "downloads-installers")
    }

    @Test("A node_modules without a project beside it is not counted as a safe-to-clear dependency tree")
    func nodeModulesNeedsAProject() throws {
        let tree = try TemporaryTree()
        try tree.file("Developer/app/package.json", bytes: 100)
        try tree.file("Developer/app/node_modules/dep/index.js", bytes: 1_000)
        try tree.file("Developer/notes/node_modules/mine.txt", bytes: 1_000)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let nodeModules = try #require(matches.first { $0.rule.id == "node-modules" })
        #expect(nodeModules.paths == [tree.root.appendingPathComponent("Developer/app/node_modules").path])
    }

    @Test("One projects folder reached by two spellings is searched once")
    func projectsFolderIsSearchedOnce() throws {
        let tree = try TemporaryTree()
        try tree.file("Code/app/package.json", bytes: 100)
        try tree.file("Code/app/node_modules/dep/index.js", bytes: 1_000)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        // On a case-insensitive volume "code" is "Code"; counting both would double the total.
        let nodeModules = try #require(matches.first { $0.rule.id == "node-modules" })
        #expect(nodeModules.paths.count == 1)
    }

    @Test("A suspect inside another suspect is not counted twice")
    func nestedSuspectsAreCountedOnce() throws {
        let tree = try TemporaryTree()
        try tree.file("Library/Caches/Homebrew/downloads/wget.tar.gz", bytes: 8_000)
        try tree.file("Library/Caches/com.app/blob.bin", bytes: 4_000)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        let everyPath = matches.filter(\.pathsAreDirectories).flatMap(\.paths)
        for path in everyPath {
            let nested = everyPath.filter { $0 != path && path.hasPrefix($0 + "/") }
            #expect(nested.isEmpty, "\(path) sits inside \(nested) and would be counted twice")
        }
        #expect(matches.contains { $0.rule.id == "user-caches" })
    }

    @Test("A symlink standing where a suspect would be is not mistaken for one")
    func ignoresSymlinkedSuspects() throws {
        let tree = try TemporaryTree()
        let elsewhere = try tree.directory("elsewhere")
        try tree.file("elsewhere/huge.bin", bytes: 100_000)
        try tree.directory("Library")
        try tree.symbolicLink("Library/Caches", to: elsewhere)

        let matches = try SuspectFinder(catalog: catalog()).discover(root: tree.path)

        #expect(
            !matches.contains { $0.rule.id == "user-caches" },
            "following it would attribute another tree's bytes to ~/Library/Caches"
        )
    }

    @Test("An aggregate reason counts its matches and gets the plural right")
    func aggregateReasonReadsCorrectly() throws {
        let rule = try #require(try catalog().rules.first { $0.id == "node-modules" })

        #expect(rule.reason(matchCount: 1).contains("1 project."))
        #expect(rule.reason(matchCount: 38).contains("38 projects."))
        #expect(!rule.reason(matchCount: 1).contains("{count}"))
        #expect(!rule.reason(matchCount: 1).contains("{s}"))
    }
}

@Suite("Verdicts")
struct ClassifierTests {
    private func classifier(home: String) throws -> Classifier {
        Classifier(home: home, catalog: try SuspectCatalog.bundled())
    }

    @Test("A catalogued path gets the catalog's verdict and reason")
    func catalogWins() throws {
        let subject = try classifier(home: "/Users/tester")

        let derived = subject.classify(
            path: "/Users/tester/Library/Developer/Xcode/DerivedData",
            isDirectory: true
        )
        #expect(derived.verdict == .safeToClear)
        #expect(derived.category == .dev)
        #expect(derived.ruleID == "xcode-derived-data")
        #expect(derived.reason.contains("rebuilds"))
    }

    @Test("A child of a catalogued folder inherits its verdict")
    func childrenInheritFromTheirCatalogueAncestor() throws {
        let subject = try classifier(home: "/Users/tester")

        let project = subject.classify(
            path: "/Users/tester/Library/Developer/Xcode/DerivedData/Atlas-fhqzpdxkcbe",
            isDirectory: true
        )
        #expect(project.verdict == .safeToClear, "one app's build folder is as rebuildable as the whole cache")
        #expect(project.ruleID == "xcode-derived-data")
    }

    @Test("node_modules is safe to clear beside a package.json, and only worth a look without one")
    func nodeModulesNeedsItsManifest() throws {
        let tree = try TemporaryTree()
        try tree.file("random/place/package.json", bytes: 100)
        try tree.directory("random/place/node_modules")
        try tree.directory("loose/node_modules")
        let subject = try classifier(home: tree.path)

        let project = subject.classify(path: tree.root.appendingPathComponent("random/place/node_modules").path, isDirectory: true)
        #expect(project.verdict == .safeToClear)
        #expect(project.category == .dev)

        let loose = subject.classify(path: tree.root.appendingPathComponent("loose/node_modules").path, isDirectory: true)
        #expect(loose.verdict == .reviewFirst, "a name alone never earns safe to clear")
    }

    @Test("Build folder names are safe to clear only in a project, never inside an app's own data")
    func buildNamesNeedAProject() throws {
        let tree = try TemporaryTree()
        try tree.file("Developer/web/package.json", bytes: 100)
        try tree.directory("Developer/web/dist")
        try tree.file("Developer/rust/Cargo.toml", bytes: 100)
        try tree.directory("Developer/rust/target")
        try tree.directory("Documents/Thesis/build")
        try tree.file("Library/Application Support/Tool/package.json", bytes: 100)
        try tree.directory("Library/Application Support/Tool/node_modules")
        try tree.file("Applications/Thing.app/Contents/Resources/package.json", bytes: 100)
        try tree.directory("Applications/Thing.app/Contents/Resources/node_modules")
        try tree.file("Developer/web/build", bytes: 100)
        let subject = try classifier(home: tree.path)
        func verdict(_ path: String, directory: Bool = true) -> Verdict {
            subject.classify(path: tree.root.appendingPathComponent(path).path, isDirectory: directory).verdict
        }

        #expect(verdict("Developer/web/dist") == .safeToClear)
        #expect(verdict("Developer/rust/target") == .safeToClear)
        #expect(verdict("Documents/Thesis/build") != .safeToClear, "a thesis chapter called build is somebody's work")
        #expect(verdict("Library/Application Support/Tool/node_modules") != .safeToClear)
        #expect(verdict("Applications/Thing.app/Contents/Resources/node_modules") != .safeToClear)
        #expect(
            subject.classify(path: tree.root.appendingPathComponent("Developer/web/build").path, isDirectory: false).kind
                != "Build output",
            "a file named build is not a build folder"
        )
    }

    @Test("A folder called Caches is safe to clear only in the recognised cache location")
    func cachesByNameIsNotEnough() throws {
        let subject = try classifier(home: "/Users/tester")

        #expect(subject.classify(path: "/Users/tester/Library/Caches/com.app", isDirectory: true).verdict == .safeToClear)
        #expect(
            subject.classify(path: "/Users/tester/Documents/Project/Caches", isDirectory: true).verdict != .safeToClear
        )
        #expect(
            subject.classify(
                path: "/Users/tester/Library/Containers/com.app/Data/Library/Caches",
                isDirectory: true
            ).verdict != .safeToClear
        )
    }

    @Test("Unrecognised folders are assumed to be the user's own")
    func defaultsToYourData() throws {
        let subject = try classifier(home: "/Users/tester")

        let unknown = subject.classify(path: "/Users/tester/Thesis", isDirectory: true)
        #expect(unknown.verdict == .yourData, "guessing 'safe to clear' here would risk somebody's work")
    }

    @Test("Category follows the folder's place in home")
    func categoryFollowsLocation() throws {
        let subject = try classifier(home: "/Users/tester")

        #expect(subject.classify(path: "/Users/tester/Movies/Trip", isDirectory: true).category == .media)
        #expect(subject.classify(path: "/Users/tester/Pictures/Photos Library", isDirectory: true).category == .photos)
        #expect(subject.classify(path: "/Users/tester/Downloads", isDirectory: true).category == .downloads)
        #expect(subject.classify(path: "/Users/tester/Documents/Tax", isDirectory: true).category == .docs)
        #expect(subject.classify(path: "/Users/tester/Library", isDirectory: true).category == .cache)
        #expect(subject.classify(path: "/Users/tester/Developer", isDirectory: true).category == .dev)
    }

    @Test("A folder called Movies inside a project is not treated as the user's media folder")
    func onlyTopLevelNamesCount() throws {
        let subject = try classifier(home: "/Users/tester")

        let nested = subject.classify(path: "/Users/tester/Developer/app/Movies", isDirectory: true)
        #expect(nested.category == .dev, "it sits under Developer, so it is code, not media")
    }

    @Test("A git repository is the user's data, however big it gets")
    func protectsGitHistory() throws {
        let subject = try classifier(home: "/Users/tester")

        let git = subject.classify(path: "/Users/tester/Developer/app/.git", isDirectory: true)
        #expect(git.verdict == .yourData)
        #expect(git.reason.contains("history"))
    }

    @Test("Home itself is described, not judged")
    func describesHome() throws {
        let subject = try classifier(home: "/Users/tester")

        let home = subject.classify(path: "/Users/tester", isDirectory: true)
        #expect(home.kind == "Home folder")
        #expect(home.verdict == .yourData)
    }
}
