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
/// "The same" includes the schedule: the pre-flight refuses before the
/// attempt stamps are written, so a later refusal must take its stamp back,
/// or a transient failure holds the retry off for a whole interval (#170).
///
/// A mirror has no pre-flight of its own that stops the run: its probe
/// skips it without failing the group, and the primary's backup stands.
/// So the third sweep fails each of a mirror's reads in turn and requires
/// the group's status to be the one a run with no failure gives (#172).
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

    @Test("every read after the pre-flight gives the pre-flight's answer and record")
    func everyReadMatchesThePreflight() async throws {
        for operation in try Self.operations() {
            let total = try await Self.readCount(operation)
            #expect(total >= 2, "\(operation.name): only \(total) read(s) — nothing after the pre-flight to sweep")
            for (error, refuses) in Self.errors {
                let (reference, referenceEnv) = try await Self.run(operation, failingAfter: 0, with: error)
                let referenceStamps = Self.attemptStamps(referenceEnv)
                referenceEnv.cleanUp()
                #expect(
                    referenceStamps == Self.priorStamps,
                    "\(operation.name), \(error): the pre-flight itself moved an attempt stamp"
                )
                for reads in 1..<max(total, 1) {
                    let (label, env) = try await Self.run(operation, failingAfter: reads, with: error)
                    #expect(
                        label == reference,
                        "\(operation.name), \(error), failing from read \(reads + 1) of \(total)"
                    )
                    #expect(
                        Self.attemptStamps(env) == referenceStamps,
                        "\(operation.name), \(error): an attempt stamp moved for a refusal at read \(reads + 1) of \(total)"
                    )
                    if refuses {
                        #expect(
                            env.stateStore.readSecretAttention(destId: T.primaryId)?.attention == .secretStoreUnusable,
                            "\(operation.name): no attention recorded for a refusal at read \(reads + 1) of \(total)"
                        )
                    }
                    env.cleanUp()
                }
            }
        }
    }

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

    @Test("a mirror's secret failure at any read leaves the group's status alone")
    func mirrorSecretFailureNeverDecidesTheGroup() async throws {
        for operation in try Self.mirrorOperations() {
            let (cleanEnv, cleanRun) = try operation.make()
            let clean = await cleanRun()
            let total = cleanEnv.secrets.reads(for: T.secondaryAId)
            cleanEnv.cleanUp()
            #expect(total >= 2, "\(operation.name): only \(total) read(s) of the mirror's secrets to sweep")
            for (error, refuses) in Self.errors {
                for reads in 0..<total {
                    let (env, run) = try operation.make()
                    env.secrets.failReads(for: T.secondaryAId, afterReads: reads, with: error)
                    let label = await run()
                    #expect(
                        label == clean,
                        "\(operation.name), \(error), failing the mirror from read \(reads + 1) of \(total)"
                    )
                    if refuses {
                        #expect(
                            env.stateStore.readSecretAttention(destId: T.secondaryAId)?.attention == .secretStoreUnusable,
                            "\(operation.name): no attention recorded for the mirror at read \(reads + 1) of \(total)"
                        )
                    }
                    env.cleanUp()
                }
            }
        }
    }

    /// The nearest constraint on letting a mirror's refusal pass (#172):
    /// the copy reads the primary's secrets too, as its source. A refusal
    /// of those is the primary's, the mirror was not updated, and the group
    /// must not read as a success. Each of the primary's reads after the
    /// pre-flight fails alone.
    @Test("the primary's secret failure during mirroring still fails the group")
    func primaryFailureDuringMirroringFailsTheGroup() async throws {
        for operation in try Self.mirrorOperations() {
            let (cleanEnv, cleanRun) = try operation.make()
            let clean = await cleanRun()
            let total = cleanEnv.secrets.reads(for: T.primaryId)
            cleanEnv.cleanUp()
            guard clean == "completed success" else { continue }
            #expect(total >= 2, "\(operation.name): only \(total) read(s) of the primary's secrets")
            for (error, _) in Self.errors {
                for reads in 1..<max(total, 1) {
                    let (env, run) = try operation.make()
                    defer { env.cleanUp() }
                    // This one read only: a later read that also fails,
                    // such as the primary's own retention, would fail the
                    // group whatever the copy's refusal did.
                    let secrets = env.secrets
                    env.secrets.failReads(for: T.primaryId, afterReads: reads, with: error) {
                        secrets.failReads(for: T.primaryId, afterReads: .max, with: error)
                    }
                    let label = await run()
                    #expect(
                        label != clean,
                        "\(operation.name), \(error), failing the primary from read \(reads + 1) of \(total): \(label)"
                    )
                }
            }
        }
    }

    /// The nearest constraint on taking the stamp back (#170): it is right
    /// only where the pre-flight would refuse on the next tick. Online-only
    /// files in a local cloud repository are not a pre-flight question. A
    /// backup's probe finds them and fails the run with its stamp, and a
    /// check, which does not probe the primary, finds them only at the
    /// runner's own check. Taking that stamp back would repeat the failed
    /// check on every tick instead of once a week.
    @Test("a repository with online-only files keeps the attempt stamp")
    func hydrationKeepsTheAttemptStamp() async throws {
        let online: @Sendable (String) -> String? = { _ in "data/ab/abcdef" }
        // Seen by the probe and the runner; or evicted after the probe, so
        // only the runner's check at launch sees it.
        let cases: [(name: String, probe: (@Sendable (String) -> String?)?, check: Bool)] = [
            ("backup, seen by the probe", online, false),
            ("backup, evicted after the probe", nil, false),
            ("check", online, true),
        ]
        for (name, probe, check) in cases {
            let env = T.makeEnv(
                script: [], retention: nil, checkPolicy: CheckPolicy(enabled: true), reachableSecondaries: [],
                probeDatalessEntry: probe, runnerDatalessEntry: online
            )
            defer { env.cleanUp() }
            env.fake.script = Self.anything
            try env.stateStore.updateScheduleState(setId: T.setId) {
                $0.lastBackupStart = Self.priorStamps[0]
                $0.lastCheckStart = Self.priorStamps[1]
            }
            let outcome = check
                ? Self.label(await env.engine.runCheck(env.set, trigger: .scheduled))
                : Self.label(await env.engine.runSet(env.set, trigger: .scheduled))
            #expect(env.fake.invocations.isEmpty, "\(name): restic ran — \(outcome)")
            let state = env.stateStore.readScheduleState()?.sets[T.setId]
            let stamp = check ? state?.lastCheckStart : state?.lastBackupStart
            #expect(stamp == T.t0, "\(name): the attempt stamp is \(String(describing: stamp)), not this run's — \(outcome)")
        }
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
        // An earlier attempt on record, so a stamp that is taken back must
        // be restored to it, not merely cleared.
        try env.stateStore.updateScheduleState(setId: T.setId) {
            $0.lastBackupStart = priorStamps[0]
            $0.lastCheckStart = priorStamps[1]
        }
        env.secrets.failReads(for: T.primaryId, afterReads: reads, with: error)
        return (await run(), env)
    }

    /// Eight days back: both a backup and the weekly check are due again.
    private static let priorStamps: [Date?] = Array(repeating: T.t0.addingTimeInterval(-8 * 24 * 60 * 60), count: 2)

    private static func attemptStamps(_ env: T.Env) -> [Date?] {
        let state = env.stateStore.readScheduleState()?.sets[T.setId]
        return [state?.lastBackupStart, state?.lastCheckStart]
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

    /// Runs with one reachable local mirror, labelled by the group's
    /// status alone: the mirror's children stay in the history either way.
    private static func mirrorOperations() throws -> [Operation] {
        [
            Operation(name: "scheduled backup, copy and mirror retention") {
                let env = T.makeEnv(script: [], reachableSecondaries: [true])
                env.fake.script = anything
                return (env, {
                    switch await env.engine.runSet(env.set, trigger: .scheduled) {
                    case .completed(let status, _, _): return "completed \(status)"
                    case let other: return label(other)
                    }
                })
            },
            Operation(name: "scheduled check, on the mirror's turn") {
                let env = T.makeEnv(
                    script: [], retention: nil, checkPolicy: CheckPolicy(enabled: true), reachableSecondaries: [true]
                )
                env.fake.script = anything
                // The next successful check is a multiple of the rotation,
                // so the mirror gets its structure-only check.
                try env.stateStore.updateScheduleState(setId: T.setId) {
                    $0.checkCount = BackupEngine.secondaryCheckEveryNChecks - 1
                }
                return (env, { label(await env.engine.runCheck(env.set, trigger: .scheduled)) })
            },
        ]
    }

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
