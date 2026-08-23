import Foundation
import Testing

@testable import ResticStationCore

/// Containment of **Apply retention now** (Option A), and proof it did not
/// reach the scheduled path.
///
/// The second and third tests are the load-bearing half. A guard placed too
/// broadly would turn "unsafe manual retention is unavailable" into "no
/// retention runs at all" — repositories would then grow without bound with
/// nothing failing to say so, which is a worse outage than the one being
/// contained.
struct ManualRetentionContainmentTests {

    private typealias Fixtures = BackupEngineTests

    // MARK: - 1. Manual apply refuses, and touches nothing

    @Test("manual retention apply refuses without spawning restic or writing any state")
    func manualApplyIsContained() async throws {
        let env = Fixtures.makeEnv(script: [])
        defer { env.cleanUp() }

        // Seed state the guard must leave alone, so "wrote nothing" is a real
        // assertion rather than a vacuous one against an empty store.
        try env.stateStore.updateRepoStatus(destId: env.primary.id) {
            $0.lastSyncedAt = Fixtures.t0
        }

        let outcome = await env.engine.runPrune(env.set)

        guard case .operationNotAllowed(let reason) = outcome else {
            Issue.record("expected .operationNotAllowed, got \(outcome)")
            return
        }
        #expect(reason == ManualRetentionApplyAvailability.reason)
        // Not `.skipped` (a retryable deferral) and not
        // `.infrastructureFailure` (this machine is broken) — either would
        // send a caller down the wrong recovery path.
        #expect(outcome != .skipped)

        #expect(env.resticArgvs.isEmpty, "no forget/prune subprocess may be spawned")
        #expect(env.indexEntries.isEmpty, "no run record may be manufactured")
        #expect(env.stateStore.readCurrentRun(setId: Fixtures.setId) == nil)
        #expect(
            env.repoStatus(env.primary)?.lastSyncedAt == Fixtures.t0,
            "pre-existing repository state is untouched"
        )
    }

    @Test("containment is a constant, not a configuration switch")
    func containmentIsConstant() {
        #expect(ManualRetentionApplyAvailability.isEnabled == false)
        #expect(!ManualRetentionApplyAvailability.reason.isEmpty)
    }

    // MARK: - 2. Scheduled retention is unaffected

    @Test("scheduled retention still forgets both mirrors and the primary, each mirror after its own copy")
    func scheduledRetentionSurvivesContainment() async throws {
        let env = Fixtures.makeEnv(script: [])
        defer { env.cleanUp() }
        let primaryRepo = env.primary.repoURL
        let secA = env.secondaries[0].repoURL
        let secB = env.secondaries[1].repoURL

        var script: [FakeProcessRunner.Expectation] = []
        script += Fixtures.resticCall(
            Fixtures.backupArgv(primaryRepo), dest: Fixtures.primaryId,
            stdoutLines: Fixtures.backupStream()
        )
        script += Fixtures.resticCall(
            Fixtures.copyArgv(to: secA, from: primaryRepo),
            dest: Fixtures.secondaryAId, from: Fixtures.primaryId
        )
        script += Fixtures.resticCall(Fixtures.forgetArgv(secA), dest: Fixtures.secondaryAId)
        script += Fixtures.resticCall(
            Fixtures.copyArgv(to: secB, from: primaryRepo),
            dest: Fixtures.secondaryBId, from: Fixtures.primaryId
        )
        script += Fixtures.resticCall(Fixtures.forgetArgv(secB), dest: Fixtures.secondaryBId)
        script += Fixtures.resticCall(Fixtures.forgetArgv(primaryRepo), dest: Fixtures.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)

        // Each mirror is forgotten immediately after its own successful copy,
        // and the primary is forgotten last.
        #expect(env.indexEntries.map(\.kind) == [.backup, .copy, .prune, .copy, .prune, .prune])
        #expect(env.indexEntries.allSatisfy { $0.status == .success })

        let forgets = env.resticArgvs.filter { $0.contains("forget") }
        #expect(forgets.count == 3, "two mirrors plus the primary")
        #expect(forgets.last == [Fixtures.resticPath] + Fixtures.forgetArgv(primaryRepo),
                "the primary is pruned last, after every mirror")
    }

    // MARK: - 3. A failed copy suppresses only its own mirror

    @Test("a failed copy skips that mirror's retention while the rest of the run continues")
    func failedCopySuppressesOnlyItsOwnMirror() async throws {
        let env = Fixtures.makeEnv(script: [])
        defer { env.cleanUp() }
        let primaryRepo = env.primary.repoURL
        let secA = env.secondaries[0].repoURL
        let secB = env.secondaries[1].repoURL

        var script: [FakeProcessRunner.Expectation] = []
        script += Fixtures.resticCall(
            Fixtures.backupArgv(primaryRepo), dest: Fixtures.primaryId,
            stdoutLines: Fixtures.backupStream()
        )
        // Mirror A's copy fails: no forget may follow it.
        script += Fixtures.resticCall(
            Fixtures.copyArgv(to: secA, from: primaryRepo),
            dest: Fixtures.secondaryAId, from: Fixtures.primaryId,
            stderr: "copy failed", exitCode: 1
        )
        script += Fixtures.resticCall(
            Fixtures.copyArgv(to: secB, from: primaryRepo),
            dest: Fixtures.secondaryBId, from: Fixtures.primaryId
        )
        script += Fixtures.resticCall(Fixtures.forgetArgv(secB), dest: Fixtures.secondaryBId)
        script += Fixtures.resticCall(Fixtures.forgetArgv(primaryRepo), dest: Fixtures.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status != .success, "the failed copy is reflected in the final status")

        let forgets = env.resticArgvs.filter { $0.contains("forget") }
        #expect(
            !forgets.contains { $0.contains(secA) },
            "SAFETY: a mirror whose copy failed is never forgotten"
        )
        // Independent safe work still happened.
        #expect(forgets.contains { $0.contains(secB) }, "the healthy mirror's retention still runs")
        #expect(forgets.contains { $0.contains(primaryRepo) }, "the primary's retention still runs")
    }
}
