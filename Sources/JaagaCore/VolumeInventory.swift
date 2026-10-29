import Foundation
import JaagaProtocol

/// Lists the volumes the user can browse: the startup disk, plus anything mounted under `/Volumes`.
///
/// Jaaga does not aggregate across volumes — a folder's size is always the size it occupies on its
/// own disk. This inventory exists so the sidebar can offer them as separate places to look.
public struct VolumeInventory: Sendable {
    public init() {}

    public func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey,
        ]

        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var result: [VolumeInfo] = []
        for url in mounted {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsBrowsable ?? true else { continue }
            // Network shares have no meaningful "free space to reclaim" story, and scanning one over
            // the wire would be painfully slow, so they stay out of the list.
            guard values.volumeIsLocal ?? true else { continue }
            guard let total = values.volumeTotalCapacity, total > 0 else { continue }

            let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
            // `ForImportantUsage` is what the Finder shows: it counts space macOS would purge
            // (snapshots, purgeable caches) as available, which is what the user can actually use.
            let free = values.volumeAvailableCapacityForImportantUsage
                .map { Int64($0) } ?? Int64(values.volumeAvailableCapacity ?? 0)

            result.append(
                VolumeInfo(
                    name: values.volumeName ?? url.lastPathComponent,
                    mountPath: url.path,
                    totalBytes: Int64(total),
                    freeBytes: free,
                    isStartupDisk: isRoot,
                    isInternal: values.volumeIsInternal ?? isRoot,
                    isRemovable: values.volumeIsRemovable ?? false
                )
            )
        }

        // Startup disk first, then internal disks, then the rest — the order the sidebar wants.
        return result.sorted { left, right in
            if left.isStartupDisk != right.isStartupDisk { return left.isStartupDisk }
            if left.isInternal != right.isInternal { return left.isInternal }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    public func startupVolume() -> VolumeInfo? {
        volumes().first { $0.isStartupDisk }
    }

    /// The volume a path sits on, so a folder's share of "its" disk is measured against the right one.
    public func volume(containing path: String) -> VolumeInfo? {
        let candidates = volumes()
        var best: VolumeInfo?
        for volume in candidates where path == volume.mountPath || path.hasPrefix(volume.mountPath == "/" ? "/" : volume.mountPath + "/") {
            // Longest matching mount point wins, so `/Volumes/Archive/x` is not attributed to `/`.
            if best == nil || volume.mountPath.count > best!.mountPath.count {
                best = volume
            }
        }
        return best
    }
}
