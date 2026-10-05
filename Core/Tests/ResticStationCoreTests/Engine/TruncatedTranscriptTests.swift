import Foundation
import Testing
@testable import ResticStationCore

/// #150: an exit 0 whose transcript was cut by the bounded drain is not a
/// success the engine can vouch for. A backup records a warning, never a
/// clean success; a purge, whose rewrite mapping is its evidence, fails
/// closed as an indeterminate audit failure even when the prefix it did read
/// parses.
@Suite struct TruncatedTranscriptTests {
    typealias T = BackupEngineTests

    @Test("the runner classifies a cut exit-0 transcript as unverified, and only exit 0")
    func runnerClassification() {
        #expect(ResticRunner.status(exitCode: 0, messages: [], stderr: "", outputComplete: false) == .successUnverified)
        #expect(ResticRunner.status(exitCode: 0, messages: [], stderr: "", outputComplete: true) == .success)
        #expect(ResticRunner.status(exitCode: 3, messages: [], stderr: "", outputComplete: false) == .warningIncompleteRead)
        #expect(!ResticExitClass.successUnverified.isSuccess)
    }

    @Test("a backup whose transcript was cut is a warning, not a success")
    func backupIsUnverified() async throws {
        let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }
        env.fake.script = [
            .init(
                argvPrefix: [env.resticPath] + T.backupArgv(env.primary.repoURL),
                stdoutLines: T.backupStream(),
                outputComplete: false
            ),
        ]

        let outcome = await env.engine.runSet(env.set, trigger: .manual)

        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected a completed run, got \(outcome)")
            return
        }
        #expect(status == .warning)
        let backup = try #require(env.entries(kind: .backup).first)
        #expect(backup.status == .warning)
        #expect(backup.errorSummary?.contains("could not be verified") == true)
    }

    @Test("a purge whose rewrite transcript was cut fails closed, even if the prefix parses")
    func purgeFailsClosed() async throws {
        let sourcePaths = [T.setId: Set(["/Users/user/example/src"])]
        let hostnames = [T.setId: Set(["example-mac.local"])]
        let env = T.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[T.setId]!, hostnames: hostnames[T.setId]!,
            patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan],
            executable: try env.requireResticExecutable()
        ))
        // The complete, well-formed rewrite transcript: only the cut flag
        // says it cannot be trusted.
        let rewrite = try FixtureLoader.string("rewrite-forget.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        env.fake.script = T.purgeLaunchValidationCalls(env.primary.repoURL, dest: T.primaryId, snapshotsJSON: snapshotsJSON)
            + T.purgeLaunchValidationCalls(env.primary.repoURL, dest: T.primaryId, snapshotsJSON: snapshotsJSON)
            + [
                .init(
                    argvPrefix: [env.resticPath] + T.rewriteArgv(
                        env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes
                    ),
                    stdoutLines: rewrite.split(separator: "\n").map(String.init),
                    outputComplete: false
                ),
            ]

        var thrown: PurgeApplyError?
        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: token.value)
        } catch let error as PurgeApplyError {
            thrown = error
        }

        guard case .auditFailure(_, let operationMayHaveRun, let runId) = try #require(thrown) else {
            Issue.record("expected an indeterminate audit failure, got \(String(describing: thrown))")
            return
        }
        #expect(operationMayHaveRun)
        let metadata = try env.runStore.metadata(runId: runId)
        #expect(metadata.auditFailureReason == .repositoryOutcomeUnknown)
        #expect(metadata.purgeSnapshotRewrites == nil, "a cut transcript must not record a rewrite mapping")
    }

    /// Codex on #175: the helper issues the prune confirmation from any
    /// completed dry run, so a cut preview must not complete.
    @Test("a prune preview whose transcript was cut fails, so it can authorize nothing")
    func prunePreviewFails() async throws {
        let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }
        env.fake.script = [
            .init(argvPrefix: [env.resticPath, "-r", env.primary.repoURL, "prune", "--dry-run"], outputComplete: false),
        ]

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary, dryRun: true)

        #expect(result == .failed(.restic(.successUnverified)), "got \(result)")
    }
}
