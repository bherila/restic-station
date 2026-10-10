import Foundation
import Testing
@testable import ResticStationCore

/// #80: `snapshots list` and `retention preview`. Both are read-only, so
/// most assertions are about what they must not do — spawn anything but
/// their one query, carry `--prune`, or write a run record or state.
@Suite struct RepositoryQueryTests {
    typealias T = BackupEngineTests

    static func snapshot(_ id: String, _ time: String, tags: [String]? = nil) -> String {
        let tagJSON = tags.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        return "{\"id\":\"\(id)\",\"short_id\":\"\(id.prefix(8))\",\"time\":\"\(time)\","
            + "\"paths\":[\"/Users/test/proj\"],\"hostname\":\"example-mac\",\"username\":\"test\","
            + "\"tags\":\(tagJSON)}"
    }

    static let idA = String(repeating: "a", count: 64)
    static let idB = String(repeating: "b", count: 64)
    static let idC = String(repeating: "c", count: 64)

    /// Three snapshots out of order, two sharing a timestamp.
    static var snapshotsJSON: String {
        "[" + [
            snapshot(idB, "2026-07-01T10:00:00Z"),
            snapshot(idC, "2026-07-03T10:00:00Z", tags: ["nightly"]),
            snapshot(idA, "2026-07-01T10:00:00Z"),
        ].joined(separator: ",") + "]"
    }

    /// One policy group: C kept as the last snapshot, A and B removed.
    static var forgetJSON: String {
        "[{\"tags\":null,\"host\":\"example-mac\",\"paths\":[\"/Users/test/proj\"],"
            + "\"keep\":[\(snapshot(idC, "2026-07-03T10:00:00Z"))],"
            + "\"remove\":[\(snapshot(idA, "2026-07-01T10:00:00Z")),\(snapshot(idB, "2026-07-01T10:00:00Z"))],"
            + "\"reasons\":[{\"snapshot\":\(snapshot(idC, "2026-07-03T10:00:00Z")),\"matches\":[\"last snapshot\"]}]}]"
    }

    static func previewArgv(_ repo: String) -> [String] {
        ["-r", repo, "forget", "--json", "--keep-last", "3", "--dry-run"]
    }

    // MARK: - snapshots list

    @Test("snapshots list: one `snapshots --json`, newest first with ties by id, limited, nothing recorded")
    func listsNewestFirst() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"], dest: T.primaryId, stdoutLines: [Self.snapshotsJSON]
        )

        let listing = try await env.engine.listSnapshots(env.set, destination: env.primary, limit: 2)

        #expect(env.resticArgvs == [[env.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"]])
        #expect(listing.totalCount == 3)
        #expect(listing.limit == 2)
        let ids = listing.snapshots.map { $0.id }
        #expect(ids == [Self.idC, Self.idA])
        #expect(listing.snapshots[0].tags == ["nightly"])
        #expect(BackupDryRunTests.writtenFiles(env) == [])
        #expect(env.indexEntries.isEmpty)
        #expect(env.repoStatus(env.primary) == nil)
    }

    /// Listing takes no set lock, so it answers during a long backup.
    @Test("snapshots list answers while another operation holds the set lock")
    func listIgnoresTheSetLock() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let holder = FileLock(path: env.paths.setLockFile(setId: T.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }
        env.fake.script = T.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"], dest: T.primaryId, stdoutLines: [Self.snapshotsJSON]
        )

        let listing = try await env.engine.listSnapshots(env.set, destination: env.primary, limit: 50)

        #expect(listing.totalCount == 3)
    }

    @Test("snapshots list of an offline destination refuses before restic, recording nothing")
    func listOffline() async throws {
        let env = T.makeEnv(script: [], primaryReachable: false)
        defer { env.cleanUp() }

        await #expect(throws: RepositoryQueryError.offline(
            destinationId: T.primaryId, reason: "repository path does not exist"
        )) {
            try await env.engine.listSnapshots(env.set, destination: env.primary, limit: 50)
        }
        #expect(env.fake.invocations.isEmpty)
        #expect(BackupDryRunTests.writtenFiles(env) == [])
    }

    @Test("the JSON document is found past a stderr warning, and its absence is an error")
    func jsonDocumentExtraction() throws {
        let data = try BackupEngine.jsonDocument(in: Self.snapshotsJSON + "\nwarning: something on stderr\n")
        #expect(String(decoding: data, as: UTF8.self) == Self.snapshotsJSON)
        #expect(throws: (any Error).self) {
            _ = try BackupEngine.jsonDocument(in: "Fatal: nothing here\n")
        }
    }

    // MARK: - retention preview

    @Test("retention preview: forget --dry-run with the policy, never --prune, nothing recorded")
    func previewsWithoutPruning() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(Self.previewArgv(env.primary.repoURL), dest: T.primaryId, stdoutLines: [Self.forgetJSON])

        let preview = try await env.engine.previewRetention(env.set, destination: env.primary)

        #expect(env.resticArgvs == [[env.resticPath] + Self.previewArgv(env.primary.repoURL)])
        #expect(!env.resticArgvs.contains { $0.contains("--prune") })
        #expect(preview.keepCount == 1)
        #expect(preview.removeCount == 2)
        #expect(preview.groups.count == 1)
        #expect(preview.groups[0].keep[0].snapshot.id == Self.idC)
        #expect(preview.groups[0].keep[0].reasons == ["last snapshot"])
        let removed = preview.groups[0].remove.map { $0.id }
        #expect(removed == [Self.idA, Self.idB])
        #expect(preview.mirrorSync == nil)
        #expect(preview.policy == RetentionPolicy(keepLast: 3))
        #expect(preview.fingerprint.hasPrefix("sha256:"))
        #expect(BackupDryRunTests.writtenFiles(env) == [])
        #expect(env.indexEntries.isEmpty)
        #expect(env.repoStatus(env.primary) == nil)
    }

    @Test("no policy, or one with no keep rule, refuses before the lock or restic")
    func refusesWithoutAPolicy() async throws {
        for retention in [nil, RetentionPolicy()] as [RetentionPolicy?] {
            let env = T.makeEnv(script: [], retention: retention)
            defer { env.cleanUp() }

            await #expect(throws: RepositoryQueryError.noRetentionPolicy) {
                try await env.engine.previewRetention(env.set, destination: env.primary)
            }
            #expect(env.fake.invocations.isEmpty)
            #expect(BackupDryRunTests.writtenFiles(env) == [])
        }
    }

    @Test("retention preview is refused while the set lock is held")
    func previewBusy() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let holder = FileLock(path: env.paths.setLockFile(setId: T.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        await #expect(throws: RepositoryQueryError.busy) {
            try await env.engine.previewRetention(env.set, destination: env.primary)
        }
        #expect(env.fake.invocations.isEmpty)
        #expect(BackupDryRunTests.writtenFiles(env) == [])
    }

    @Test("a locked repository is reported, never unlocked and retried")
    func previewLockedRepository() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(Self.previewArgv(env.primary.repoURL), dest: T.primaryId, exitCode: 11)

        await #expect(throws: RepositoryQueryError.resticFailed(destinationId: T.primaryId, .repoLocked)) {
            try await env.engine.previewRetention(env.set, destination: env.primary)
        }
        #expect(env.resticArgvs.count == 1)
    }

    /// A mirror's preview carries what repo-status says about its sync, and
    /// nothing in the preview changes repo-status.
    @Test("a mirror's preview reports its recorded sync against the primary's, and writes no state")
    func mirrorSync() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        let mirror = env.secondaries[0]
        try env.paths.ensureDirectories()
        _ = try env.stateStore.updateRepoStatus(destId: env.primary.id) { $0.lastSyncedAt = T.t0 }
        _ = try env.stateStore.updateRepoStatus(destId: mirror.id) { $0.lastSyncedAt = T.t0.addingTimeInterval(-3600) }
        let before = BackupDryRunTests.writtenFiles(env).map {
            (try? Data(contentsOf: env.paths.root.resolvingSymlinksInPath().appendingPathComponent($0))) ?? Data()
        }
        env.fake.script = T.resticCall(Self.previewArgv(mirror.repoURL), dest: mirror.id, stdoutLines: [Self.forgetJSON])

        let preview = try await env.engine.previewRetention(env.set, destination: mirror)

        let sync = try #require(preview.mirrorSync)
        #expect(sync.lastSyncedAt == T.t0.addingTimeInterval(-3600))
        #expect(sync.primaryLastSyncedAt == T.t0)
        #expect(sync.behindPrimary)
        let after = BackupDryRunTests.writtenFiles(env).map {
            (try? Data(contentsOf: env.paths.root.resolvingSymlinksInPath().appendingPathComponent($0))) ?? Data()
        }
        #expect(after == before)
    }

    @Test("a mirror with no recorded sync, or a level one, reads accordingly")
    func behindPrimaryRule() {
        typealias Sync = RetentionPreview.MirrorSync
        #expect(Sync(lastSyncedAt: nil, primaryLastSyncedAt: T.t0).behindPrimary)
        #expect(Sync(lastSyncedAt: T.t0, primaryLastSyncedAt: nil).behindPrimary)
        #expect(!Sync(lastSyncedAt: T.t0, primaryLastSyncedAt: T.t0).behindPrimary)
    }

    @Test("the fingerprint ignores id order and changes with the plan")
    func fingerprintIsDeterministic() {
        let destination = Destination(id: T.primaryId, label: "Primary", repoURL: "/repo", isPrimary: true)
        func fp(keep: [String], remove: [String], policy: RetentionPolicy = RetentionPolicy(keepLast: 3)) -> String {
            RetentionPreview.computeFingerprint(
                setId: T.setId, destination: destination, policy: policy, keepIDs: keep, removeIDs: remove
            )
        }
        #expect(fp(keep: ["c"], remove: ["a", "b"]) == fp(keep: ["c"], remove: ["b", "a"]))
        #expect(fp(keep: ["c"], remove: ["a", "b"]) != fp(keep: ["c", "a"], remove: ["b"]))
        #expect(fp(keep: ["c"], remove: ["a"]) != fp(keep: ["c"], remove: ["a"], policy: RetentionPolicy(keepLast: 4)))
    }

    @Test("isRetentionPreview accepts only forget with --dry-run and without --prune")
    func previewGuard() {
        let policy = RetentionPolicy(keepLast: 3)
        #expect(BackupEngine.isRetentionPreview(.forget(repo: "/r", policy: policy, dryRun: true)))
        #expect(!BackupEngine.isRetentionPreview(.forget(repo: "/r", policy: policy)))
        #expect(!BackupEngine.isRetentionPreview(.forget(repo: "/r", policy: policy, prune: true, dryRun: true)))
        #expect(!BackupEngine.isRetentionPreview(.snapshots(repo: "/r")))
    }

    // MARK: - CLI mapping

    @Test("each refusal maps to its documented code and exit")
    func cliMapping() {
        let dest = T.primaryId
        let cases: [(RepositoryQueryError, CLIErrorCode, HelperExitCode)] = [
            (.busy, .setBusy, .busy),
            (.offline(destinationId: dest, reason: "gone"), .repositoryOffline, .offline),
            (.noRetentionPolicy, .operationNotAllowed, .error),
            (.resticFailed(destinationId: dest, .repoLocked), .repositoryLocked, .error),
            (.resticFailed(destinationId: dest, .fatal(stderrSummary: "boom")), .resticFailed, .error),
            (.attention(.secretNotConfigured, destinationId: dest, message: "m"), .secretNotConfigured, .error),
            (.secretUnavailable(destinationId: dest, message: "m"), .secretUnavailable, .error),
            (.lockUnusable("d"), .internalError, .error),
            (.unreadableOutput(destinationId: dest, reason: "r"), .internalError, .error),
            (.notAPreview, .internalError, .error),
            (.resticDidNotRun(destinationId: dest, .timedOut), .operationTimedOut, .error),
        ]
        for (error, code, exit) in cases {
            let failure = CLIFailure.classifyRepositoryQuery(error, setId: T.setId)
            #expect(failure.code == code, "\(error)")
            #expect(failure.exitCode == exit, "\(error)")
            #expect(failure.details.setId == T.setId, "\(error)")
        }
    }
}
