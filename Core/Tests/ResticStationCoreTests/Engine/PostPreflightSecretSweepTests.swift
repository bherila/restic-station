import Foundation
import Testing
@testable import ResticStationCore

/// #152, as one property instead of one test per site: a secret problem
/// that appears *after* an operation's pre-flight is published exactly as
/// the pre-flight would have published it, and a refusal leaves the same
/// attention record behind.
///
/// Each operation is run once with a store that never fails, to count the
/// reads of the primary's secrets it makes. Then it is run again once per
/// read, with the store failing from that read on. Read 0 is the
/// pre-flight's own read, so its answer is the reference every later read
/// must match. A new read site needs no new test: it is a new read in the
/// count, and it is swept.
///
/// The second sweep pins the precedence (#169 review): when the failing
/// read lands inside a recorded run and the run record then cannot be
/// written, the run-history failure is the answer, not the secret one.
@Suite struct PostPreflightSecretSweepTests {
    typealias T = BackupEngineTests

    static let anything = SecretPreflightAttentionTests.anything

    private struct Operation {
        let name: String
        /// A fresh environment, with nothing failing yet, and the operation
        /// to run in it, returning its outcome as a comparable label.
        let make: () throws -> (env: T.Env, run: () async -> String)
    }

    private static let errors: [(SecretStoreError, refuses: Bool)] = [
        (.storeUnusable("chmod 600 secrets.json"), true),
        (.backendFailed("locked"), false),
    ]

    @Test("a run-history failure outranks a secret failure inside the same run")
    func runHistoryFailureOutranksSecret() async throws {
        var covered = 0
        for operation in try Self.operations() {
            let total = try await Self.readCount(operation)
            for reads in 1..<max(total, 1) {
                // Only the reads inside a recorded run: a refusal in the
                // pre-flight writes no run record to fail.
                let (_, plain) = try await Self.run(operation, failingAfter: reads, with: Self.errors[0].0)
                let recorded = !plain.indexEntries.isEmpty
                plain.cleanUp()
                guard recorded else { continue }

                let (env, run) = try operation.make()
                defer { env.cleanUp() }
                let index = env.paths.runsIndexLockFile
                env.secrets.failReads(for: T.primaryId, afterReads: reads, with: Self.errors[0].0) {
                    // The run record's terminal write fails: its index lock
                    // is a directory now (as `BackupEngineTests` does it).
                    try? FileManager.default.removeItem(at: index)
                    try? FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
                }
                let label = await run()
                covered += 1
                #expect(
                    label.contains("nfrastructure") || label.contains("auditFailure"),
                    "\(operation.name), failing from read \(reads + 1) of \(total): \(label)"
                )
            }
        }
        #expect(covered >= 4, "the precedence sweep reached only \(covered) recorded run(s)")
    }

    // MARK: - Harness

    private static func readCount(_ operation: Operation) async throws -> Int {
        let (env, run) = try operation.make()
        defer { env.cleanUp() }
        _ = await run()
        return env.secrets.reads(for: T.primaryId)
    }

    private static func run(
        _ operation: Operation,
        failingAfter reads: Int,
        with error: SecretStoreError
    ) async throws -> (label: String, env: T.Env) {
        let (env, run) = try operation.make()
        env.secrets.failReads(for: T.primaryId, afterReads: reads, with: error)
        return (await run(), env)
    }

    /// An outcome's description with every quoted string removed: the
    /// pre-flight and a later read word the same refusal differently, and
    /// the wording is not the property under test.
    static func label(_ value: Any) -> String {
        String(describing: value).replacingOccurrences(
            of: #""(?:[^"\\]|\\.)*""#, with: "\"…\"", options: .regularExpression
        )
    }

    // MARK: - Operations

    private static func operations() throws -> [Operation] {
        let remoteURL = "sftp:backup@example:/srv/repo"
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        return [
            Operation(name: "scheduled backup") {
                let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
                env.fake.script = anything
                return (env, { label(await env.engine.runSet(env.set, trigger: .scheduled)) })
            },
            Operation(name: "scheduled backup, remote primary") {
                // A remote primary's reachability probe reads the store too.
                let env = T.makeEnv(
                    script: [], retention: nil, reachableSecondaries: [], primaryRepoURL: remoteURL
                )
                env.fake.script = anything
                return (env, { label(await env.engine.runSet(env.set, trigger: .scheduled)) })
            },
            Operation(name: "scheduled check") {
                let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
                env.fake.script = anything
                return (env, { label(await env.engine.runCheck(env.set, trigger: .scheduled)) })
            },
            Operation(name: "restore") {
                let env = T.makeEnv(script: [], reachableSecondaries: [])
                env.fake.script = anything
                return (env, {
                    label(await env.engine.runRestore(request: RestoreRequest(
                        destId: T.primaryId, snapshotID: "abc123", targetPath: "/tmp/target"
                    )))
                })
            },
            Operation(name: "standalone prune dry run") {
                let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
                env.fake.script = anything
                return (env, {
                    label(await env.engine.runPruneRepository(set: env.set, destination: env.primary, dryRun: true))
                })
            },
            Operation(name: "remote prune dry run") {
                let env = T.makeEnv(script: [], retention: nil, reachableSecondaries: [])
                env.fake.script = [
                    .init(
                        argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "/opt/restic").argv,
                        stdoutLines: ["{\"version\":\"0.18.1\"}"]
                    ),
                ] + anything
                var destination = env.primary
                destination.repoURL = remoteURL
                destination.remoteMaintenance = RemoteMaintenance(enabled: true, remoteResticPath: "/opt/restic")
                var set = env.set
                set.destinations[0] = destination
                return (env, {
                    label(await env.engine.runPruneRepository(set: set, destination: destination, dryRun: true))
                })
            },
            Operation(name: "purge preview, local") {
                try purgePreview(remote: false, snapshotsJSON: snapshotsJSON)
            },
            Operation(name: "purge preview, remote") {
                try purgePreview(remote: true, snapshotsJSON: snapshotsJSON)
            },
            Operation(name: "purge apply, local") {
                try purgeApply(remote: false, snapshotsJSON: snapshotsJSON)
            },
            Operation(name: "purge apply, remote") {
                try purgeApply(remote: true, snapshotsJSON: snapshotsJSON)
            },
        ]
    }

    private static func purgePreview(
        remote: Bool,
        snapshotsJSON: String
    ) throws -> (env: T.Env, run: () async -> String) {
        let env = T.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            primaryRepoURL: remote ? "sftp:backup@example:/srv/repo" : nil
        )
        let repo = env.primary.repoURL
        env.fake.script = (remote ? T.repositoryConfigCall(repo, dest: T.primaryId) : [])
            + T.resticCall(["-r", repo, "snapshots", "--json"], dest: T.primaryId, stdoutLines: [snapshotsJSON])
            + anything
        let executable = try env.requireResticExecutable()
        return (env, {
            let result = await env.engine.previewPurge(set: env.set, destination: env.primary, executable: executable)
            return "\(result.status)"
        })
    }

    private static func purgeApply(
        remote: Bool,
        snapshotsJSON: String
    ) throws -> (env: T.Env, run: () async -> String) {
        let sourcePaths = [T.setId: Set(["/Users/user/example/src"])]
        let hostnames = [T.setId: Set(["example-mac.local"])]
        let env = T.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames,
            primaryRepoURL: remote ? "sftp:backup@example:/srv/repo" : nil
        )
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
        // Issuing the token read nothing worth counting; start from zero.
        env.secrets.clearFailures()
        let repo = env.primary.repoURL
        // A remote probe is its own `cat config`; then validation, then the
        // launch-bound revalidation, then the rewrite.
        env.fake.script = (remote ? T.repositoryConfigCall(repo, dest: T.primaryId) : [])
            + T.purgeLaunchValidationCalls(repo, dest: T.primaryId, snapshotsJSON: snapshotsJSON)
            + T.purgeLaunchValidationCalls(repo, dest: T.primaryId, snapshotsJSON: snapshotsJSON)
            + anything
        return (env, {
            do {
                let result = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: token.value)
                return "returned \(result.status)"
            } catch {
                return "threw \(label(error))"
            }
        })
    }
}
