import Foundation

/// Finds the shipped `suspects.json`.
///
/// This does the job of SwiftPM's generated `Bundle.module`, deliberately by hand: that accessor calls
/// `fatalError` when the resource bundle is missing, which would turn a packaging mistake into a
/// crashing daemon. Here a missing catalog is an error the caller can report, and there is more than
/// one place to look because the same library is linked into an app bundle and into a bare executable.
enum CatalogLocation {
    static let resourceName = "suspects"
    static let resourceExtension = "json"

    /// Where the catalog is, or nil with the list of places that were searched.
    static func find() -> (url: URL?, searched: [String]) {
        var searched: [String] = []

        for directory in searchDirectories() {
            // Inside a SwiftPM resource bundle, e.g. `Jaaga_JaagaCore.bundle/suspects.json`.
            if let bundled = resourceBundle(in: directory) {
                let candidate = bundled.appendingPathComponent("\(resourceName).\(resourceExtension)")
                searched.append(candidate.path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return (candidate, searched)
                }
            }
            // Or loose in the directory, which is what a bare `swift build` products folder looks like
            // once the bundle has been unpacked, and what a custom layout might do.
            let loose = directory.appendingPathComponent("\(resourceName).\(resourceExtension)")
            searched.append(loose.path)
            if FileManager.default.fileExists(atPath: loose.path) {
                return (loose, searched)
            }
        }

        return (nil, searched)
    }

    private static func searchDirectories() -> [URL] {
        var directories: [URL] = []

        // The app bundle's Resources, which is where `Scripts/bundle-app.sh` puts it. `Bundle.main`
        // resolves to the enclosing .app for the daemon too, because it sits in Contents/MacOS.
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        directories.append(Bundle.main.bundleURL)

        // A `swift build` products directory: the bundle sits beside the executable.
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            directories.append(executable)
        }
        directories.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())

        // Whatever bundle this library ended up in, for a framework or test-host layout.
        let own = Bundle(for: BundleToken.self)
        if let resources = own.resourceURL { directories.append(resources) }
        directories.append(own.bundleURL)

        // The directory *containing* those bundles. Under `swift test` the resource bundle sits in the
        // products directory beside `JaagaPackageTests.xctest` rather than inside it, so without this
        // the catalog is invisible to the tests that check it.
        directories.append(own.bundleURL.deletingLastPathComponent())
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())

        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func resourceBundle(in directory: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        // SwiftPM names it "<package>_<target>.bundle", and the package name is not ours to assume.
        guard let name = entries.first(where: { $0.hasSuffix("_JaagaCore.bundle") }) else { return nil }
        return directory.appendingPathComponent(name)
    }
}

/// Only here so `Bundle(for:)` has a class in this module to point at.
private final class BundleToken {}
