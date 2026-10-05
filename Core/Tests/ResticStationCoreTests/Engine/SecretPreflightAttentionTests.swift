import Foundation
import Testing
@testable import ResticStationCore

/// #95: a destination whose secrets cannot be produced for a reason that
/// will not clear on its own is not a silent, forever-retried skip. The
/// scheduled paths return `.misconfigured` with no run record and record
/// `state/secret-attention-<destId>.json`; the manual paths refuse with the
/// repair; transient failures keep the old retryable, traceless behaviour.
@Suite struct SecretPreflightAttentionTests {
    typealias T = BackupEngineTests

    /// For tests that only care that the pre-flight passed: accept whatever
    /// the engine launches afterwards, since that outcome is not asserted.
    static let anything = Array(repeating: FakeProcessRunner.Expectation(argvPrefix: []), count: 12)

    @Test("scheduled backup: no stored password → misconfigured, no run record, attention recorded")
    func missingPasswordNeedsAttention() async throws {
        let env = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { env.cleanUp() }

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .misconfigured(let reason) = outcome else {
            Issue.record("expected .misconfigured, got \(outcome)")
            return
        }
        #expect(reason.contains("no password is stored"))
        #expect(reason.contains(DestinationAttention.secretSetCommand(destId: T.primaryId)))
        #expect(env.fake.invocations.isEmpty)
        #expect(env.indexEntries.isEmpty, "no run record — a 2-minute schedule must not write one per tick")
        #expect(env.stateStore.readScheduleState() == nil)
        let record = try #require(env.stateStore.readSecretAttention(destId: T.primaryId))
        #expect(record.attention == .secretNotConfigured)
        #expect(record.setId == T.setId)
    }

    @Test("a malformed secret environment beside a good password is unusable, not a restic failure")
    func malformedEnvironmentNeedsAttention() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.secrets.failSecretEnv(for: T.primaryId, with: .storeUnusable("failed to decode secret env JSON"))

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .misconfigured(let reason) = outcome else {
            Issue.record("expected .misconfigured, got \(outcome)")
            return
        }
        #expect(reason.contains("cannot be read"))
        #expect(env.fake.invocations.isEmpty, "restic must never be launched to fail on it")
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable)
    }

    @Test("a transient failure stays retryable and records no attention")
    func transientFailureStaysSilent() async throws {
        for failure: SecretStoreError in [.backendFailed("locked"), .lockUnusable(LockFailure(path: "/tmp/secrets.lock", operation: "flock", errnoValue: EWOULDBLOCK))] {
            let env = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: failure, script: [])
            defer { env.cleanUp() }

            let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

            guard case .retryable = outcome else {
                Issue.record("expected .retryable for \(failure), got \(outcome)")
                continue
            }
            #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)
        }
    }

    @Test("the next pre-flight that succeeds clears the attention")
    func successClearsAttention() async throws {
        let env = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { env.cleanUp() }
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) != nil)

        env.secrets.clearFailures()
        env.secrets.store(password: "now-stored", for: T.primaryId)
        env.fake.script = Self.anything
        // A check is the cheapest path through the same pre-flight; its own
        // outcome after the pre-flight does not matter here.
        _ = await env.engine.runCheck(env.set, trigger: .scheduled)

        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)
    }

    @Test("a repeated refusal keeps the time it was first seen")
    func repeatedRefusalKeepsDetectedAt() async throws {
        let env = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { env.cleanUp() }
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        let first = try #require(env.stateStore.readSecretAttention(destId: T.primaryId))
        env.clock.advance(3600)
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.detectedAt == first.detectedAt)
    }

    @Test("scheduled check: a permanent refusal is misconfigured, a transient one retryable")
    func checkPreflight() async throws {
        let permanent = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { permanent.cleanUp() }
        guard case .misconfigured = await permanent.engine.runCheck(permanent.set, trigger: .scheduled) else {
            Issue.record("expected .misconfigured")
            return
        }
        let transient = T.makeEnv(secretsUnavailableFor: [T.primaryId], script: [])
        defer { transient.cleanUp() }
        guard case .retryable = await transient.engine.runCheck(transient.set, trigger: .scheduled) else {
            Issue.record("expected .retryable")
            return
        }
    }

    @Test("manual restore and init-secondary refuse with the repair instead of a retryable skip")
    func manualPathsRefuse() async throws {
        let env = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { env.cleanUp() }

        let restore = await env.engine.runRestore(request: RestoreRequest(
            destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
        ))
        let initialize = await env.engine.initSecondary(env.set, dest: env.secondaries[0])

        for outcome in [restore, initialize] {
            guard case .secretRefused(let attention, let destinationId, _) = outcome else {
                Issue.record("expected .secretRefused, got \(outcome)")
                continue
            }
            #expect(attention == .secretNotConfigured)
            #expect(destinationId == T.primaryId)
        }
        #expect(env.fake.invocations.isEmpty)

        let transient = T.makeEnv(secretsUnavailableFor: [T.primaryId], script: [])
        defer { transient.cleanUp() }
        let deferred = await transient.engine.runRestore(request: RestoreRequest(
            destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
        ))
        #expect(deferred == .skipped)
    }

    /// The scope boundary from #95: remote maintenance spawns with no
    /// environment, so a malformed stored environment must not refuse it.
    @Test("remote maintenance is not refused over an environment it never uses")
    func remoteMaintenanceIgnoresStoredEnvironment() async throws {
        let env = T.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.secrets.failSecretEnv(for: T.primaryId, with: .storeUnusable("failed to decode secret env JSON"))
        env.fake.script = Self.anything
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true, remoteResticPath: "/opt/restic")
        var set = env.set
        set.destinations[0] = destination

        let result = await env.engine.runPruneRepository(set: set, destination: destination)

        if case .skipped(.secretRefused) = result {
            Issue.record("remote maintenance was refused over the stored environment: \(result)")
        }
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)
    }

    @Test("a local standalone prune is refused over a malformed environment it would pass to restic")
    func localPruneReadsStoredEnvironment() async throws {
        let env = T.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.secrets.failSecretEnv(for: T.primaryId, with: .storeUnusable("failed to decode secret env JSON"))

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary)

        guard case .skipped(.secretRefused(let attention, _)) = result else {
            Issue.record("expected .skipped(.secretRefused), got \(result)")
            return
        }
        #expect(attention == .secretStoreUnusable)
    }

    /// Codex on #165: a password-only pre-flight must not clear a problem it
    /// never re-checked — the malformed environment is still there and the
    /// next scheduled backup still refuses over it.
    @Test("a password-only pre-flight keeps an environment problem, and clears a missing-password one")
    func passwordOnlyPreflightClearsOnlyWhatItChecked() async throws {
        let env = T.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.secrets.failSecretEnv(for: T.primaryId, with: .storeUnusable("failed to decode secret env JSON"))
        _ = await env.engine.runSet(env.set, trigger: .scheduled)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable)

        env.fake.script = Self.anything
        var remote = env.primary
        remote.repoURL = "sftp:backup@example:/srv/repo"
        remote.remoteMaintenance = RemoteMaintenance(enabled: true, remoteResticPath: "/opt/restic")
        var set = env.set
        set.destinations[0] = remote
        _ = await env.engine.runPruneRepository(set: set, destination: remote)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable)

        // A missing password, by contrast, is disproved by any password read.
        try env.stateStore.clearSecretAttention(destId: T.primaryId)
        try env.stateStore.recordSecretAttention(SecretAttentionRecord(
            destId: T.primaryId, setId: T.setId, attention: .secretNotConfigured, detail: "", detectedAt: .now
        ))
        env.fake.script = Self.anything
        _ = await env.engine.runPruneRepository(set: set, destination: remote)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)
    }

    /// Codex on #165: a secondary's permanent secret problem is recorded on
    /// the due run too, without blocking the primary backup.
    @Test("a secondary with no stored password is recorded, and the primary still backs up")
    func secondarySecretProblemIsRecorded() async throws {
        let env = T.makeEnv(secretsUnavailableFor: [T.secondaryAId], secretFailure: .itemNotFound, script: [])
        defer { env.cleanUp() }
        env.fake.script = Self.anything

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        if case .misconfigured = outcome { Issue.record("a secondary must not block the primary: \(outcome)") }
        if case .retryable = outcome { Issue.record("a secondary must not defer the primary: \(outcome)") }
        #expect(env.stateStore.readSecretAttention(destId: T.secondaryAId)?.attention == .secretNotConfigured)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)

        env.secrets.clearFailures()
        env.secrets.store(password: "mirror", for: T.secondaryAId)
        env.fake.script = Self.anything
        _ = await env.engine.runCheck(env.set, trigger: .scheduled)
        #expect(env.stateStore.readSecretAttention(destId: T.secondaryAId) == nil)
    }

    // MARK: - #152: a store changed between the pre-flight and the spawn

    /// The engine's pre-flight reads the environment once; the runner's read
    /// just before the spawn is the second. Failing from the second read is
    /// a `chmod` or a malformed write landing in exactly that window.
    @Test("restore: a store refusal after the pre-flight is refused like the pre-flight, not a failed run")
    func restoreRefusalAfterPreflight() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = Self.anything
        env.secrets.failSecretEnv(for: T.primaryId, afterReads: 1, with: .storeUnusable("chmod 600 secrets.json"))

        let outcome = await env.engine.runRestore(request: RestoreRequest(
            destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
        ))

        guard case .secretRefused(let attention, let destinationId, _) = outcome else {
            Issue.record("expected .secretRefused, got \(outcome)")
            return
        }
        #expect(attention == .secretStoreUnusable)
        #expect(destinationId == T.primaryId)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable)
    }

    @Test("restore: a transient failure after the pre-flight stays a retryable skip")
    func restoreTransientAfterPreflight() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = Self.anything
        env.secrets.failSecretEnv(for: T.primaryId, afterReads: 1, with: .backendFailed("locked"))

        let outcome = await env.engine.runRestore(request: RestoreRequest(
            destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
        ))

        #expect(outcome == .skipped)
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId) == nil)
    }

    @Test("standalone prune: a store refusal after the pre-flight is published with the pre-flight's code")
    func pruneRefusalAfterPreflight() async throws {
        let env = T.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.fake.script = Self.anything
        env.secrets.failSecretEnv(for: T.primaryId, afterReads: 1, with: .storeUnusable("chmod 600 secrets.json"))

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary, dryRun: true)

        guard case .skipped(.secretRefused(let attention, _)) = result else {
            Issue.record("expected .skipped(.secretRefused), got \(result)")
            return
        }
        #expect(attention == .secretStoreUnusable)
    }

    @Test("purge preview: a store refusal after the pre-flight is not restic_failed")
    func purgePreviewRefusalAfterPreflight() async throws {
        let env = T.makeEnv(script: [], purgeExcludes: ["secret.key"])
        defer { env.cleanUp() }
        env.fake.script = Self.anything
        env.secrets.failSecretEnv(for: T.primaryId, afterReads: 1, with: .storeUnusable("chmod 600 secrets.json"))

        let result = await env.engine.previewPurge(
            set: env.set, destination: env.primary, executable: try env.requireResticExecutable()
        )

        #expect(result.status == .secretStoreUnusable, "got \(result.status): \(result.message ?? "")")
    }

    @Test("purge apply: a store refusal in a query after the pre-flight is refused, not 'unavailable'")
    func purgeApplyRefusalAfterPreflight() async throws {
        let sourcePaths = [T.setId: Set(["/Users/user/example/src"])]
        let hostnames = [T.setId: Set(["example-mac.local"])]
        let env = T.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshots = try parseSnapshots(Data(try FixtureLoader.string("snapshots.json").utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[T.setId]!, hostnames: hostnames[T.setId]!,
            patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan],
            executable: try env.requireResticExecutable()
        ))
        env.fake.script = [
            .init(
                argvPrefix: [env.resticPath, "-r", env.primary.repoURL, "cat", "config"],
                stdoutLines: ["{\"version\":2,\"id\":\"\(T.repositoryId)\"}"]
            ),
        ] + Self.anything
        // Pre-flight and reachability probe read the environment; the
        // repository query inside apply is the third read.
        env.secrets.failSecretEnv(for: T.primaryId, afterReads: 1, with: .storeUnusable("chmod 600 secrets.json"))

        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: token.value)
            Issue.record("expected a refusal")
        } catch let error as PurgeApplyError {
            guard case .secretRefused(let attention, let destinationId, _) = error else {
                Issue.record("expected .secretRefused, got \(error)")
                return
            }
            #expect(attention == .secretStoreUnusable)
            #expect(destinationId == T.primaryId)
        }
        #expect(!env.resticArgvs.contains { $0.contains("rewrite") })
        // Codex on #169: the pre-flight cleared any earlier record, so the
        // refusal must leave one behind for health and status.
        #expect(env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable)
    }
}
