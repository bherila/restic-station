import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Test doubles

/// Injectable clock. `now` is deliberately a stored closure so the same
/// clock instance drives the engine, the `RunStore` (runId timestamps) and
/// the `LogWriter`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Wraps `FakeProcessRunner` and calls `onSpawn` *before* delegating, so a
/// test can observe on-disk state (notably `state/current-run-<setId>.json`)
/// at the exact moment a given restic child is spawned — the only way to
/// watch the live-progress file, which a finished set run deletes.
final class ObservingProcessRunner: ProcessRunning, @unchecked Sendable {
    let inner: FakeProcessRunner
    private let onSpawn: @Sendable ([String]) -> Void

    init(inner: FakeProcessRunner, onSpawn: @escaping @Sendable ([String]) -> Void) {
        self.inner = inner
        self.onSpawn = onSpawn
    }

    func run(
        _ argv: [String],
        env: [String: String]?,
        stdin: Data?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        onSpawn(argv)
        return try await inner.run(
            argv,
            env: env,
            stdin: stdin,
            currentDirectory: currentDirectory,
            onStdoutLine: onStdoutLine,
            onStderrLine: onStderrLine,
            timeout: timeout
        )
    }
}

// MARK: - Suite

@Suite("BackupEngine: runSet sequence, checks, prune, restore, init")
struct BackupEngineTests {

    // MARK: Fixed identifiers / clock

    /// A **real file**, not merely a plausible path.
    ///
    /// `maintenanceExecutable()` hashes the bytes at this path, and since the
    /// #109 exact-head fix a purge refuses to mint or honour a destructive
    /// capability when it cannot identify a binary. A fixture path that only
    /// looks like restic therefore passes on a dev Mac that happens to have
    /// it installed at `/opt/homebrew/bin/restic` and fails in the Linux CI
    /// container, which does not — the tests were silently depending on
    /// ambient host state, and tolerating a nil identity is what hid it.
    ///
    /// Used for `argv[0]` as well, so the golden argv assertions keep
    /// comparing the configured path against itself on both platforms.
    static let resticPath: String = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-fixture-restic", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data("restic fixture binary".utf8)
            )
        }
        return url.path
    }()
    static let setId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    static let primaryId = UUID(uuidString: "0A1B2C3D-8B86-D011-B42D-00C04FC964FF")!
    static let secondaryAId = UUID(uuidString: "1B2C3D4E-8B86-D011-B42D-00C04FC964FF")!
    static let secondaryBId = UUID(uuidString: "2C3D4E5F-8B86-D011-B42D-00C04FC964FF")!
    static let source = "/Users/test/proj"
    static let t0 = Date(timeIntervalSince1970: 1_784_000_000) // 2026-07-13T…Z, fixed

    // MARK: Environment

    /// Everything one engine test needs, wired to a temp data dir. Local
    /// destinations are used throughout so `Reachability` answers from the
    /// filesystem and every spawned argv in `fake.invocations` is either a
    /// restic command the engine itself issued.
    struct Env {
        let root: URL
        let paths: AppPaths
        let clock: TestClock
        let fake: FakeProcessRunner
        let runStore: RunStore
        let stateStore: StateStore
        let engine: BackupEngine
        let machineId: String
        let set: BackupSet
        let primary: Destination
        let secondaries: [Destination]

        var resticArgvs: [[String]] {
            fake.invocations.map(\.argv).filter { $0.first == BackupEngineTests.resticPath }
        }

        var indexEntries: [RunIndexEntry] {
            ((try? runStore.recentRuns(limit: 1000)) ?? []).reversed()
        }

        func entries(kind: RunKind) -> [RunIndexEntry] {
            indexEntries.filter { $0.kind == kind }
        }

        func repoStatus(_ destination: Destination) -> RepoStatus? {
            stateStore.readRepoStatus(destId: destination.id)
        }

        func log(runId: String) -> String {
            (try? String(contentsOf: paths.runLogFile(runId: runId), encoding: .utf8)) ?? ""
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// - Parameters:
    ///   - reachableSecondaries: one flag per secondary; an unreachable one
    ///     simply has no repository directory on disk.
    static func makeEnv(
        secretsUnavailableFor: [UUID] = [],
        secretBackend: SecretBackend = .platformDefault,
        script: [FakeProcessRunner.Expectation],
        retention: RetentionPolicy? = RetentionPolicy(keepLast: 3),
        checkPolicy: CheckPolicy? = nil,
        excludes: [String] = [],
        purgeExcludes: [String] = [],
        primaryReachable: Bool = true,
        reachableSecondaries: [Bool] = [true, true],
        startingAt: Date = t0,
        onSpawn: (@Sendable ([String]) -> Void)? = nil,
        purgeSourcePaths: [UUID: Set<String>] = [:],
        purgeHostnames: [UUID: Set<String>] = [:],
        machineId: String = "example-machine",
        /// Overridable so a test can point the engine at a binary it is
        /// allowed to modify, and assert what happens when restic is
        /// replaced mid-operation.
        resticPath: String = BackupEngineTests.resticPath
    ) -> Env {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-engine-\(UUID().uuidString)", isDirectory: true)
        let repos = root.appendingPathComponent("repos", isDirectory: true)
        try? FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)

        func repo(_ name: String, exists: Bool) -> String {
            let url = repos.appendingPathComponent(name, isDirectory: true)
            if exists {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url.path
        }

        let primary = Destination(
            id: primaryId,
            label: "Primary",
            repoURL: repo("primary", exists: primaryReachable),
            isPrimary: true
        )
        let secondaryIds = [secondaryAId, secondaryBId]
        let secondaries = reachableSecondaries.enumerated().map { index, reachable in
            Destination(
                id: secondaryIds[index],
                label: "Mirror \(index + 1)",
                repoURL: repo("secondary-\(index)", exists: reachable),
                isPrimary: false
            )
        }

        let set = BackupSet(
            id: setId,
            name: "Projects",
            sources: [source],
            excludes: excludes,
            purgeExcludes: purgeExcludes,
            schedule: .daily(hour: 2, minute: 30),
            retention: retention,
            checkPolicy: checkPolicy,
            destinations: [primary] + secondaries
        )
        let config = AppConfig(resticPath: resticPath, sets: [set])

        let paths = AppPaths(root: root)
        let clock = TestClock(startingAt)
        let fake = FakeProcessRunner(script: script)
        let processRunner: ProcessRunning = onSpawn.map {
            ObservingProcessRunner(inner: fake, onSpawn: $0)
        } ?? fake
        let secrets = FakeSecretStore(defaultPassword: "repo-password", backend: secretBackend)
        for id in secretsUnavailableFor {
            secrets.failPassword(for: id)
        }
        let restic = ResticRunner(
            resticPath: resticPath,
            paths: paths,
            secrets: secrets,
            runner: processRunner
        )
        let runStore = RunStore(paths: paths, now: clock.now)
        let stateStore = StateStore(paths: paths)

        let engine = BackupEngine(
            config: config,
            paths: paths,
            restic: restic,
            secrets: secrets,
            runStore: runStore,
            stateStore: stateStore,
            reachability: Reachability(restic: restic),
            now: clock.now,
            purgeSourcePaths: purgeSourcePaths,
            purgeHostnames: purgeHostnames,
            machineId: machineId
        )

        return Env(
            root: root,
            paths: paths,
            clock: clock,
            fake: fake,
            runStore: runStore,
            stateStore: stateStore,
            engine: engine,
            machineId: machineId,
            set: set,
            primary: primary,
            secondaries: secondaries
        )
    }

    // MARK: Scripting helpers

    /// One scripted restic spawn. `argv` is matched in full (prefix == whole
    /// argv).
    ///
    /// Before T23 this also had to script the four `/usr/bin/security` reads
    /// each spawn triggered; secrets now come from an injected
    /// `FakeSecretStore`, so the process script is restic and nothing else.
    /// `dest`/`from` are kept in the signature because they document which
    /// destinations a call reads secrets for.
    static func resticCall(
        _ argv: [String],
        dest: UUID,
        from: UUID? = nil,
        stdoutLines: [String] = [],
        stderr: String = "",
        exitCode: Int32 = 0
    ) -> [FakeProcessRunner.Expectation] {
        [
            .init(
                argvPrefix: [resticPath] + argv,
                stdoutLines: stdoutLines,
                stderr: stderr,
                exitCode: exitCode
            ),
        ]
    }

    static func backupArgv(_ repo: String, excludes: [String] = []) -> [String] {
        var argv = ["-r", repo, "backup", "--json"]
        for exclude in excludes {
            argv.append("--exclude")
            argv.append(exclude)
        }
        argv.append(source)
        return argv
    }

    static func copyArgv(to secondary: String, from primary: String) -> [String] {
        ["-r", secondary, "copy", "--from-repo", primary]
    }

    static func forgetArgv(_ repo: String, keepLast: Int = 3) -> [String] {
        ["-r", repo, "forget", "--json", "--keep-last", String(keepLast), "--prune"]
    }

    static func rewriteArgv(_ repo: String, snapshotIDs: [String], patterns: [String]) -> [String] {
        var argv = ["-r", repo, "rewrite", "--forget"]
        for pattern in patterns {
            argv += ["--exclude", pattern]
        }
        return argv + snapshotIDs
    }

    static func backupStream() -> [String] {
        (try? FixtureLoader.lines("backup.ndjson")) ?? []
    }

    // MARK: - Row 1 — happy path

    @Test("row 1: primary + 2 reachable secondaries + retention → backup, 2 copies, 3 prunes, one group")
    func rowOneHappyPath() async throws {
        var script: [FakeProcessRunner.Expectation] = []
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        let primaryRepo = env.primary.repoURL
        let secA = env.secondaries[0].repoURL
        let secB = env.secondaries[1].repoURL

        script += Self.resticCall(
            Self.backupArgv(primaryRepo), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: secA, from: primaryRepo), dest: Self.secondaryAId, from: Self.primaryId
        )
        script += Self.resticCall(Self.forgetArgv(secA), dest: Self.secondaryAId)
        script += Self.resticCall(
            Self.copyArgv(to: secB, from: primaryRepo), dest: Self.secondaryBId, from: Self.primaryId
        )
        script += Self.resticCall(Self.forgetArgv(secB), dest: Self.secondaryBId)
        script += Self.resticCall(Self.forgetArgv(primaryRepo), dest: Self.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        // Exact spawned restic argv sequence. NOTE the interleaving: T09
        // step 6 applies retention to a secondary immediately after that
        // secondary's copy succeeds; `docs/testing.md`'s row-1 shorthand
        // ("copy ×2 → forget ×3") groups by command type, which is not the
        // order the normative step-6 text describes.
        // Built stepwise: a single nested-literal expression exceeds the
        // Swift 6.1 type checker's budget (CI), though 6.3 handles it.
        var expectedArgvs: [[String]] = []
        expectedArgvs.append([Self.resticPath] + Self.backupArgv(primaryRepo))
        expectedArgvs.append([Self.resticPath] + Self.copyArgv(to: secA, from: primaryRepo))
        expectedArgvs.append([Self.resticPath] + Self.forgetArgv(secA))
        expectedArgvs.append([Self.resticPath] + Self.copyArgv(to: secB, from: primaryRepo))
        expectedArgvs.append([Self.resticPath] + Self.forgetArgv(secB))
        expectedArgvs.append([Self.resticPath] + Self.forgetArgv(primaryRepo))
        #expect(env.resticArgvs == expectedArgvs)

        guard case .completed(let status, let groupId, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)
        #expect(children.count == 6)

        let entries = env.indexEntries
        #expect(entries.count == 6)
        #expect(entries.map(\.kind) == [.backup, .copy, .prune, .copy, .prune, .prune])
        #expect(entries.allSatisfy { $0.status == .success })
        #expect(entries.allSatisfy { $0.groupId == groupId })
        #expect(entries.allSatisfy { $0.trigger == .scheduled })
        #expect(entries[0].runId == groupId, "groupId is the primary backup's runId")
        #expect(entries[0].snapshotId?.hasPrefix("e9ffc5cb") == true)

        // lastSyncedAt updated for all three destinations.
        for destination in [env.primary] + env.secondaries {
            #expect(env.repoStatus(destination)?.lastSyncedAt == Self.t0)
            #expect(env.repoStatus(destination)?.reachable == true)
        }
        // current-run deleted when the group finished.
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil)
        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.lastBackupStart == Self.t0)
    }

    // MARK: - Row 2 — primary unreachable

    @Test("row 2: primary unreachable → failed backup record, no restic at all, lastBackupStart still updated")
    func rowTwoPrimaryUnreachable() async throws {
        let env = Self.makeEnv(
            script: [],
            primaryReachable: false
        )
        defer { env.cleanUp() }

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs.isEmpty, "no restic child may be spawned once the primary probe fails")
        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .failed)
        #expect(children.count == 1)

        let entries = env.indexEntries
        #expect(entries.count == 1)
        #expect(entries[0].kind == .backup)
        #expect(entries[0].status == .failed)
        #expect(entries[0].errorSummary?.contains("primary unreachable") == true)
        #expect(env.entries(kind: .copy).isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)

        // Attempt semantics: the attempt counts even though it failed.
        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.lastBackupStart == Self.t0)
        #expect(env.repoStatus(env.primary)?.reachable == false)
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil)
    }

    // MARK: - Row 3 — secondary offline

    @Test("row 3: offline secondary gets no run record, only repo-status; its old lastSyncedAt survives")
    func rowThreeSecondaryOffline() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [false, true])
        defer { env.cleanUp() }
        let offline = env.secondaries[0]
        let online = env.secondaries[1]

        // Seed a stale lastSyncedAt for the offline mirror: staleness must be
        // computed from it, so the engine must not clear or overwrite it.
        let staleSync = Self.t0.addingTimeInterval(-30 * 24 * 3600)
        try env.stateStore.updateRepoStatus(destId: offline.id) { status in
            status.reachable = true
            status.lastSyncedAt = staleSync
        }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: online.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryBId,
            from: Self.primaryId
        )
        script += Self.resticCall(Self.forgetArgv(online.repoURL), dest: Self.secondaryBId)
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        // Built stepwise for the Swift 6.1 type-checker budget (see row 1).
        var expectedArgvs: [[String]] = []
        expectedArgvs.append([Self.resticPath] + Self.backupArgv(env.primary.repoURL))
        expectedArgvs.append([Self.resticPath] + Self.copyArgv(to: online.repoURL, from: env.primary.repoURL))
        expectedArgvs.append([Self.resticPath] + Self.forgetArgv(online.repoURL))
        expectedArgvs.append([Self.resticPath] + Self.forgetArgv(env.primary.repoURL))
        #expect(env.resticArgvs == expectedArgvs)
        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)

        // No run record of any kind mentions the offline destination.
        #expect(env.indexEntries.allSatisfy { $0.destId != offline.id })
        let offlineStatus = try #require(env.repoStatus(offline))
        #expect(offlineStatus.reachable == false)
        #expect(offlineStatus.lastSyncedAt == staleSync, "staleness still derives from the old sync time")
        #expect(env.repoStatus(online)?.lastSyncedAt == Self.t0)
    }

    // MARK: - Row 4 — backup exit 3

    @Test("row 4: backup exit 3 is a warning and the copy still runs (the snapshot exists)")
    func rowFourExitThreeWarning() async throws {
        let env = Self.makeEnv(script: [], retention: nil, reachableSecondaries: [true])
        defer { env.cleanUp() }
        let secondary = env.secondaries[0]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream(),
            stderr: "error: lstat /Users/test/proj/secret: permission denied",
            exitCode: 3
        )
        script += Self.resticCall(
            Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryAId,
            from: Self.primaryId
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .warning, "worst child status: warning (backup) vs success (copy)")
        #expect(children.map(\.status) == [.warning, .success])
        #expect(env.entries(kind: .backup).first?.status == .warning)
        #expect(env.entries(kind: .copy).first?.status == .success)
        #expect(env.repoStatus(env.primary)?.lastSyncedAt == Self.t0, "exit 3 still produced a snapshot")
    }

    // MARK: - Row 5 — backup exit 1

    @Test("row 5: backup exit 1 stops the sequence — no copies, no retention")
    func rowFiveExitOneStops() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL),
            dest: Self.primaryId,
            stderr: "Fatal: unable to open repository",
            exitCode: 1
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs == [[Self.resticPath] + Self.backupArgv(env.primary.repoURL)])
        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .failed)
        #expect(children.count == 1)
        #expect(env.entries(kind: .backup).first?.status == .failed)
        #expect(env.entries(kind: .copy).isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
        #expect(env.repoStatus(env.primary)?.lastSyncedAt == nil)
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil, "current-run cleared on the failure path too")
    }

    @Test("a terminal run that cannot enter the index is infrastructure failure")
    func runIndexFailureCannotReportScheduledSuccess() async throws {
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            reachableSecondaries: [],
            onSpawn: { argv in
                guard argv.contains("backup"), let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.runsIndexLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.runsIndexLockFile,
                    withIntermediateDirectories: true
                )
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        env.fake.script = Self.resticCall(
            Self.backupArgv(env.primary.repoURL),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream()
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("a missing terminal index entry must fail the scheduled operation: \(outcome)")
            return
        }
        #expect(reason.contains("run history unusable"))
        #expect(env.indexEntries.isEmpty)
    }

    // MARK: - Row 6 / Row 12 — copy failure isolates that mirror

    @Test("rows 6+12: a failed copy is recorded, its mirror is never forgotten, the other mirror proceeds")
    func rowSixCopyFailureIsolated() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        let failing = env.secondaries[0]
        let healthy = env.secondaries[1]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: failing.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryAId,
            from: Self.primaryId,
            stderr: "Fatal: unable to open repository",
            exitCode: 1
        )
        script += Self.resticCall(
            Self.copyArgv(to: healthy.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryBId,
            from: Self.primaryId
        )
        script += Self.resticCall(Self.forgetArgv(healthy.repoURL), dest: Self.secondaryBId)
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        // SAFETY: no forget argv anywhere targets the mirror whose copy failed.
        let forgets = env.resticArgvs.filter { $0.contains("forget") }
        #expect(forgets.allSatisfy { !$0.contains(failing.repoURL) })
        #expect(forgets.count == 2)

        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        // T09 step 8 is literal: group outcome = worst child status, and a
        // failed copy child is `.failed`. (`docs/testing.md` row 6 says the
        // group is "shown as warning" — that is a UI-presentation statement:
        // the primary snapshot exists, only a mirror lagged.)
        #expect(status == .failed)
        #expect(env.entries(kind: .backup).first?.status == .success)

        let copies = env.entries(kind: .copy)
        #expect(copies.count == 2)
        #expect(copies.first(where: { $0.destId == failing.id })?.status == .failed)
        #expect(copies.first(where: { $0.destId == healthy.id })?.status == .success)

        #expect(env.repoStatus(failing)?.lastSyncedAt == nil, "a failed copy must not refresh lastSyncedAt")
        #expect(env.repoStatus(healthy)?.lastSyncedAt == Self.t0)
        #expect(env.entries(kind: .prune).allSatisfy { $0.destId != failing.id })
    }

    // MARK: - Row 7 — repo locked, stale lock

    @Test("row 7: exit 11 → unlock → exactly one retry that succeeds; the log holds both attempts")
    func rowSevenLockedStale() async throws {
        let env = Self.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }
        let lockedError = (try? FixtureLoader.string("locked-error.json").trimmingCharacters(in: .newlines)) ?? ""

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL),
            dest: Self.primaryId,
            stdoutLines: [lockedError],
            exitCode: 11
        )
        script += Self.resticCall(
            ["-r", env.primary.repoURL, "unlock"],
            dest: Self.primaryId,
            stdoutLines: ["successfully removed 1 locks"]
        )
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs == [
            [Self.resticPath] + Self.backupArgv(env.primary.repoURL),
            [Self.resticPath, "-r", env.primary.repoURL, "unlock"],
            [Self.resticPath] + Self.backupArgv(env.primary.repoURL),
        ])
        guard case .completed(let status, let groupId, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)
        #expect(children.count == 1, "the retry is part of the same run record, not a second one")

        let log = env.log(runId: groupId)
        #expect(log.contains("repository is already locked"), "attempt 1's raw output")
        #expect(log.contains("successfully removed 1 locks"), "the unlock child's raw output")
        #expect(log.contains("retrying after unlock"))
        #expect(log.contains("\"message_type\":\"summary\""), "attempt 2's raw output")
    }

    // MARK: - Row 8 — repo locked, live lock

    @Test("row 8: still locked after unlock + retry → failed, and no third attempt")
    func rowEightLockedLive() async throws {
        let env = Self.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, exitCode: 11
        )
        script += Self.resticCall(["-r", env.primary.repoURL, "unlock"], dest: Self.primaryId)
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, exitCode: 11
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs.count == 3, "exactly one retry — never a loop")
        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .failed)
        let backup = try #require(env.entries(kind: .backup).first)
        #expect(backup.status == .failed)
        #expect(backup.errorSummary?.contains("locked") == true)
    }

    // MARK: - Row 9 — unreadable secret store (safety: no trace at all)

    @Test("row 9: an unreadable secret store leaves NO run record, NO lastBackupStart, NO lock file")
    func rowNineSecretsUnavailable() async throws {
        let env = Self.makeEnv(secretsUnavailableFor: [Self.primaryId], script: [])
        defer { env.cleanUp() }

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .retryable = outcome else {
            Issue.record("expected .retryable, got \(outcome)")
            return
        }
        // Nothing was spawned at all — the pre-flight is not a subprocess,
        // and it runs before anything else the engine does.
        #expect(env.fake.invocations.isEmpty)
        #expect(env.indexEntries.isEmpty)
        #expect(env.stateStore.readScheduleState() == nil, "no schedule-state write at all")
        #expect(
            !FileManager.default.fileExists(atPath: env.paths.setLockFile(setId: Self.setId).path),
            "the set lock must not even be created before the pre-flight passes"
        )
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil)
    }

    /// Regression test for the review finding that the engine's wording
    /// branched on `#if os(macOS)`. The `.retryable` reason is shown to the
    /// user and logged; on a host running the file backend it must point at
    /// the secrets file, not at a login keychain the host may not even have.
    @Test("row 9: the retryable reason names the store in use, not the host OS")
    func rowNineReasonFollowsTheBackend() async throws {
        for backend in SecretBackend.allCases {
            let env = Self.makeEnv(
                secretsUnavailableFor: [Self.primaryId],
                secretBackend: backend,
                script: []
            )
            defer { env.cleanUp() }

            let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

            guard case .retryable(let reason) = outcome else {
                Issue.record("expected .retryable, got \(outcome)")
                return
            }
            #expect(reason.hasPrefix(backend.displayName), "reason was: \(reason)")
            if backend == .file {
                #expect(!reason.lowercased().contains("keychain"), "reason was: \(reason)")
            }
        }
    }

    // MARK: - Row 10 — set lock busy

    @Test("row 10: set lock busy → one .skipped record and nothing else (no lastBackupStart)")
    func rowTenLockBusy() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()

        // A separate FileLock (separate open file description) genuinely
        // contends, even in-process — see FileLock's documentation.
        let holder = FileLock(path: env.paths.setLockFile(setId: Self.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        let outcome = await env.engine.runSet(env.set, trigger: .manual)

        #expect(outcome == .skipped)
        #expect(env.resticArgvs.isEmpty)
        let entries = env.indexEntries
        #expect(entries.count == 1)
        #expect(entries[0].kind == .backup)
        #expect(entries[0].status == .skipped)
        #expect(entries[0].trigger == .manual)
        #expect(
            env.stateStore.readScheduleState()?.sets[Self.setId]?.lastBackupStart == nil,
            "step 3 happens after the lock is taken — a busy lock must not consume the schedule slot"
        )
    }

    // MARK: - Row 10b — set lock unusable (#110)

    @Test("row 10b: an unusable set lock is a .failed record, not a .skipped one")
    func rowTenLockUnusable() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()

        // A directory where the set's lock *file* belongs. Chosen over
        // `chmod`-ing `locks/` so the fault is injectable as root too — the
        // Linux CI container runs as root, where mode bits are advisory and
        // a permissions-based injection would have to be skipped. Only the
        // lock path is touched, so the run store can still record what
        // happened; that is the whole point of the assertion below.
        try FileManager.default.createDirectory(
            at: env.paths.setLockFile(setId: Self.setId),
            withIntermediateDirectories: true
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        // Before #110 this was `.skipped` with a `.skipped` index record —
        // which `HealthDerivation` does not count, so the machine went on
        // reporting healthy while every scheduled backup silently did
        // nothing, forever.
        // `.infrastructureFailure`, distinct from `.misconfigured`: the
        // machine is broken, not the configuration, and only this case makes
        // the scheduled tick exit non-zero.
        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("a broken lock must not be reported as ordinary contention: \(outcome)")
            return
        }
        #expect(reason.contains("lock"))
        #expect(env.resticArgvs.isEmpty, "nothing may be spawned without the lock")

        let entries = env.indexEntries
        #expect(entries.count == 1)
        #expect(entries[0].kind == .backup)
        #expect(entries[0].status == .failed, "a .skipped record here is invisible to health derivation")
        #expect(entries[0].errorSummary?.contains("lock") == true)
        #expect(
            env.stateStore.readScheduleState()?.sets[Self.setId]?.lastBackupStart == nil,
            "a run that never started must not consume the schedule slot"
        )
    }

    @Test("an unusable schedule-state lock stops a backup before restic launches")
    func scheduleStateLockUnusableStopsBackup() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: env.paths.scheduleStateLockFile,
            withIntermediateDirectories: true
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("a backup without durable scheduling state must not run: \(outcome)")
            return
        }
        #expect(reason.contains("schedule state"))
        #expect(env.resticArgvs.isEmpty)
        #expect(env.entries(kind: .backup).first?.status == .failed)
    }

    /// The health consequence of the record above, asserted end to end
    /// rather than assumed: a `.failed` last run is what makes
    /// `hasWarningConditions` true, and therefore what makes `status --json`
    /// exit 1 instead of reporting an idle, healthy machine.
    @Test("row 10b: the recorded failure actually reaches health derivation")
    func rowTenLockUnusableIsUnhealthy() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: env.paths.setLockFile(setId: Self.setId),
            withIntermediateDirectories: true
        )

        _ = await env.engine.runSet(env.set, trigger: .scheduled)

        let health = HealthDerivation.setHealth(
            set: env.set,
            recentRuns: env.indexEntries.reversed(),
            currentRun: nil,
            repoStatuses: [:],
            setScheduleState: env.stateStore.readScheduleState()?.sets[Self.setId],
            now: Self.t0,
            calendar: Calendar(identifier: .gregorian)
        )
        #expect(health.lastRunFailed)
        #expect(health.needsAttention)
        #expect(
            HealthDerivation.hasWarningConditions(
                setHealths: [health],
                runsInFlight: [],
                fullDiskAccessDenied: false,
                backgroundAgentEnabled: true
            ),
            "status --json must exit 1 on a machine that cannot take its own locks"
        )
    }

    // MARK: - Row 11 — empty / absent retention

    @Test(
        "row 11: forget is never invoked without a non-empty retention policy",
        arguments: [nil, RetentionPolicy()] as [RetentionPolicy?]
    )
    func rowElevenEmptyRetention(retention: RetentionPolicy?) async throws {
        let env = Self.makeEnv(script: [], retention: retention, reachableSecondaries: [true])
        defer { env.cleanUp() }
        let secondary = env.secondaries[0]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryAId,
            from: Self.primaryId
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs.allSatisfy { !$0.contains("forget") })
        #expect(env.entries(kind: .prune).isEmpty)
        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)
        #expect(children.map(\.kind) == [.backup, .copy])
    }

    // MARK: - purgeExcludes reach `backup` as ordinary --exclude flags

    /// `set.effectiveBackupExcludes` — plain `excludes` followed by
    /// `purgeExcludes` — is what `backup` actually receives (issue #86, the
    /// purging-exclusions epic #85): a purge pattern is a forward-only
    /// exclude too, so
    /// `backup` must never re-capture what the purge phase just rewrote out
    /// of history.
    @Test("purgeExcludes: backup argv carries plain excludes, then purge excludes, as --exclude")
    func backupArgvCarriesPurgeExcludesAfterPlainExcludes() async throws {
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            excludes: ["node_modules", "*.tmp"],
            purgeExcludes: ["secrets/", "*.key"],
            reachableSecondaries: []
        )
        defer { env.cleanUp() }

        let expectedExcludes = ["node_modules", "*.tmp", "secrets/", "*.key"]
        #expect(env.set.effectiveBackupExcludes == expectedExcludes)

        let script = Self.resticCall(
            Self.backupArgv(env.primary.repoURL, excludes: expectedExcludes),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream()
        )
        env.fake.script = script

        // This case is about backup argv construction, not the scheduled
        // purge phase. Seed its already-applied watermark so no additional
        // repository commands obscure that assertion.
        try env.stateStore.updateScheduleState(setId: Self.setId) { state in
            for destination in env.set.destinations {
                state.appliedPurgeExcludes[destination.id] = Array(expectedExcludes.suffix(2))
            }
        }

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs == [[Self.resticPath] + Self.backupArgv(env.primary.repoURL, excludes: expectedExcludes)])
        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)
        #expect(children.map(\.kind) == [.backup])
    }

    // MARK: - Safety invariant: forget never targets an un-copied mirror

    @Test("safety: a mirror whose copy failed is never a forget target, even as the only secondary")
    func forgetNeverTargetsFailedCopy() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [true])
        defer { env.cleanUp() }
        let secondary = env.secondaries[0]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryAId,
            from: Self.primaryId,
            exitCode: 1
        )
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        env.fake.script = script

        _ = await env.engine.runSet(env.set, trigger: .scheduled)

        #expect(env.resticArgvs == [
            [Self.resticPath] + Self.backupArgv(env.primary.repoURL),
            [Self.resticPath] + Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
            [Self.resticPath] + Self.forgetArgv(env.primary.repoURL),
        ])
    }

    // MARK: - Safety invariant: every child's raw output reaches the run log

    @Test("safety: stdout AND stderr of every restic child land in that run's log")
    func rawOutputAlwaysLogged() async throws {
        let env = Self.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream(),
            stderr: "warning: could not read /Users/test/proj/socket",
            exitCode: 3
        )
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)
        guard case .completed(_, let groupId, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }

        let log = env.log(runId: groupId)
        #expect(log.contains("$ \(Self.resticPath) -r \(env.primary.repoURL) backup --json \(Self.source)"))
        for line in Self.backupStream() {
            #expect(log.contains(line))
        }
        #expect(log.contains("warning: could not read /Users/test/proj/socket"))
    }

    // MARK: - current-run lifecycle + throttling

    @Test("current-run is live during the run (phase per child) and deleted afterwards")
    func currentRunLifecycle() async throws {
        // Captured at the moment each restic child is spawned.
        final class Observed: @unchecked Sendable {
            let lock = NSLock()
            var states: [(argv: [String], state: CurrentRunState?)] = []
        }
        let observed = Observed()
        let statesBox = observed

        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            reachableSecondaries: [true],
            onSpawn: { argv in
                guard argv.first == Self.resticPath, let paths = paths.value else { return }
                let state = StateStore(paths: paths).readCurrentRun(setId: Self.setId)
                statesBox.lock.lock()
                statesBox.states.append((argv, state))
                statesBox.lock.unlock()
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        let secondary = env.secondaries[0]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        script += Self.resticCall(
            Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
            dest: Self.secondaryAId,
            from: Self.primaryId
        )
        script += Self.resticCall(Self.forgetArgv(secondary.repoURL), dest: Self.secondaryAId)
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        env.fake.script = script

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)
        guard case .completed(let status, let groupId, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)

        let phases = observed.states.map { $0.state?.phase }
        #expect(phases == [
            "backing-up-primary",
            "copying-\(secondary.id.uuidString)",
            "retention",
            "retention",
        ])
        #expect(observed.states.first?.state?.runId == groupId)
        // …and gone once the group finished.
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil)
    }

    @Test("progress writes are throttled to at most one per 1.5 s (injected clock)")
    func progressThrottling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-throttle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let stateStore = StateStore(paths: paths)
        let clock = TestClock(Self.t0)
        let reporter = ProgressReporter(
            stateStore: stateStore,
            setId: Self.setId,
            runId: "20260713T000000Z-backup-6f9619ff",
            kind: .backup,
            phase: "backing-up-primary",
            now: clock.now
        )

        func status(_ percent: Double) -> BackupStatus {
            let line = "{\"message_type\":\"status\",\"percent_done\":\(percent),\"bytes_done\":10}"
            guard case .status(let value) = ResticMessageDecoder().decodeLine(line) else {
                fatalError("fixture-shaped status line failed to decode")
            }
            return value
        }

        // A flood of ten status lines inside one 1.5 s window: only the first
        // reaches disk.
        for index in 1...10 {
            reporter.record(status(Double(index) / 10))
        }
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.percentDone == 0.1)
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.updatedAt == Self.t0)

        // Still inside the window (1.4 s) — still throttled.
        clock.advance(1.4)
        reporter.record(status(0.5))
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.percentDone == 0.1)

        // Past the window — the next status lands.
        clock.advance(0.1)
        reporter.record(status(0.7))
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.percentDone == 0.7)
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.updatedAt == Self.t0.addingTimeInterval(1.5))
    }

    @Test("heartbeat advances liveness without changing visible progress")
    func heartbeatPreservesProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-heartbeat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateStore = StateStore(paths: AppPaths(root: root))
        let clock = TestClock(Self.t0)
        let uptime = Box(100.0)
        let reporter = ProgressReporter(
            stateStore: stateStore,
            setId: Self.setId,
            runId: "heartbeat-run",
            kind: .check,
            phase: "checking",
            now: clock.now,
            uptime: { uptime.value },
            heartbeatInterval: 3_600
        )

        reporter.writePhaseMarker()
        reporter.startHeartbeat()
        defer { reporter.stopHeartbeat() }
        let initial = try #require(stateStore.readCurrentRun(setId: Self.setId))
        #expect(initial.updatedAt == Self.t0)
        #expect(initial.heartbeatAt == Self.t0)
        #expect(initial.heartbeatUptime == 100)

        clock.advance(60)
        uptime.value = 160
        reporter.writeHeartbeat()

        let heartbeating = try #require(stateStore.readCurrentRun(setId: Self.setId))
        #expect(heartbeating.updatedAt == initial.updatedAt)
        #expect(heartbeating.percentDone == initial.percentDone)
        #expect(heartbeating.phase == initial.phase)
        #expect(heartbeating.heartbeatAt == Self.t0.addingTimeInterval(60))
        #expect(heartbeating.heartbeatUptime == 160)

        reporter.stopHeartbeat()
        clock.advance(60)
        uptime.value = 220
        reporter.writeHeartbeat()
        #expect(stateStore.readCurrentRun(setId: Self.setId)?.heartbeatUptime == 160)
    }

    @Test("shouldWriteProgress: first write allowed, window enforced, backwards clock does not stall")
    func throttlePredicate() {
        #expect(BackupEngine.shouldWriteProgress(lastWriteAt: nil, now: Self.t0))
        #expect(!BackupEngine.shouldWriteProgress(lastWriteAt: Self.t0, now: Self.t0.addingTimeInterval(1.49)))
        #expect(BackupEngine.shouldWriteProgress(lastWriteAt: Self.t0, now: Self.t0.addingTimeInterval(1.5)))
        #expect(BackupEngine.shouldWriteProgress(lastWriteAt: Self.t0, now: Self.t0.addingTimeInterval(-60)))
    }

    // MARK: - Worst-status aggregation

    @Test("worstStatus picks failed > warning > success > skipped")
    func worstStatusAggregation() {
        #expect(BackupEngine.worstStatus([]) == .success)
        #expect(BackupEngine.worstStatus([.success, .success]) == .success)
        #expect(BackupEngine.worstStatus([.success, .warning]) == .warning)
        #expect(BackupEngine.worstStatus([.warning, .failed, .success]) == .failed)
        #expect(BackupEngine.worstStatus([.skipped, .success]) == .success)
    }

    // MARK: - Manual trigger

    @Test("a manual run also consumes the schedule slot and records trigger=manual")
    func manualRunUpdatesLastBackupStart() async throws {
        let env = Self.makeEnv(script: [], retention: nil, reachableSecondaries: [])
        defer { env.cleanUp() }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            Self.backupArgv(env.primary.repoURL), dest: Self.primaryId, stdoutLines: Self.backupStream()
        )
        env.fake.script = script

        _ = await env.engine.runSet(env.set, trigger: .manual)

        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.lastBackupStart == Self.t0)
        #expect(env.entries(kind: .backup).first?.trigger == .manual)
    }

    // MARK: - runCheck

    @Test("runCheck: slice rotation from the cursor, cursor persisted on success")
    func checkAdvancesCursorOnSuccess() async throws {
        let env = Self.makeEnv(
            script: [],
            checkPolicy: CheckPolicy(enabled: true, readDataSubsetSlices: 20),
            reachableSecondaries: []
        )
        defer { env.cleanUp() }
        try env.stateStore.updateScheduleState(setId: Self.setId) { state in
            state.checkSliceCursor = 7
            state.checkCount = 1
        }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            ["-r", env.primary.repoURL, "check", "--read-data-subset=8/20"],
            dest: Self.primaryId,
            stdoutLines: ["no errors were found"]
        )
        env.fake.script = script

        let outcome = await env.engine.runCheck(env.set)

        #expect(outcome == .completed(.success))
        #expect(env.resticArgvs == [
            [Self.resticPath, "-r", env.primary.repoURL, "check", "--read-data-subset=8/20"],
        ])
        let state = try #require(env.stateStore.readScheduleState()?.sets[Self.setId])
        #expect(state.checkSliceCursor == 8)
        #expect(state.checkCount == 2)
        #expect(state.lastCheckStart == Self.t0)
        let entry = try #require(env.entries(kind: .check).first)
        #expect(entry.status == .success)
        #expect(entry.destId == Self.primaryId)
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil)
    }

    @Test("safety: a failed check does NOT advance checkSliceCursor")
    func checkDoesNotAdvanceCursorOnFailure() async throws {
        let env = Self.makeEnv(
            script: [],
            checkPolicy: CheckPolicy(enabled: true, readDataSubsetSlices: 20),
            reachableSecondaries: []
        )
        defer { env.cleanUp() }
        try env.stateStore.updateScheduleState(setId: Self.setId) { state in
            state.checkSliceCursor = 7
            state.checkCount = 1
        }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            ["-r", env.primary.repoURL, "check", "--read-data-subset=8/20"],
            dest: Self.primaryId,
            stderr: "Fatal: repository contains errors",
            exitCode: 1
        )
        env.fake.script = script

        let outcome = await env.engine.runCheck(env.set)

        #expect(outcome == .completed(.failed))
        let state = try #require(env.stateStore.readScheduleState()?.sets[Self.setId])
        #expect(state.checkSliceCursor == 7, "the same slice must be re-verified next time")
        #expect(state.checkCount == 1)
        #expect(state.lastCheckStart == Self.t0, "the attempt still counts for scheduling")
        #expect(env.entries(kind: .check).first?.status == .failed)
    }

    @Test("runCheck: every 4th successful check also checks reachable secondaries, structure-only")
    func checkRotatesToSecondaries() async throws {
        let env = Self.makeEnv(
            script: [],
            checkPolicy: CheckPolicy(enabled: true, readDataSubsetSlices: 20),
            reachableSecondaries: [true, false]
        )
        defer { env.cleanUp() }
        let reachable = env.secondaries[0]
        try env.stateStore.updateScheduleState(setId: Self.setId) { state in
            state.checkSliceCursor = 3
            state.checkCount = 3 // this run is the 4th
        }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            ["-r", env.primary.repoURL, "check", "--read-data-subset=4/20"],
            dest: Self.primaryId,
            stdoutLines: ["no errors were found"]
        )
        script += Self.resticCall(
            ["-r", reachable.repoURL, "check"],
            dest: Self.secondaryAId,
            stdoutLines: ["no errors were found"]
        )
        env.fake.script = script

        let outcome = await env.engine.runCheck(env.set)

        #expect(outcome == .completed(.success))
        #expect(env.resticArgvs == [
            [Self.resticPath, "-r", env.primary.repoURL, "check", "--read-data-subset=4/20"],
            [Self.resticPath, "-r", reachable.repoURL, "check"],
        ], "secondaries are checked structure-only (no --read-data-subset), and only when reachable")

        let checks = env.entries(kind: .check)
        #expect(checks.count == 2)
        #expect(checks.allSatisfy { $0.groupId == checks[0].runId })
        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.checkCount == 4)
    }

    @Test("runCheck: set lock busy → .skipped record, no restic")
    func checkLockBusy() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let holder = FileLock(path: env.paths.setLockFile(setId: Self.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        let outcome = await env.engine.runCheck(env.set)

        #expect(outcome == .skipped)
        #expect(env.resticArgvs.isEmpty)
        #expect(env.entries(kind: .check).first?.status == .skipped)
        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.lastCheckStart == nil)
    }

    @Test("runCheck: an unusable set lock is infrastructure failure, not a failed check")
    func checkLockUnusable() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: env.paths.setLockFile(setId: Self.setId),
            withIntermediateDirectories: true
        )

        let outcome = await env.engine.runCheck(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("an unusable check lock must be a tick-failing infrastructure error: \(outcome)")
            return
        }
        #expect(reason.contains("lock"))
        #expect(env.resticArgvs.isEmpty)
        #expect(env.entries(kind: .check).first?.status == .failed)
        #expect(env.stateStore.readScheduleState()?.sets[Self.setId]?.lastCheckStart == nil)
    }

    // MARK: - runPrune

    @Test("runPrune: primary plus only mirrors that are at least as fresh as the primary")
    func pruneSkipsStaleMirrors() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        let stale = env.secondaries[0]
        let fresh = env.secondaries[1]

        try env.stateStore.updateRepoStatus(destId: env.primary.id) { $0.lastSyncedAt = Self.t0 }
        try env.stateStore.updateRepoStatus(destId: stale.id) {
            $0.lastSyncedAt = Self.t0.addingTimeInterval(-3600)
        }
        try env.stateStore.updateRepoStatus(destId: fresh.id) { $0.lastSyncedAt = Self.t0 }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        script += Self.resticCall(Self.forgetArgv(fresh.repoURL), dest: Self.secondaryBId)
        env.fake.script = script

        let status = await env.engine.runPrune(env.set)

        #expect(status == .success)
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil, "live progress is cleared afterwards")
        // SAFETY: the mirror that is behind the primary is never forgotten.
        #expect(env.resticArgvs == [
            [Self.resticPath] + Self.forgetArgv(env.primary.repoURL),
            [Self.resticPath] + Self.forgetArgv(fresh.repoURL),
        ])
        let prunes = env.entries(kind: .prune)
        #expect(prunes.count == 2)
        #expect(prunes.allSatisfy { $0.groupId == prunes[0].runId })
        #expect(prunes.allSatisfy { $0.trigger == .manual })
        #expect(prunes.allSatisfy { $0.destId != stale.id })
    }

    @Test("safety: no mirror is pruned when the primary has never completed a backup")
    func pruneSkipsAllMirrorsWithoutPrimarySync() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        // Mirrors claim a sync time; the primary has none.
        for secondary in env.secondaries {
            try env.stateStore.updateRepoStatus(destId: secondary.id) { $0.lastSyncedAt = Self.t0 }
        }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)
        env.fake.script = script

        let status = await env.engine.runPrune(env.set)

        #expect(status == .success)
        #expect(env.resticArgvs == [[Self.resticPath] + Self.forgetArgv(env.primary.repoURL)])
    }

    @Test("runPrune: a terminal run-index failure cannot report success")
    func pruneIndexFailureCannotReportSuccess() async throws {
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            reachableSecondaries: [],
            onSpawn: { argv in
                guard argv.contains("forget"), let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.runsIndexLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.runsIndexLockFile,
                    withIntermediateDirectories: true
                )
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        env.fake.script = Self.resticCall(Self.forgetArgv(env.primary.repoURL), dest: Self.primaryId)

        let status = await env.engine.runPrune(env.set)

        #expect(status == .failed)
        #expect(env.indexEntries.isEmpty)
    }

    @Test(
        "safety: runPrune with an empty or absent policy spawns nothing at all",
        arguments: [nil, RetentionPolicy()] as [RetentionPolicy?]
    )
    func pruneRefusesEmptyPolicy(retention: RetentionPolicy?) async throws {
        let env = Self.makeEnv(script: [], retention: retention)
        defer { env.cleanUp() }

        let status = await env.engine.runPrune(env.set)

        #expect(status == .skipped)
        #expect(env.fake.invocations.isEmpty, "nothing spawned — the guard is the first thing checked")
        #expect(env.indexEntries.isEmpty)
    }

    @Test("standalone prune: a set with no retention can reclaim primary space")
    func standalonePruneAllowsNoRetention() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.fake.script = Self.resticCall(["-r", env.primary.repoURL, "prune"], dest: Self.primaryId)

        let status = await env.engine.runPruneRepository(set: env.set, destination: env.primary)

        #expect(status == .completed(.success))
        #expect(env.resticArgvs == [[Self.resticPath, "-r", env.primary.repoURL, "prune"]])
        #expect(env.entries(kind: .prune).count == 1)
    }

    @Test("standalone prune: a terminal run-index failure cannot report success")
    func standalonePruneIndexFailureCannotReportSuccess() async throws {
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            onSpawn: { argv in
                guard argv.contains("prune"), let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.runsIndexLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.runsIndexLockFile,
                    withIntermediateDirectories: true
                )
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        env.fake.script = Self.resticCall(["-r", env.primary.repoURL, "prune"], dest: Self.primaryId)

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary)

        guard case .failed(.infrastructure(let reason)) = result else {
            Issue.record("a missing terminal index entry must fail standalone prune: \(result)")
            return
        }
        #expect(reason.contains("run history unusable"))
        #expect(env.indexEntries.isEmpty)
    }

    @Test("standalone prune: launch and terminal-index failures stay outcome-neutral")
    func standalonePruneLaunchAndIndexFailuresStayOutcomeNeutral() async throws {
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            onSpawn: { argv in
                guard argv.contains("prune"), let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.runsIndexLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.runsIndexLockFile,
                    withIntermediateDirectories: true
                )
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        env.fake.script = [
            .init(
                argvPrefix: [Self.resticPath, "-r", env.primary.repoURL, "prune"],
                failure: .launchFailed("restic disappeared")
            ),
        ]

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary)

        guard case .failed(.infrastructure(let reason)) = result else {
            Issue.record("combined launch/index failure must stay infrastructure failure: \(result)")
            return
        }
        #expect(reason.contains("run history unusable"))
        #expect(env.indexEntries.isEmpty)
    }

    @Test("standalone remote prune: a terminal run-index failure cannot report success")
    func standaloneRemotePruneIndexFailureCannotReportSuccess() async throws {
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            onSpawn: { argv in
                guard argv.contains(where: { $0.contains("prune") }),
                      let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.runsIndexLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.runsIndexLockFile,
                    withIntermediateDirectories: true
                )
            }
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo with space"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true, remoteResticPath: "/opt/restic")
        var set = env.set
        set.destinations[0] = destination
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(
                    sshTarget: "backup@example",
                    resticPath: "/opt/restic"
                ).argv,
                stdoutLines: ["{\"version\":\"0.18.1\"}"]
            ),
            .init(
                argvPrefix: RemoteResticCommand(
                    sshTarget: "backup@example",
                    resticPath: "/opt/restic",
                    repoPath: "/srv/repo with space",
                    dryRun: false,
                    password: "repo-password"
                ).argv
            ),
        ]

        let result = await env.engine.runPruneRepository(set: set, destination: destination)

        guard case .failed(.infrastructure(let reason)) = result else {
            Issue.record("a missing terminal index entry must fail remote prune: \(result)")
            return
        }
        #expect(reason.contains("run history unusable"))
        #expect(env.indexEntries.isEmpty)
    }

    @Test("standalone prune: SFTP remote maintenance verifies SSH then never falls back locally")
    func standalonePruneUsesRemoteSFTPOnly() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo with space"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true, remoteResticPath: "/opt/restic")
        var set = env.set
        set.destinations[0] = destination
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "/opt/restic").argv,
                stdoutLines: ["{\"version\":\"0.18.1\"}"]
            ),
            .init(
                argvPrefix: RemoteResticCommand(
                    sshTarget: "backup@example", resticPath: "/opt/restic", repoPath: "/srv/repo with space", dryRun: false,
                    password: "repo-password"
                ).argv
            ),
        ]

        let status = await env.engine.runPruneRepository(set: set, destination: destination)

        #expect(status == .completed(.success))
        #expect(env.fake.invocations.count == 2)
        #expect(env.fake.invocations.allSatisfy { $0.argv.first == "/usr/bin/ssh" })
        #expect(env.fake.invocations[0].stdin == nil)
        #expect(env.fake.invocations[1].stdin == Data("repo-password\n".utf8))
        #expect(env.fake.invocations[1].argv.joined(separator: " ").contains("repo-password") == false)
        #expect(env.resticArgvs.isEmpty, "remote maintenance must not fall back to local restic")
        let prune = try #require(env.entries(kind: .prune).first)
        #expect(env.log(runId: prune.runId).contains("repo-password") == false)
    }

    @Test("standalone prune: unavailable SFTP remote maintenance never starts local restic")
    func standalonePruneRemoteSFTPUnavailableDoesNotFallBack() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true)
        var set = env.set
        set.destinations[0] = destination
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "restic").argv,
                exitCode: 1
            ),
        ]

        let status = await env.engine.runPruneRepository(set: set, destination: destination)

        #expect(status == .failed(.didNotRun))
        #expect(env.fake.invocations.count == 1)
        #expect(env.fake.invocations[0].argv.first == "/usr/bin/ssh")
        #expect(env.resticArgvs.isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
    }

    @Test("standalone prune: an SSH launch failure restores the remote-maintenance preview token")
    func standalonePruneRemoteSFTPLaunchFailureRestoresPreviewToken() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true)
        var set = env.set
        set.destinations[0] = destination
        let fingerprint = destination.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: set.id,
            destinationId: destination.id,
            effectiveDestinationFingerprint: fingerprint
        )
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "restic").argv,
                stdoutLines: ["{\"version\":\"0.18.1\"}"]
            ),
            .init(
                argvPrefix: RemoteResticCommand(
                    sshTarget: "backup@example", resticPath: "restic", repoPath: "/srv/repo", dryRun: false,
                    password: "repo-password"
                ).argv,
                failure: .launchFailed("ssh disappeared")
            ),
        ]

        let status = await env.engine.runPruneRepository(
            set: set,
            destination: destination,
            authorization: MaintenancePruneAuthorization(
                token: token,
                machineId: env.machineId,
                effectiveDestinationFingerprint: fingerprint
            )
        )

        #expect(status == .failed(.didNotRun))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
        #expect(env.fake.invocations.allSatisfy { $0.argv.first == "/usr/bin/ssh" })
    }

    @Test("standalone prune: unavailable SFTP confirmation remains retryable")
    func standalonePruneRemoteSFTPUnavailableConfirmationRemainsRetryable() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true)
        var set = env.set
        set.destinations[0] = destination
        let fingerprint = destination.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: set.id,
            destinationId: destination.id,
            effectiveDestinationFingerprint: fingerprint
        )
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "restic").argv,
                stdoutLines: ["{\"version\":\"0.18.1\"}"]
            ),
        ]
        try env.paths.ensureDirectories()
        let heldTokenStoreLock = FileLock(path: env.paths.previewTokensLockFile)
        #expect(heldTokenStoreLock.acquire() == .acquired)

        let status = await env.engine.runPruneRepository(
            set: set,
            destination: destination,
            authorization: MaintenancePruneAuthorization(
                token: token,
                machineId: env.machineId,
                effectiveDestinationFingerprint: fingerprint
            )
        )
        heldTokenStoreLock.release()

        #expect(status == .skipped(.previewUnavailable))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
        #expect(env.fake.invocations.count == 1, "SSH prune must not launch when confirmation storage is busy")
    }

    @Test("standalone prune: remote restic failures retain their exit classification")
    func standalonePruneRemoteSFTPRetainsResticFailureClassification() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        var destination = env.primary
        destination.repoURL = "sftp:backup@example:/srv/repo"
        destination.remoteMaintenance = RemoteMaintenance(enabled: true)
        var set = env.set
        set.destinations[0] = destination
        env.fake.script = [
            .init(
                argvPrefix: RemoteResticCommand.version(sshTarget: "backup@example", resticPath: "restic").argv,
                stdoutLines: ["{\"version\":\"0.18.1\"}"]
            ),
            .init(
                argvPrefix: RemoteResticCommand(
                    sshTarget: "backup@example", resticPath: "restic", repoPath: "/srv/repo", dryRun: false,
                    password: "repo-password"
                ).argv,
                exitCode: 11
            ),
        ]

        let status = await env.engine.runPruneRepository(set: set, destination: destination)

        #expect(status == .failed(.restic(.repoLocked)))
    }

    @Test("standalone prune: automatic unlock reuses its confirmed secret snapshot")
    func standalonePruneUnlockUsesConfirmedSecretSnapshot() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let snapshot = ["RESTIC_PASSWORD": "previewed-password", "RCLONE_CONFIG_REMOTE": "previewed-remote"]
        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(["-r", env.primary.repoURL, "prune"], dest: Self.primaryId, exitCode: 11)
        script += Self.resticCall(["-r", env.primary.repoURL, "unlock"], dest: Self.primaryId)
        script += Self.resticCall(["-r", env.primary.repoURL, "prune"], dest: Self.primaryId)
        env.fake.script = script

        let status = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            destinationSecretEnv: snapshot
        )

        #expect(status == .completed(.success))
        let resticInvocations = env.fake.invocations.filter { $0.argv.first == Self.resticPath }
        #expect(resticInvocations.count == 3)
        #expect(resticInvocations[1].env == resticInvocations[0].env)
        #expect(resticInvocations[1].env == resticInvocations[2].env)
    }

    @Test("standalone prune: a stale mirror is never touched or consumes its preview token")
    func standalonePruneRefusesStaleMirror() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let mirror = env.secondaries[0]
        let fingerprint = mirror.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: env.set.id,
            destinationId: mirror.id,
            effectiveDestinationFingerprint: fingerprint
        )
        let authorization = MaintenancePruneAuthorization(
            token: token,
            machineId: env.machineId,
            effectiveDestinationFingerprint: fingerprint
        )
        try env.stateStore.updateRepoStatus(destId: env.primary.id) { $0.lastSyncedAt = Self.t0 }
        try env.stateStore.updateRepoStatus(destId: mirror.id) {
            $0.lastSyncedAt = Self.t0.addingTimeInterval(-1)
        }

        let status = await env.engine.runPruneRepository(
            set: env.set,
            destination: mirror,
            authorization: authorization
        )

        #expect(status == .skipped(.staleMirror))
        #expect(env.fake.invocations.isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
    }

    @Test("standalone prune: dry run never spawns a modifying restic command")
    func standalonePruneDryRunIsReadOnly() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        env.fake.script = Self.resticCall(["-r", env.primary.repoURL, "prune", "--dry-run"], dest: Self.primaryId)

        let status = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            dryRun: true
        )

        #expect(status == .completed(.success))
        #expect(env.resticArgvs == [[Self.resticPath, "-r", env.primary.repoURL, "prune", "--dry-run"]])
        #expect(env.resticArgvs.allSatisfy { $0.contains("--dry-run") })
        #expect(env.entries(kind: .prune).isEmpty, "a preview must not replace the last real prune run")
    }

    @Test("standalone prune: a busy dry run is also absent from history")
    func standalonePruneBusyDryRunIsUnrecorded() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let heldLock = FileLock(path: env.paths.setLockFile(setId: env.set.id))
        #expect(heldLock.acquire() == .acquired)
        defer { heldLock.release() }

        let result = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            dryRun: true
        )

        #expect(result == .skipped(.busy))
        #expect(env.fake.invocations.isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
    }

    @Test("standalone prune: a busy confirmation does not consume its preview token")
    func standalonePruneBusyConfirmationRetainsItsPreviewToken() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let fingerprint = env.primary.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: env.set.id,
            destinationId: env.primary.id,
            effectiveDestinationFingerprint: fingerprint
        )
        let authorization = MaintenancePruneAuthorization(
            token: token,
            machineId: env.machineId,
            effectiveDestinationFingerprint: fingerprint
        )
        try env.paths.ensureDirectories()
        let heldLock = FileLock(path: env.paths.setLockFile(setId: env.set.id))
        #expect(heldLock.acquire() == .acquired)

        let busy = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: authorization
        )
        heldLock.release()

        #expect(busy == .skipped(.busy))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)

        env.fake.script = Self.resticCall(["-r", env.primary.repoURL, "prune"], dest: Self.primaryId)
        let completed = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: authorization
        )
        #expect(completed == .completed(.success))
    }

    @Test("standalone prune: an invalid confirmation remains previewChanged")
    func standalonePruneInvalidConfirmationIsPreviewChanged() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let result = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: MaintenancePruneAuthorization(
                token: "not-a-preview-token",
                machineId: env.machineId,
                effectiveDestinationFingerprint: env.primary.pruneConfirmationFingerprint(secretEnv: [:])
            )
        )

        #expect(result == .skipped(.previewChanged))
        #expect(env.fake.invocations.isEmpty)
    }

    @Test("standalone prune: token-store contention preserves the preview for retry")
    func standalonePruneUnavailableConfirmationRetainsItsPreviewToken() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let fingerprint = env.primary.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: env.set.id,
            destinationId: env.primary.id,
            effectiveDestinationFingerprint: fingerprint
        )
        try env.paths.ensureDirectories()
        let heldTokenStoreLock = FileLock(path: env.paths.previewTokensLockFile)
        #expect(heldTokenStoreLock.acquire() == .acquired)

        let result = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: MaintenancePruneAuthorization(
                token: token,
                machineId: env.machineId,
                effectiveDestinationFingerprint: fingerprint
            )
        )
        heldTokenStoreLock.release()

        #expect(result == .skipped(.previewUnavailable))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
        #expect(env.fake.invocations.isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
    }

    @Test("standalone prune: a launch-time secret failure retains its preview token")
    func standalonePruneSecretFailureRetainsItsPreviewToken() async throws {
        let env = Self.makeEnv(secretsUnavailableFor: [Self.primaryId], script: [], retention: nil)
        defer { env.cleanUp() }
        let fingerprint = env.primary.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: env.set.id,
            destinationId: env.primary.id,
            effectiveDestinationFingerprint: fingerprint
        )

        let result = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: MaintenancePruneAuthorization(
                token: token,
                machineId: env.machineId,
                effectiveDestinationFingerprint: fingerprint
            )
        )

        #expect(result == .skipped(.secretUnavailable))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
        #expect(env.fake.invocations.isEmpty)
    }

    @Test("standalone prune: a process launch failure restores its preview token")
    func standalonePruneLaunchFailureRestoresItsPreviewToken() async throws {
        let env = Self.makeEnv(script: [], retention: nil)
        defer { env.cleanUp() }
        let fingerprint = env.primary.pruneConfirmationFingerprint(secretEnv: [:])
        let token = try PreviewTokenStore(paths: env.paths).issueMaintenancePrune(
            machineId: env.machineId,
            setId: env.set.id,
            destinationId: env.primary.id,
            effectiveDestinationFingerprint: fingerprint
        )
        env.fake.script = [
            .init(
                argvPrefix: [Self.resticPath, "-r", env.primary.repoURL, "prune"],
                failure: .launchFailed("restic disappeared")
            ),
        ]

        let result = await env.engine.runPruneRepository(
            set: env.set,
            destination: env.primary,
            authorization: MaintenancePruneAuthorization(
                token: token,
                machineId: env.machineId,
                effectiveDestinationFingerprint: fingerprint
            )
        )

        #expect(result == .failed(.didNotRun))
        #expect(try PreviewTokenStore(paths: env.paths).token(token).value == token)
        #expect(env.resticArgvs == [[Self.resticPath, "-r", env.primary.repoURL, "prune"]])
    }

    @Test("standalone prune: an unavailable secret is distinguished from success")
    func standalonePruneReportsSecretUnavailable() async throws {
        let env = Self.makeEnv(secretsUnavailableFor: [Self.primaryId], script: [], retention: nil)
        defer { env.cleanUp() }

        let result = await env.engine.runPruneRepository(set: env.set, destination: env.primary)

        #expect(result == .skipped(.secretUnavailable))
        #expect(env.fake.invocations.isEmpty)
        #expect(env.entries(kind: .prune).isEmpty)
    }

    @Test("standalone prune: offline and restic failures retain their classifications")
    func standalonePruneRetainsFailureClassification() async throws {
        let offline = Self.makeEnv(script: [], retention: nil, primaryReachable: false)
        defer { offline.cleanUp() }
        let offlineResult = await offline.engine.runPruneRepository(set: offline.set, destination: offline.primary)
        guard case .failed(.offline) = offlineResult else {
            Issue.record("expected offline result, got \(offlineResult)")
            return
        }
        #expect(offline.fake.invocations.isEmpty)

        let locked = Self.makeEnv(script: [], retention: nil)
        defer { locked.cleanUp() }
        var lockedScript = Self.resticCall(
            ["-r", locked.primary.repoURL, "prune"],
            dest: Self.primaryId,
            exitCode: 11
        )
        lockedScript += Self.resticCall(["-r", locked.primary.repoURL, "unlock"], dest: Self.primaryId)
        lockedScript += Self.resticCall(
            ["-r", locked.primary.repoURL, "prune"],
            dest: Self.primaryId,
            exitCode: 11
        )
        locked.fake.script = lockedScript

        let lockedResult = await locked.engine.runPruneRepository(set: locked.set, destination: locked.primary)

        #expect(lockedResult == .failed(.restic(.repoLocked)))
    }

    // MARK: - purge preview

    /// The destructive path starts with an already-reviewed plan. These
    /// tests deliberately build it from the captured snapshots fixture so
    /// the only ids a `rewrite --forget` can ever receive are the pure
    /// attribution result, never a caller-supplied filter.
    /// The purge token binds the restic executable's identity, but binding is
    /// only meaningful if the validated executable is the one that actually
    /// receives `rewrite --forget`. It was not: the destructive child was
    /// launched with an unpinned invocation, so a binary swapped after
    /// validation — the window includes `currentPurgePlan`'s repository
    /// queries, which are slow — would have run under an already-consumed
    /// token.
    @Test("runPurge: a restic replaced after validation never receives the rewrite")
    func purgeApplyRefusesASwappedExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeRestic = root.appendingPathComponent("restic", isDirectory: false)
        try Data("original restic".utf8).write(to: fakeRestic)

        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        // Swap the binary from inside the `snapshots` spawn — i.e. *after*
        // the token fingerprint has been revalidated (an earlier swap is
        // already refused as `tokenDoesNotMatchCurrentPlan`) and while
        // `currentPurgePlan` is querying the repository. Only a recheck at
        // launch can catch this one.
        let swapPath = fakeRestic.path
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            onSpawn: { argv in
                guard argv.contains("snapshots") else { return }
                try? Data("a different restic entirely".utf8)
                    .write(to: URL(fileURLWithPath: swapPath))
            },
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames,
            resticPath: fakeRestic.path
        )
        defer { env.cleanUp() }

        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!,
            patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))

        // Built against the injected path, not the shared `resticPath` helper.
        env.fake.script = [
            .init(
                argvPrefix: [fakeRestic.path, "-r", env.primary.repoURL, "snapshots", "--json"],
                stdoutLines: [snapshotsJSON]
            ),
        ]

        let result = try await env.engine.runPurge(
            set: env.set, destinations: [env.primary], token: token.value
        )

        #expect(result.status == .failed)
        // The decisive assertion: no rewrite argv was ever produced.
        #expect(!env.resticArgvs.contains { $0.contains("rewrite") })
    }

    // MARK: - #109 exact-head review: no unbound destructive capability

    /// The token issuer used to accept a missing executable and fold it to
    /// the literal `"none"`. A token minted that way bound no binary at all,
    /// and an apply that also saw no restic recomputed the same `"none"`
    /// fingerprint and matched — so a replacement appearing in between could
    /// run `rewrite --forget` unpinned.
    @Test("purge preview mints no token at all when restic has vanished")
    func purgeTokenRefusesWithoutAnExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-purge-noexec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeRestic = root.appendingPathComponent("restic", isDirectory: false)
        try Data("original restic".utf8).write(to: fakeRestic)

        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames,
            resticPath: fakeRestic.path
        )
        defer { env.cleanUp() }

        let snapshots = try parseSnapshots(Data(try FixtureLoader.string("snapshots.json").utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!,
            patterns: env.set.purgeExcludes
        )

        // The preview queries have completed; restic disappears before the
        // capability is minted. That is the window the finding describes.
        try FileManager.default.removeItem(at: fakeRestic)

        #expect(throws: PurgeApplyError.resticUnavailable) {
            _ = try env.engine.issuePurgeToken(
                set: env.set, destinations: [env.primary], plans: [plan]
            )
        }
    }

    /// The other half: even a token minted while restic existed must not be
    /// honoured once it cannot be identified at apply time. Without this the
    /// nil-bound fingerprint compared equal and `purgeChild` was launched
    /// with no `expectedExecutableIdentity`.
    @Test("purge apply refuses a token when restic cannot be identified")
    func purgeApplyRefusesWithoutAnExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-purge-noexec2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeRestic = root.appendingPathComponent("restic", isDirectory: false)
        try Data("original restic".utf8).write(to: fakeRestic)

        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames,
            resticPath: fakeRestic.path
        )
        defer { env.cleanUp() }

        let snapshots = try parseSnapshots(Data(try FixtureLoader.string("snapshots.json").utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!,
            patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))

        try FileManager.default.removeItem(at: fakeRestic)

        await #expect(throws: PurgeApplyError.resticUnavailable) {
            _ = try await env.engine.runPurge(
                set: env.set, destinations: [env.primary], token: token.value
            )
        }
        // The decisive assertion, as elsewhere in this suite: nothing
        // destructive was ever spawned.
        #expect(!env.resticArgvs.contains { $0.contains("rewrite") })
    }

    /// The pin added in `9d47b55` reads the executable identity through a
    /// metadata-keyed cache. An updater that overwrites restic in place,
    /// writes the same number of bytes and restores the original mtime
    /// leaves device, inode, size and mtime untouched — so the cache key is
    /// unchanged, the launch check compares the *previous* digest to itself,
    /// and the replacement binary receives `rewrite --forget`.
    ///
    /// The mtime is pinned to a fixed whole-second value on **both** writes
    /// rather than captured and restored. A captured mtime does not
    /// round-trip: `setAttributes` loses sub-microsecond precision, so the
    /// key changes, the cache misses, and the test passes without ever
    /// exercising the path it is about. It did exactly that on first
    /// writing.
    @Test("a same-size, same-mtime in-place swap still fails the destructive launch check")
    func purgeRefusesACacheDefeatingSwap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-purge-swap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeRestic = root.appendingPathComponent("restic", isDirectory: false)
        let pinnedMtime = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("original restic!".utf8).write(to: fakeRestic)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime], ofItemAtPath: fakeRestic.path
        )

        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let swapPath = fakeRestic.path
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            onSpawn: { argv in
                guard argv.contains("snapshots") else { return }
                // Same inode, same 16-byte length, same pinned mtime: every
                // field of the cache key is identical to the entry the
                // preview populated, so a cached lookup returns the *old*
                // digest for genuinely different bytes.
                let handle = FileHandle(forWritingAtPath: swapPath)
                try? handle?.write(contentsOf: Data("a totally other!".utf8))
                try? handle?.close()
                try? FileManager.default.setAttributes(
                    [.modificationDate: pinnedMtime], ofItemAtPath: swapPath
                )
            },
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames,
            resticPath: fakeRestic.path
        )
        defer { env.cleanUp() }

        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!,
            patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))

        env.fake.script = [
            .init(
                argvPrefix: [fakeRestic.path, "-r", env.primary.repoURL, "snapshots", "--json"],
                stdoutLines: [snapshotsJSON]
            ),
        ]

        let result = try await env.engine.runPurge(
            set: env.set, destinations: [env.primary], token: token.value
        )

        #expect(result.status == .failed)
        #expect(
            !env.resticArgvs.contains { $0.contains("rewrite") },
            "a cache-defeating in-place swap must not reach the destructive command"
        )
    }

    @Test("runPurge: a valid token revalidates ids, records rewrite mapping, and is single-use")
    func purgeApplyUsesTokenAndRecordsMapping() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }

        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!, patterns: env.set.purgeExcludes
        )
        let token = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))
        // A repository can hold snapshots from another backup set. Fresh
        // validation sees this one, but attribution declines it and its id
        // must never reach the destructive argv.
        let foreignSnapshot = "{\"time\":\"2026-07-26T16:57:06Z\",\"id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"short_id\":\"aaaaaaaa\",\"paths\":[\"/unrelated\"],\"hostname\":\"other-machine\",\"username\":\"other\"}"
        let snapshotsAtApply = String(snapshotsJSON.trimmingCharacters(in: .whitespacesAndNewlines).dropLast())
            + ",\(foreignSnapshot)]"
        let rewrite = try FixtureLoader.string("rewrite-forget.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        env.fake.script = Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [snapshotsAtApply]
        ) + Self.resticCall(
            Self.rewriteArgv(env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes),
            dest: Self.primaryId, stdoutLines: rewrite.split(separator: "\n").map(String.init)
        )

        let result = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: token.value)

        #expect(result.status == .success)
        #expect(env.resticArgvs == [
            [Self.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"],
            [Self.resticPath] + Self.rewriteArgv(
                env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes
            ),
        ])
        let purgeRun = try #require(env.entries(kind: .purge).first)
        let metadata = try env.runStore.metadata(runId: purgeRun.runId)
        #expect(metadata.purgeSnapshotRewrites?[snapshots[0].id] == "14a53542")
        #expect(metadata.purgeSnapshotRewrites?[snapshots[1].id] == "3ca2e0a5")
        #expect(!env.log(runId: purgeRun.runId).contains(token.value))
        #expect(env.resticArgvs.last?.contains("aaaaaaaa") == false)

        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: token.value)
            Issue.record("a consumed token must be refused")
        } catch let error as PurgeApplyError {
            #expect(error == .token(.alreadyUsed))
        }
        #expect(env.resticArgvs.count == 2, "a replay must not spawn restic")
    }

    @Test("runPurge: absent, expired, and changed snapshot-list tokens fail closed")
    func purgeApplyRefusesInvalidTokens() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let plan = PurgePlan(
            destinationId: env.primary.id, snapshots: snapshots,
            sourcePaths: sourcePaths[Self.setId]!, hostnames: hostnames[Self.setId]!, patterns: env.set.purgeExcludes
        )

        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: "")
            Issue.record("an absent token must be refused")
        } catch let error as PurgeApplyError {
            #expect(error == .token(.unknown))
        }

        let expired = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))
        env.clock.advance(PreviewTokenStore.defaultLifetime + 1)
        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: expired.value)
            Issue.record("an expired token must be refused")
        } catch let error as PurgeApplyError {
            #expect(error == .token(.expired))
        }

        let changed = try #require(try env.engine.issuePurgeToken(
            set: env.set, destinations: [env.primary], plans: [plan]
        ))
        var snapshotObjects = try #require(JSONSerialization.jsonObject(with: Data(snapshotsJSON.utf8)) as? [[String: Any]])
        snapshotObjects.removeLast()
        let changedSnapshots = String(
            decoding: try JSONSerialization.data(withJSONObject: snapshotObjects), as: UTF8.self
        )
        env.fake.script = Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [changedSnapshots]
        )
        do {
            _ = try await env.engine.runPurge(set: env.set, destinations: [env.primary], token: changed.value)
            Issue.record("a changed snapshot list must be refused")
        } catch let error as PurgeApplyError {
            #expect(error == .tokenDoesNotMatchCurrentPlan)
        }
        #expect(env.resticArgvs == [[Self.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"]])
        #expect(env.entries(kind: .purge).isEmpty, "failed validation cannot create a purge run")
    }

    @Test("row purge 1: scheduled primary and stale secondary purge before copy exactly once")
    func automaticPurgePrecedesCopy() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [true],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let rewrite = try FixtureLoader.string("rewrite-forget.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        let rewriteLines = rewrite.split(separator: "\n").map(String.init)
        let secondary = env.secondaries[0]
        env.fake.script = Self.resticCall(Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes), dest: Self.primaryId, stdoutLines: Self.backupStream())
            + Self.resticCall(["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [snapshotsJSON])
            + Self.resticCall(["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [snapshotsJSON])
            + Self.resticCall(Self.rewriteArgv(env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes), dest: Self.primaryId, stdoutLines: rewriteLines)
            + Self.resticCall(["-r", secondary.repoURL, "snapshots", "--json"], dest: secondary.id, stdoutLines: [snapshotsJSON])
            + Self.resticCall(["-r", secondary.repoURL, "snapshots", "--json"], dest: secondary.id, stdoutLines: [snapshotsJSON])
            + Self.resticCall(Self.rewriteArgv(secondary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes), dest: secondary.id, stdoutLines: rewriteLines)
            + Self.resticCall(Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL), dest: secondary.id, from: env.primary.id)

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        let expectedArgvs: [[String]] = [
            [Self.resticPath] + Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes),
            [Self.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"],
            [Self.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"],
            [Self.resticPath] + Self.rewriteArgv(env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes),
            [Self.resticPath, "-r", secondary.repoURL, "snapshots", "--json"],
            [Self.resticPath, "-r", secondary.repoURL, "snapshots", "--json"],
            [Self.resticPath] + Self.rewriteArgv(secondary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes),
            [Self.resticPath] + Self.copyArgv(to: secondary.repoURL, from: env.primary.repoURL),
        ]
        #expect(env.resticArgvs == expectedArgvs)
        guard case .completed(let status, _, let children) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .success)
        #expect(children.map(\.kind) == [.backup, .purge, .purge, .copy])
        let applied = env.stateStore.readScheduleState()?.sets[Self.setId]?.appliedPurgeExcludes
        #expect(applied?[env.primary.id] == env.set.purgeExcludes)
        #expect(applied?[secondary.id] == env.set.purgeExcludes)
    }

    @Test("automatic purge: unusable preview-token storage is an infrastructure failure")
    func automaticPurgeTokenStoreFailureIsInfrastructureFailure() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        try env.paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: env.paths.previewTokensLockFile,
            withIntermediateDirectories: true
        )
        env.fake.script = Self.resticCall(
            Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream()
        ) + Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"],
            dest: Self.primaryId,
            stdoutLines: [snapshotsJSON]
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("an unusable token store must fail the scheduled tick: \(outcome)")
            return
        }
        #expect(reason.contains("preview-token store unusable"))
        #expect(env.resticArgvs.count == 2)
    }

    @Test("a secondary purge infrastructure failure does not skip later independent work")
    func secondaryPurgeInfrastructureFailureContinuesOtherDestinations() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], purgeExcludes: ["build/**"], reachableSecondaries: [true, true],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let failing = env.secondaries[0]
        let healthy = env.secondaries[1]
        try env.stateStore.updateScheduleState(setId: Self.setId) { state in
            state.appliedPurgeExcludes[env.primary.id] = env.set.purgeExcludes
            state.appliedPurgeExcludes[healthy.id] = env.set.purgeExcludes
        }
        try FileManager.default.createDirectory(
            at: env.paths.previewTokensLockFile,
            withIntermediateDirectories: true
        )
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        env.fake.script = Self.resticCall(
            Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream()
        ) + Self.resticCall(
            ["-r", failing.repoURL, "snapshots", "--json"],
            dest: failing.id,
            stdoutLines: [snapshotsJSON]
        ) + Self.resticCall(
            Self.copyArgv(to: healthy.repoURL, from: env.primary.repoURL),
            dest: healthy.id,
            from: env.primary.id
        ) + Self.resticCall(
            Self.forgetArgv(healthy.repoURL), dest: healthy.id
        ) + Self.resticCall(
            Self.forgetArgv(env.primary.repoURL), dest: env.primary.id
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("the aggregate outcome must retain the infrastructure failure: \(outcome)")
            return
        }
        #expect(reason.contains("preview-token store unusable"))
        #expect(env.resticArgvs.contains([Self.resticPath] + Self.copyArgv(
            to: healthy.repoURL, from: env.primary.repoURL
        )))
        #expect(env.resticArgvs.contains([Self.resticPath] + Self.forgetArgv(healthy.repoURL)))
        #expect(env.resticArgvs.contains([Self.resticPath] + Self.forgetArgv(env.primary.repoURL)))
        #expect(!env.resticArgvs.contains { $0.contains("copy") && $0.contains(failing.repoURL) })
    }

    @Test("automatic purge: a successful rewrite without a durable watermark is infrastructure failure")
    func automaticPurgeWatermarkFailureIsInfrastructureFailure() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let paths = Box<AppPaths?>(nil)
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [],
            onSpawn: { argv in
                guard argv.contains("rewrite"),
                      !argv.contains("--dry-run"),
                      let paths = paths.value else { return }
                try? FileManager.default.removeItem(at: paths.scheduleStateLockFile)
                try? FileManager.default.createDirectory(
                    at: paths.scheduleStateLockFile,
                    withIntermediateDirectories: true
                )
            },
            purgeSourcePaths: sourcePaths,
            purgeHostnames: hostnames
        )
        paths.value = env.paths
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let rewrite = try FixtureLoader.string("rewrite-forget.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        env.fake.script = Self.resticCall(
            Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes),
            dest: Self.primaryId,
            stdoutLines: Self.backupStream()
        ) + Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"],
            dest: Self.primaryId,
            stdoutLines: [snapshotsJSON]
        ) + Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"],
            dest: Self.primaryId,
            stdoutLines: [snapshotsJSON]
        ) + Self.resticCall(
            Self.rewriteArgv(
                env.primary.repoURL,
                snapshotIDs: snapshots.map(\.id),
                patterns: env.set.purgeExcludes
            ),
            dest: Self.primaryId,
            stdoutLines: rewrite.split(separator: "\n").map(String.init)
        )

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .infrastructureFailure(let reason) = outcome else {
            Issue.record("a lost purge watermark must fail the scheduled tick: \(outcome)")
            return
        }
        #expect(reason.contains("purge watermark"))
        #expect(env.entries(kind: .purge).first?.status == .success)
    }

    @Test("row purge 2: a stale secondary whose purge fails is never copied or marked applied")
    func failedSecondaryPurgeSkipsCopy() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [], retention: nil, purgeExcludes: ["build/**"], reachableSecondaries: [true],
            purgeSourcePaths: sourcePaths, purgeHostnames: hostnames
        )
        defer { env.cleanUp() }
        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let rewrite = try FixtureLoader.string("rewrite-forget.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        let secondary = env.secondaries[0]
        env.fake.script = Self.resticCall(Self.backupArgv(env.primary.repoURL, excludes: env.set.purgeExcludes), dest: Self.primaryId, stdoutLines: Self.backupStream())
            + Self.resticCall(["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [snapshotsJSON])
            + Self.resticCall(["-r", env.primary.repoURL, "snapshots", "--json"], dest: Self.primaryId, stdoutLines: [snapshotsJSON])
            + Self.resticCall(Self.rewriteArgv(env.primary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes), dest: Self.primaryId, stdoutLines: rewrite.split(separator: "\n").map(String.init))
            + Self.resticCall(["-r", secondary.repoURL, "snapshots", "--json"], dest: secondary.id, stdoutLines: [snapshotsJSON])
            + Self.resticCall(["-r", secondary.repoURL, "snapshots", "--json"], dest: secondary.id, stdoutLines: [snapshotsJSON])
            + Self.resticCall(Self.rewriteArgv(secondary.repoURL, snapshotIDs: snapshots.map(\.id), patterns: env.set.purgeExcludes), dest: secondary.id, stderr: "rewrite failed", exitCode: 1)

        let outcome = await env.engine.runSet(env.set, trigger: .scheduled)

        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == .failed)
        #expect(env.resticArgvs.allSatisfy { !$0.contains("copy") })
        let applied = env.stateStore.readScheduleState()?.sets[Self.setId]?.appliedPurgeExcludes
        #expect(applied?[env.primary.id] == env.set.purgeExcludes)
        #expect(applied?[secondary.id] == nil)
    }

    @Test("previewPurge: snapshots then rewrite dry-run only, with explicit attributed ids")
    func purgePreviewIsReadOnly() async throws {
        let sourcePaths = [Self.setId: Set(["/Users/user/example/src"])]
        let hostnames = [Self.setId: Set(["example-mac.local"])]
        let env = Self.makeEnv(
            script: [],
            retention: nil,
            purgeExcludes: ["build/**"],
            reachableSecondaries: [],
            purgeSourcePaths: sourcePaths,
            purgeHostnames: hostnames
        )
        defer { env.cleanUp() }

        let snapshotsJSON = try FixtureLoader.string("snapshots.json")
        let snapshots = try parseSnapshots(Data(snapshotsJSON.utf8))
        let snapshotIDs = snapshots.map(\.id)
        let dryRunText = try FixtureLoader.string("rewrite-dry-run.txt")
            .replacingOccurrences(of: "09b3295c", with: snapshots[0].shortId)
            .replacingOccurrences(of: "b2435423", with: snapshots[1].shortId)
        let dryRun = dryRunText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        env.fake.script = Self.resticCall(
            ["-r", env.primary.repoURL, "snapshots", "--json"],
            dest: Self.primaryId,
            stdoutLines: [snapshotsJSON]
        ) + Self.resticCall(
            ["-r", env.primary.repoURL, "rewrite", "--dry-run", "--exclude", "build/**"] + snapshotIDs,
            dest: Self.primaryId,
            stdoutLines: dryRun
        )

        let result = await env.engine.previewPurge(set: env.set, destination: env.primary)

        #expect(result.status == .ready)
        #expect(result.plan.matched.map(\.id) == snapshotIDs)
        #expect(result.changed.map(\.id) == snapshotIDs)
        #expect(env.resticArgvs == [
            [Self.resticPath, "-r", env.primary.repoURL, "snapshots", "--json"],
            [Self.resticPath, "-r", env.primary.repoURL, "rewrite", "--dry-run", "--exclude", "build/**"] + snapshotIDs,
        ])
        #expect(env.fake.invocations.allSatisfy { !$0.argv.contains("--forget") })
        #expect(env.indexEntries.isEmpty, "a read-only preview creates no run record")
    }

    @Test("previewPurge with no patterns is empty and spawns nothing")
    func purgePreviewEmpty() async throws {
        let env = Self.makeEnv(script: [], retention: nil, purgeExcludes: [], reachableSecondaries: [])
        defer { env.cleanUp() }

        let result = await env.engine.previewPurge(set: env.set, destination: env.primary)

        #expect(result.status == .empty)
        #expect(result.plan.matched.isEmpty)
        #expect(env.fake.invocations.isEmpty)
    }

    // MARK: - runRestore

    @Test("runRestore: exact argv, .restore record, set lock taken")
    func restoreHappyPath() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [true])
        defer { env.cleanUp() }
        let target = env.root.appendingPathComponent("restore-target", isDirectory: true).path

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            [
                "-r", env.primary.repoURL, "restore", "--json", "abc123:/proj/src",
                "--target", target, "--include", "*.txt", "--overwrite", "if-newer",
            ],
            dest: Self.primaryId,
            stdoutLines: (try? FixtureLoader.lines("restore.ndjson")) ?? []
        )
        env.fake.script = script

        let status = await env.engine.runRestore(request: RestoreRequest(
            destId: Self.primaryId,
            snapshotID: "abc123",
            subpath: "/proj/src",
            targetPath: target,
            includes: ["*.txt"],
            overwriteMode: .ifNewer
        ))

        #expect(status == .success)
        #expect(env.resticArgvs == [[
            Self.resticPath, "-r", env.primary.repoURL, "restore", "--json", "abc123:/proj/src",
            "--target", target, "--include", "*.txt", "--overwrite", "if-newer",
        ]])
        let entry = try #require(env.entries(kind: .restore).first)
        #expect(entry.status == .success)
        #expect(entry.trigger == .manual)
        #expect(entry.destId == Self.primaryId)
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil, "live progress is cleared afterwards")
    }

    @Test("safety: a restore cannot start while the set lock is held by a backup")
    func restoreRespectsSetLock() async throws {
        let env = Self.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let holder = FileLock(path: env.paths.setLockFile(setId: Self.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        let status = await env.engine.runRestore(request: RestoreRequest(
            destId: Self.primaryId,
            snapshotID: "abc123",
            targetPath: "/tmp/target"
        ))

        #expect(status == .skipped)
        #expect(env.resticArgvs.isEmpty)
        #expect(env.entries(kind: .restore).first?.status == .skipped)
    }

    @Test("runRestore: per-item error messages downgrade an exit-0 restore to .warning")
    func restoreWithItemErrorsIsWarning() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [])
        defer { env.cleanUp() }

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            ["-r", env.primary.repoURL, "restore", "--json", "abc123", "--target", "/tmp/target"],
            dest: Self.primaryId,
            stdoutLines: [
                "{\"message_type\":\"error\",\"error\":{\"message\":\"permission denied\"},\"item\":\"/x\"}",
                "{\"message_type\":\"summary\",\"total_files\":4,\"files_restored\":3,"
                    + "\"total_bytes\":10,\"bytes_restored\":8}",
            ]
        )
        env.fake.script = script

        let status = await env.engine.runRestore(request: RestoreRequest(
            destId: Self.primaryId,
            snapshotID: "abc123",
            targetPath: "/tmp/target"
        ))

        #expect(status == .warning)
        #expect(env.entries(kind: .restore).first?.status == .warning)
    }

    // MARK: - initSecondary

    @Test("initSecondary: --from-repo + --copy-chunker-params, run record kind .init")
    func initSecondaryUsesChunkerParams() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [true])
        defer { env.cleanUp() }
        let secondary = env.secondaries[0]

        var script: [FakeProcessRunner.Expectation] = []
        script += Self.resticCall(
            [
                "-r", secondary.repoURL, "init", "--json",
                "--from-repo", env.primary.repoURL, "--copy-chunker-params",
            ],
            dest: Self.secondaryAId,
            from: Self.primaryId,
            stdoutLines: [(try? FixtureLoader.string("init-secondary.json").trimmingCharacters(in: .newlines)) ?? ""]
        )
        env.fake.script = script

        let status = await env.engine.initSecondary(env.set, dest: secondary)

        #expect(status == .success)
        #expect(env.resticArgvs == [[
            Self.resticPath, "-r", secondary.repoURL, "init", "--json",
            "--from-repo", env.primary.repoURL, "--copy-chunker-params",
        ]])
        let entry = try #require(env.entries(kind: .`init`).first)
        #expect(entry.status == .success)
        #expect(entry.destId == secondary.id)
        #expect(entry.trigger == .manual)
        #expect(env.repoStatus(secondary)?.reachable == true)
        #expect(env.repoStatus(secondary)?.lastSyncedAt == nil, "an init is not a sync")
        #expect(env.stateStore.readCurrentRun(setId: Self.setId) == nil, "live progress is cleared afterwards")
    }

    @Test("initSecondary refuses to target the primary")
    func initSecondaryRefusesPrimary() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [])
        defer { env.cleanUp() }

        let status = await env.engine.initSecondary(env.set, dest: env.primary)

        #expect(status == .failed)
        #expect(env.fake.invocations.isEmpty)
    }

    // MARK: - Misconfiguration

    @Test("a set without a primary destination is refused before anything is spawned or written")
    func setWithoutPrimaryIsRefused() async throws {
        let env = Self.makeEnv(script: [], reachableSecondaries: [true])
        defer { env.cleanUp() }
        var broken = env.set
        broken.destinations = broken.destinations.filter { !$0.isPrimary }

        let outcome = await env.engine.runSet(broken, trigger: .scheduled)

        guard case .misconfigured = outcome else {
            Issue.record("expected .misconfigured, got \(outcome)")
            return
        }
        #expect(env.fake.invocations.isEmpty)
        #expect(env.indexEntries.isEmpty)
    }
}

// MARK: - Box

/// Minimal mutable holder used to hand the freshly built `AppPaths` to a
/// spawn observer that must be constructed before the environment exists.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        self.storage = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
