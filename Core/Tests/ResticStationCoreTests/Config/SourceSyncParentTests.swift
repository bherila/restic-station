import Foundation
import Testing
@testable import ResticStationCore

/// Each sync backup adds a per-operation vault path, so restic's own
/// host-and-paths match never finds a parent and re-reads the whole scope.
@Suite("Sync backup parent snapshot")
struct SourceSyncParentTests {
    static func snapshot(_ id: Character, host: String, time: String, paths: [String]) -> String {
        let pathList = paths.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"id\":\"\(String(repeating: id, count: 64))\",\"short_id\":\"\(String(repeating: id, count: 8))\","
            + "\"time\":\"\(time)\",\"paths\":[\(pathList)],\"hostname\":\"\(host)\",\"username\":\"someone\"}"
    }

    @Test("the newest snapshot of this host that covers every configured source")
    func newestCoveringSnapshot() throws {
        let sources = ["/Users/someone/proj", "/Users/someone/.ssh"]
        let json = "[" + [
            Self.snapshot("a", host: "laptop", time: "2026-10-01T00:00:00Z", paths: sources),
            // A sync snapshot also carries its vault; it still covers the sources.
            Self.snapshot("b", host: "laptop", time: "2026-10-02T00:00:00Z", paths: sources + ["/Users/someone/proj/.restic-station-sync-x/vault"]),
            // Newer, but missing a source: restic would re-read that source.
            Self.snapshot("c", host: "laptop", time: "2026-10-03T00:00:00Z", paths: ["/Users/someone/proj"]),
            // Newer, but another computer's.
            Self.snapshot("d", host: "desktop", time: "2026-10-04T00:00:00Z", paths: sources),
        ].joined(separator: ",") + "]"
        let snapshots = try parseSnapshots(Data(json.utf8))
        #expect(EngineSourceSyncBackups.parent(among: snapshots, host: "laptop", sources: sources) == String(repeating: "b", count: 64))
        #expect(EngineSourceSyncBackups.parent(among: snapshots, host: "server", sources: sources) == nil)
        #expect(EngineSourceSyncBackups.parent(among: [], host: "laptop", sources: sources) == nil)
    }
}

@Suite("Sync hash cache")
struct SyncHashCacheTests {
    static let stamp: [Int64] = [1, 2, 3, 0o100644, 1_600_000_000, 0, 1_600_000_000, 0]

    @Test("a cache from another root or version is ignored")
    func foreignCacheIgnored() {
        let entry = SyncHashCache.Entry(stamp: Self.stamp, digest: String(repeating: "a", count: 64))
        let own = SyncHashCache(rootIdentity: "1:2:3", entries: ["note": entry])
        #expect(SyncHashCache.Session(previous: own, rootIdentity: "1:2:3").reuse("note", stamp: Self.stamp) == entry.digest)
        #expect(SyncHashCache.Session(previous: own, rootIdentity: "1:2:4").reuse("note", stamp: Self.stamp) == nil)
        var newer = own; newer.version = 2
        #expect(SyncHashCache.Session(previous: newer, rootIdentity: "1:2:3").reuse("note", stamp: Self.stamp) == nil)
    }
}
