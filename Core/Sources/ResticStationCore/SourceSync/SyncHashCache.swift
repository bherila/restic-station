import Foundation

/// File digests from a live root's previous inventory, so an unchanged file
/// is not read again by every step of one synchronization.
///
/// A digest is reused only when the file's whole stat stamp is identical:
/// device, inode, size, mode, modification time and change time. Any write
/// or rename moves the change time, which an ordinary user cannot set back,
/// so a stale digest needs a clock stepped backwards or root. Git and restic
/// rely on the same property.
///
/// A file whose times are within ``settleSeconds`` of the scan is never
/// recorded ("racily clean" in git's terms): on a filesystem with coarse
/// timestamps, a write in that same tick would not change the stamp.
///
/// The cache only saves reading. A missing, unreadable or foreign cache
/// means every file is hashed, exactly as without one.
public struct SyncHashCache: Codable, Equatable, Sendable {
    public var version = 1
    var rootIdentity: String
    var entries: [String: Entry]

    struct Entry: Codable, Equatable, Sendable {
        var stamp: [Int64]
        var digest: String
    }

    @TaskLocal static var settleSeconds: Int64 = 2

    /// One scan: answers from the previous entries and records this scan's,
    /// so files that disappeared drop out of the next cache.
    public final class Session {
        private let previous: [String: Entry]
        private let rootIdentity: String
        private let settledBefore: Int64
        private var entries: [String: Entry] = [:]

        init(previous: SyncHashCache?, rootIdentity: String, now: Date = Date()) {
            let usable = previous.flatMap { $0.version == 1 && $0.rootIdentity == rootIdentity ? $0 : nil }
            self.previous = usable?.entries ?? [:]
            self.rootIdentity = rootIdentity
            settledBefore = Int64(now.timeIntervalSince1970) - SyncHashCache.settleSeconds
        }

        func reuse(_ path: String, stamp: [Int64]) -> String? {
            guard let hit = previous[path], hit.stamp == stamp else { return nil }
            entries[path] = hit
            return hit.digest
        }

        func record(_ path: String, stamp: [Int64], digest: String) {
            // SourceSyncFilesystem.stamp: [dev, ino, size, mode, mtime s, ns, ctime s, ns].
            guard stamp.count == 8, stamp[4] < settledBefore, stamp[6] < settledBefore else { return }
            entries[path] = Entry(stamp: stamp, digest: digest)
        }

        var result: SyncHashCache { SyncHashCache(rootIdentity: rootIdentity, entries: entries) }
    }
}
