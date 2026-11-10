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
    @Test("the outcome is read through the primary alone, whatever the group status says")
    func outcomeIgnoresGroupStatus() {
        let (set, d) = SourceSyncMirrorTests.set(mirrors: ["Offsite"])
        let backup = SetRunChild(runId: "b", kind: .backup, destId: d[0].id, status: .success)
        let failedCopy = SetRunChild(runId: "c", kind: .copy, destId: d[1].id, status: .failed)
        // A failed mirror copy makes the group's status `failed`; the proof stands.
        let proven = EngineSourceSyncBackups.provenOnPrimary(.completed(status: .failed, groupId: "g", children: [backup, failedCopy]), set: set, primary: d[0])
        #expect(proven?.backup.runId == "b")
        #expect(proven?.warnings.count == 1 && proven?.warnings.first?.contains("\"Offsite\"") == true)
        // A group that claims success cannot make a failed primary backup one.
        let failedBackup = SetRunChild(runId: "b", kind: .backup, destId: d[0].id, status: .failed)
        #expect(EngineSourceSyncBackups.provenOnPrimary(.completed(status: .success, groupId: "g", children: [failedBackup]), set: set, primary: d[0]) == nil)
        // Anything but a completed run is no proof.
        #expect(EngineSourceSyncBackups.provenOnPrimary(.skipped, set: set, primary: d[0]) == nil)
        #expect(EngineSourceSyncBackups.provenOnPrimary(.retryable(reason: "x"), set: set, primary: d[0]) == nil)
        #expect(EngineSourceSyncBackups.provenOnPrimary(.infrastructureFailure(reason: "x"), set: set, primary: d[0]) == nil)
    }

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

@Suite("Sync free space estimate")
struct SyncSpaceTests {
    static func file(_ bytes: UInt64) -> SyncItem { SyncItem(digest: String(repeating: "a", count: 64), bytes: bytes) }
    static func plan(requiresProtection: Bool) -> SourceSyncPlan {
        let mib: UInt64 = 1 << 20
        var local = ["new-here": file(10 * mib)], peer = ["new-there": file(20 * mib)]
        var changes = [
            SyncChange(path: "new-here", action: .copyToPeer, local: local["new-here"], peer: nil),
            SyncChange(path: "new-there", action: .copyToLocal, local: nil, peer: peer["new-there"]),
        ]
        if requiresProtection {
            local["edited"] = file(5 * mib); peer["edited"] = file(7 * mib)
            changes.append(SyncChange(path: "edited", action: .copyToLocal, local: local["edited"], peer: peer["edited"]))
        }
        return SourceSyncPlan(groupId: UUID(), groupFingerprint: "x", local: .init(rootIdentity: "a", items: local),
                              peer: .init(rootIdentity: "b", items: peer), baselineGeneration: nil, changes: changes)
    }

    @Test("what each place needs: exports plus arrivals beside a folder, the vault and its restores at the coordinator")
    func needs() {
        let mib: UInt64 = 1 << 20
        // Without protection: vault is the exports (10 + 20), held with one restore.
        let plain = SyncSpace.need(for: Self.plan(requiresProtection: false))
        #expect(plain.coordinator == 2 * 30 * mib)
        #expect(plain.local == 10 * mib + 20 * mib, "exports its new file, receives the other's")
        #expect(plain.peer == 20 * mib + 10 * mib)
        // With protection the replaced versions join the vault, and two restores stay until cleanup.
        let protected = SyncSpace.need(for: Self.plan(requiresProtection: true))
        #expect(protected.coordinator == 3 * (10 + 5 + 20 + 7) * mib)
        #expect(protected.local == (10 + 5) * mib + (20 + 7) * mib)
        #expect(protected.peer == (20 + 7) * mib + 10 * mib)
    }

    @Test("a conflict adds nothing to what a plan needs")
    func conflictsAreFree() {
        let mib: UInt64 = 1 << 20
        var plan = Self.plan(requiresProtection: false)
        let base = SyncSpace.need(for: plan)
        plan.local.items["fight"] = Self.file(500 * mib); plan.peer.items["fight"] = Self.file(600 * mib)
        plan.changes.append(SyncChange(path: "fight", action: .conflict, local: plan.local.items["fight"], peer: plan.peer.items["fight"]))
        #expect(SyncSpace.need(for: plan) == base)
    }

    @Test("free space is read from statvfs figures only when they can be trusted")
    func trustedFigures() {
        // Ordinary: 1000 free fragments of 4096 bytes.
        #expect(SyncSpace.free(available: 1000, fragment: 4096, blocks: 5000) == 4_096_000)
        // A full volume really is full: blocks exist and none are available.
        #expect(SyncSpace.free(available: 0, fragment: 4096, blocks: 5000) == 0)
        // Filesystems that report nothing (some FUSE and network mounts) say nothing, which is unknown.
        #expect(SyncSpace.free(available: 0, fragment: 4096, blocks: 0) == nil)
        #expect(SyncSpace.free(available: 123, fragment: 0, blocks: 5000) == nil)
        // A sentinel that would overflow is nonsense, not a crash.
        #expect(SyncSpace.free(available: UInt64.max, fragment: 4096, blocks: 5000) == nil)
        // The real call reports something for a real directory.
        #expect(SyncSpace.reading(atPath: NSTemporaryDirectory()).volume != nil)
    }

    @Test("a peer is assumed to read 32 MiB unless it says otherwise")
    func advertisedLimit() {
        #expect(SyncEndpointRequest.limit(peerAdvertised: nil) == 32 * 1024 * 1024)
        #expect(SyncEndpointRequest.limit(peerAdvertised: 64 * 1024 * 1024) == 64 * 1024 * 1024)
        #expect(SyncEndpointRequest.limit(peerAdvertised: 4096) == 4096)
    }

    @Test("directories, links and removals need no space, so an empty plan needs none")
    func nothingToCopy() {
        let dir = SyncItem(kind: .directory, digest: "", mode: 0o755)
        let plan = SourceSyncPlan(groupId: UUID(), groupFingerprint: "x", local: .init(rootIdentity: "a", items: ["d": dir]),
                                  peer: .init(rootIdentity: "b", items: [:]), baselineGeneration: nil,
                                  changes: [SyncChange(path: "d", action: .copyToPeer, local: dir, peer: nil)])
        #expect(SyncSpace.need(for: plan) == .init(coordinator: 0, local: 0, peer: 0))
        #expect(SyncSpace.required(0) == 0)
        #expect(SyncSpace.shortfalls(.init(coordinator: 0, local: 0, peer: 0), coordinator: .init(free: 0, volume: 1), local: .init(free: 0, volume: 1), peer: .init(free: 0), peerIsRemote: true).isEmpty)
    }

    @Test("slack is ten percent and 64 MiB; unknown is not short; the other computer is named when remote")
    func slackAndWording() {
        let mib: UInt64 = 1 << 20
        #expect(SyncSpace.required(100 * mib) == 110 * mib + 64 * mib)
        let need = SyncSpace.Need(coordinator: 100 * mib, local: 100 * mib, peer: 100 * mib)
        let unknown = SyncSpace.Reading()
        #expect(SyncSpace.shortfalls(need, coordinator: unknown, local: unknown, peer: unknown, peerIsRemote: true).isEmpty)
        // Exactly enough is enough; one byte under is not.
        let exact = SyncSpace.required(100 * mib)
        func readings(_ free: UInt64) -> (SyncSpace.Reading, SyncSpace.Reading, SyncSpace.Reading) {
            (.init(free: free, volume: 1), .init(free: free, volume: 2), .init(free: free, volume: 3))
        }
        var r = readings(exact)
        #expect(SyncSpace.shortfalls(need, coordinator: r.0, local: r.1, peer: r.2, peerIsRemote: true).isEmpty)
        r = readings(exact - 1)
        let lines = SyncSpace.shortfalls(need, coordinator: r.0, local: r.1, peer: r.2, peerIsRemote: true)
        #expect(lines.count == 3 && lines[2].hasPrefix("beside the other computer's folder"))
        // Two places on a volume that disagree about free space (quotas): the smaller figure decides.
        let quota = SyncSpace.shortfalls(need, coordinator: .init(free: exact * 4, volume: 7), local: .init(free: exact - 1, volume: 7), peer: .init(free: exact * 4, volume: 9), peerIsRemote: true)
        #expect(quota.count == 1 && quota[0].hasPrefix("this computer's Restic Station data and beside this computer's folder"), "\(quota)")
        // The same volume number on the other computer is a coincidence, not the same volume.
        let remote = SyncSpace.shortfalls(need, coordinator: .init(free: exact, volume: 7), local: .init(free: exact, volume: 8), peer: .init(free: exact, volume: 7), peerIsRemote: true)
        #expect(remote.isEmpty, "\(remote)")
        // Two places that really share a volume add up: enough for each, not for both.
        let shared = SyncSpace.shortfalls(need, coordinator: .init(free: exact, volume: 7), local: .init(free: exact, volume: 7), peer: .init(free: exact, volume: 9), peerIsRemote: true)
        #expect(shared.count == 1 && shared[0].hasPrefix("this computer's Restic Station data and beside this computer's folder"))
        #expect(SyncSpace.format(174 * mib) == "174.0 MiB" && SyncSpace.format(3 << 30) == "3.0 GiB" && SyncSpace.format(512) == "512 B")
    }
}

@Suite("Sync SSH request size")
struct SyncRequestSizeTests {
    @Test("a 150,000-file prepare request fits, where the old shape (pretty, inventory twice) passed 32 MiB")
    func largeInventoryFits() throws {
        let digest = String(repeating: "a", count: 64)
        var items: [String: SyncItem] = [:]
        for index in 0..<150_000 { items["projects/some/deeply/nested/folder/file-number-\(index).txt"] = SyncItem(digest: digest, bytes: 4096, mode: 0o644) }
        let group = SourceSyncGroup(name: "Notes", localPath: "/tmp/a", peer: .init(path: "/tmp/b"), coordinatorMachineId: "laptop")
        let inventory = SyncInventory(rootIdentity: "1:2:3", items: items)
        var request = SyncEndpointRequest(action: .prepare, group: group, root: "/tmp/a", operationId: UUID(), expected: inventory)
        // What the coordinator sends now: the inventory once, compactly.
        let now = try SyncEndpointRequest.encode(request)
        #expect(now.count < SyncEndpointRequest.maximumEncodedBytes)
        #expect(now.count < 32 * 1024 * 1024)
        // What it sent before: the same inventory again as protectedItems, pretty-printed.
        request.protectedItems = items
        let before = try ConfigStore.makeEncoder().encode(request)
        #expect(before.count > 32 * 1024 * 1024, "the old shape should have been over the old limit")
        #expect(now.count * 5 < before.count * 2, "now \(now.count) vs before \(before.count)")
        // The peer decodes the compact form with its usual decoder.
        request.protectedItems = [:]
        let decoded = try ConfigStore.makeDecoder().decode(SyncEndpointRequest.self, from: try SyncEndpointRequest.encode(request))
        #expect(decoded.expected?.items.count == 150_000 && decoded.operationId == request.operationId)
    }

    @Test("a request over the limit is refused before it is sent, by name; an older peer's smaller limit is explained")
    func oversizeRefused() {
        #expect(throws: Never.self) { try SourceSyncClient.requireSize(SyncEndpointRequest.maximumEncodedBytes) }
        let error = #expect(throws: SourceSyncError.self) { try SourceSyncClient.requireSize(SyncEndpointRequest.maximumEncodedBytes + 1) }
        #expect(error?.description.contains("too many entries") == true && error?.description.contains("64.0 MiB") == true)
        let older = #expect(throws: SourceSyncError.self) {
            try SourceSyncClient.requireSize(SyncEndpointRequest.legacyMaximumEncodedBytes + 1, limit: SyncEndpointRequest.legacyMaximumEncodedBytes, peerIsOlder: true)
        }
        #expect(older?.description.contains("is older and reads at most 32.0 MiB") == true && older?.description.contains("raises that to 64.0 MiB") == true)
    }

    /// Records what the client sends over SSH, and answers like a peer.
    struct RecordingRunner: ProcessRunning {
        final class Sent: @unchecked Sendable {
            private let lock = NSLock(); private var value: [Data] = []
            func add(_ data: Data) { lock.lock(); value.append(data); lock.unlock() }
            var all: [Data] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let sent: Sent
        func run(_ argv: [String], env: [String: String]?, stdin: Data?, currentDirectory: String?, onStdoutLine: (@Sendable (String) -> Void)?, onStderrLine: (@Sendable (String) -> Void)?, timeout: TimeInterval?) async throws -> ProcessResult {
            sent.add(stdin ?? Data())
            struct Envelope: Encodable { var ok = true; var data: SyncEndpointReply }
            let reply = SyncEndpointReply(inventory: SyncInventory(rootIdentity: "1:2:3", items: [:]))
            return ProcessResult(exitCode: 0, stdout: try ConfigStore.makeEncoder().encode(Envelope(data: reply)), stderr: Data())
        }
    }

    @Test("the client sends the compact request over SSH, and refuses one over the limit without sending it")
    func clientSendsCompact() async throws {
        let group = SourceSyncGroup(name: "Notes", localPath: "/tmp/a", peer: .init(path: "/tmp/b", sshTarget: "user@host"), coordinatorMachineId: "laptop")
        var items: [String: SyncItem] = [:]
        for index in 0..<200 { items["folder/file-\(index)"] = SyncItem(digest: String(repeating: "b", count: 64), bytes: 1) }
        let request = SyncEndpointRequest(action: .prepare, group: group, root: "/tmp/b", operationId: UUID(), expected: SyncInventory(rootIdentity: "1:2:3", items: items))
        let sent = RecordingRunner.Sent()
        let client = SourceSyncClient(runner: RecordingRunner(sent: sent))
        _ = try await client.request(request, at: group.peer)
        let body = try #require(sent.all.first)
        #expect(!body.contains(UInt8(ascii: "\n")), "compact: no line breaks")
        #expect(String(decoding: body, as: UTF8.self).contains("\"folder/file-0\""), "slashes are not escaped")
        #expect(body == (try SyncEndpointRequest.encode(request)))
        // Oversize is refused by name by the same call, and nothing is sent.
        let before = sent.all.count
        let limited = await #expect(throws: SourceSyncError.self) {
            try await SyncEndpointRequest.$limitOverride.withValue(1024) { try await client.request(request, at: group.peer) }
        }
        #expect(limited?.description.contains("too many entries") == true)
        #expect(sent.all.count == before, "nothing reached the runner")
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
        // A file where a folder must be is not an absent folder.
        try Data("x".utf8).write(to: root.appendingPathComponent("plainfile"))
        #expect(throws: SourceSyncError.self) { try SourceSyncFilesystem.prospectiveDirectory(root.appendingPathComponent("plainfile/repo").path) }
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
