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

@Suite("Sync backup mirrors")
struct SourceSyncMirrorTests {
    static func set(mirrors: [String]) -> (BackupSet, [Destination]) {
        let primary = Destination(id: UUID(), label: "Archive", repoURL: "/tmp/primary", isPrimary: true)
        let others = mirrors.map { Destination(id: UUID(), label: $0, repoURL: "/tmp/\($0)", isPrimary: false) }
        var set = BackupSet(id: UUID(), name: "Work", sources: ["/Users/someone/work"], schedule: .daily(hour: 2, minute: 0), destinations: [primary] + others)
        set.syncFolders = []
        return (set, [primary] + others)
    }

    @Test("a mirror with no successful copy is named; a copied one is not; the primary never is")
    func classification() {
        let (set, d) = Self.set(mirrors: ["Offsite", "Disk", "NAS"])
        let children = [
            SetRunChild(runId: "b", kind: .backup, destId: d[0].id, status: .success),
            SetRunChild(runId: "c1", kind: .copy, destId: d[2].id, status: .success),
            SetRunChild(runId: "c2", kind: .copy, destId: d[3].id, status: .failed),
            // Offsite was unreachable: the engine records no run for it at all.
        ]
        let engine = EngineSourceSyncBackups.warningsForTesting(set, children: children)
        #expect(engine.count == 2)
        #expect(engine[0].contains("\"Offsite\"") && engine[1].contains("\"NAS\""))
        #expect(!engine.joined().contains("Disk") && !engine.joined().contains("Archive"))
        // A copy that only warned is not a complete copy either.
        let warned = [SetRunChild(runId: "c", kind: .copy, destId: d[2].id, status: .warning)]
        #expect(EngineSourceSyncBackups.warningsForTesting(set, children: warned).contains { $0.contains("\"Disk\"") })
        // No mirrors, no warnings.
        let (single, e) = Self.set(mirrors: [])
        #expect(EngineSourceSyncBackups.warningsForTesting(single, children: [SetRunChild(runId: "b", kind: .backup, destId: e[0].id, status: .success)]).isEmpty)
    }
}

@Suite("Sync primary proof")
struct SourceSyncPrimaryProofTests {
    @Test("only the primary's own runs decide the proof; a failed mirror copy never does")
    func primaryOnly() {
        let (_, d) = SourceSyncMirrorTests.set(mirrors: ["Offsite"])
        let primary = d[0], mirror = d[1]
        let backup = SetRunChild(runId: "b", kind: .backup, destId: primary.id, status: .success)
        let failedCopy = SetRunChild(runId: "c", kind: .copy, destId: mirror.id, status: .failed)
        #expect(EngineSourceSyncBackups.primaryBackup([backup, failedCopy], primary: primary)?.runId == "b")
        #expect(EngineSourceSyncBackups.primaryBackup([failedCopy, backup], primary: primary)?.runId == "b")
        // The primary's own backup must have succeeded, exactly; a warning
        // (some file unreadable) is not a proof.
        for status in [RunStatus.failed, .warning, .skipped] {
            let weak = SetRunChild(runId: "b", kind: .backup, destId: primary.id, status: status)
            #expect(EngineSourceSyncBackups.primaryBackup([weak, failedCopy], primary: primary) == nil, "\(status)")
        }
        // Any other run against the primary failing also refuses.
        let failedPurge = SetRunChild(runId: "p", kind: .prune, destId: primary.id, status: .failed)
        #expect(EngineSourceSyncBackups.primaryBackup([backup, failedPurge], primary: primary) == nil)
        // No backup of the primary at all is no proof, however the mirror did.
        let goodCopy = SetRunChild(runId: "c", kind: .copy, destId: mirror.id, status: .success)
        #expect(EngineSourceSyncBackups.primaryBackup([goodCopy], primary: primary) == nil)
        #expect(EngineSourceSyncBackups.primaryBackup([], primary: primary) == nil)
    }
}

@Suite("Sync repository path while absent")
struct SyncProspectiveDirectoryTests {
    @Test("an existing path resolves as before; a missing tail is appended to the deepest existing ancestor")
    func resolvesThroughExistingAncestor() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try SourceSyncFilesystem.resolvedDirectory(root.path)
        #expect(try SourceSyncFilesystem.prospectiveDirectory(root.path) == real)
        #expect(try SourceSyncFilesystem.prospectiveDirectory(root.appendingPathComponent("disk/repo").path) == real + "/disk/repo")
        // Through a symlinked ancestor, the tail lands where the link points.
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: target)
        #expect(try SourceSyncFilesystem.prospectiveDirectory(root.appendingPathComponent("link/gone/repo").path)
                == (try SourceSyncFilesystem.resolvedDirectory(target.path)) + "/gone/repo")
    }

    @Test("a dangling symlink, or a non-directory in the way, refuses rather than being skipped")
    func failsClosed() throws {
        let root = try syncTemporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A link whose target does not exist yet could point into a sync
        // folder once it appears, so it cannot be read as "absent".
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("nowhere"))
        #expect(throws: SourceSyncError.self) { try SourceSyncFilesystem.prospectiveDirectory(root.appendingPathComponent("dangling/repo").path) }
        #expect(throws: SourceSyncError.self) { try SourceSyncFilesystem.prospectiveDirectory("relative/path") }
        // The prospective path of a missing repository inside a folder is
        // still inside it, so the overlap check still catches it.
        let notes = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let inside = try SourceSyncFilesystem.prospectiveDirectory(notes.appendingPathComponent("not-yet/repo").path)
        #expect(SourceSyncGroup.contains(try SourceSyncFilesystem.resolvedDirectory(notes.path), inside))
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
