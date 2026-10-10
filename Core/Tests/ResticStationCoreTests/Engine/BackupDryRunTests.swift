import Foundation
import Testing
@testable import ResticStationCore

/// #78: `backup dry-run`. Most of these are about what it must *not* do —
/// spawn anything but the one `backup --dry-run`, or write any run record or
/// state — so most assertions are negative, over everything rather than one
/// filtered kind.
@Suite struct BackupDryRunTests {
    typealias T = BackupEngineTests

    /// restic 0.18+'s `summary` line for `backup --dry-run`: it carries a
    /// `snapshot_id` for a snapshot that was never saved, and `dry_run`.
    static func dryRunSummary(dryRun: Bool? = true, filesNew: Int = 3) -> String {
        let marker = dryRun.map { ",\"dry_run\":\($0)" } ?? ""
        return "{\"message_type\":\"summary\",\"files_new\":\(filesNew),\"files_changed\":1,"
            + "\"files_unmodified\":7,\"dirs_new\":2,\"dirs_changed\":0,\"dirs_unmodified\":4,"
            + "\"data_blobs\":3,\"tree_blobs\":3,\"data_added\":67860,\"data_added_packed\":67085,"
            + "\"total_files_processed\":11,\"total_bytes_processed\":65571,\"total_duration\":0.75,"
            + "\"backup_start\":\"2026-07-26T16:57:04.634751-04:00\","
            + "\"backup_end\":\"2026-07-26T16:57:05.386964-04:00\","
            + "\"snapshot_id\":\"e9ffc5cb64395ad443fd14f432751a9823181224978d6b25bf2af1a99ad367fd\"\(marker)}"
    }

    static func dryRunArgv(_ repo: String, source: String = T.source) -> [String] {
        ["-r", repo, "backup", "--json", "--dry-run", source]
    }

    /// Every file under the data directory, so "nothing was written" is
    /// checked over the whole tree rather than over the files a test thought
    /// to name. Lock files are the one expected entry: taking the set lock
    /// creates its file.
    static func writtenFiles(_ env: T.Env) -> [String] {
        let root = env.paths.root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        return walker.compactMap { $0 as? String }
            .filter { path in
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isDirectory)
                return !isDirectory.boolValue && !path.hasPrefix("locks/")
            }
            .sorted()
    }

    func expectNothingRecorded(_ env: T.Env) {
        #expect(Self.writtenFiles(env) == [])
        #expect(env.indexEntries.isEmpty)
        #expect(env.stateStore.readScheduleState() == nil)
        #expect(env.repoStatus(env.primary) == nil)
        #expect(env.stateStore.readCurrentRun(setId: T.setId) == nil)
    }

    // MARK: - The one command

    @Test("a dry run spawns exactly one restic: backup --json --dry-run, and records nothing")
    func spawnsOnlyTheDryRun() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(
            Self.dryRunArgv(env.primary.repoURL), dest: T.primaryId, stdoutLines: [Self.dryRunSummary()]
        )

        let report = try await env.engine.backupDryRun(env.set)

        // The set has two mirrors and a retention policy: none of them is
        // touched, and no unlock, check or init either.
        #expect(env.resticArgvs == [[env.resticPath] + Self.dryRunArgv(env.primary.repoURL)])
        #expect(report.outcome == .success)
        #expect(report.summary.filesNew == 3)
        #expect(report.summary.dataAdded == 67860)
        #expect(report.resticExitCode == 0)
        #expect(report.primary.id == T.primaryId)
        #expect(report.warnings.isEmpty)
        expectNothingRecorded(env)
    }

    /// The acceptance criterion "dry run and real backup share construction",
    /// tested as the observable fact rather than as the refactor: two engines
    /// over the same set, every kind of exclusion, and the dry run's argv is
    /// the real one with `--dry-run` and nothing else changed.
    ///
    /// Run twice: once plain, and once with a `CACHEDIR.TAG` above the
    /// source, where both must hold `--exclude-caches` back. Without the
    /// second case a dry run that skipped the tag check passed (review
    /// finding on #185).
    @Test(
        "the dry run's argv is the real backup's argv plus --dry-run, for every exclusion source",
        arguments: [false, true]
    )
    func sharesTheRealBackupsConstruction(taggedAboveSource: Bool) async throws {
        let plan = GlobalExcludePlan(
            patterns: ["node_modules", "Library/Caches"],
            excludeCaches: true,
            excludeLargerThan: "10G"
        )
        let tree = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-dry-run-cachedir-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: tree) }
        let source: String
        if taggedAboveSource {
            let project = tree.appendingPathComponent("cache/project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8)
                .write(to: tree.appendingPathComponent("cache/CACHEDIR.TAG"))
            source = project.path
        } else {
            source = T.source
        }
        func env() -> T.Env {
            T.makeEnv(
                script: [],
                sources: [source],
                retention: nil,
                excludes: ["*.log"],
                purgeExcludes: ["secrets/"],
                globalExcludes: .success(plan),
                reachableSecondaries: []
            )
        }
        let real = env()
        defer { real.cleanUp() }
        real.fake.script = SecretPreflightAttentionTests.anything
        _ = await real.engine.runSet(real.set, trigger: .manual)
        let realBackup = try #require(real.resticArgvs.first { $0.contains("backup") })

        let dry = env()
        defer { dry.cleanUp() }
        var expected = realBackup
        let json = try #require(expected.firstIndex(of: "--json"))
        expected.insert("--dry-run", at: json + 1)
        // Same fixture path on both, so the repository differs only by temp dir.
        expected = expected.map { $0 == real.primary.repoURL ? dry.primary.repoURL : $0 }
        dry.fake.script = [.init(argvPrefix: expected, stdoutLines: [Self.dryRunSummary()])]

        let report = try await dry.engine.backupDryRun(dry.set)

        #expect(dry.resticArgvs == [expected])
        #expect(realBackup.contains("--iexclude") && realBackup.contains("secrets/"), "fixture exercises every list")
        #expect(realBackup.contains("--exclude-caches") == !taggedAboveSource)
        #expect(report.excludeCaches == !taggedAboveSource)
        #expect(report.excludePatternCount == 4)
    }

    // MARK: - Evidence that it was a dry run

    @Test("a summary without dry_run: true is not reported as a projection")
    func refusesAnUnconfirmedSummary() async throws {
        for marker in [nil, false] as [Bool?] {
            let env = T.makeEnv(script: [])
            defer { env.cleanUp() }
            env.fake.script = T.resticCall(
                Self.dryRunArgv(env.primary.repoURL),
                dest: T.primaryId,
                stdoutLines: [Self.dryRunSummary(dryRun: marker)]
            )

            await #expect(throws: BackupDryRunError.unconfirmed(
                destinationId: T.primaryId,
                reason: "restic's summary does not say this was a dry run"
            )) {
                try await env.engine.backupDryRun(env.set)
            }
            expectNothingRecorded(env)
        }
    }

    @Test("no summary at all is not reported as a projection")
    func refusesAMissingSummary() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(Self.dryRunArgv(env.primary.repoURL), dest: T.primaryId)

        await #expect(throws: BackupDryRunError.unconfirmed(
            destinationId: T.primaryId, reason: "restic reported no summary"
        )) {
            try await env.engine.backupDryRun(env.set)
        }
    }

    @Test("isDryRunBackup finds the flag where the builder puts it, never as an exclude pattern")
    func dryRunFlagDetection() {
        let repo = "/repo"
        #expect(BackupEngine.isDryRunBackup(.backup(repo: repo, sources: ["/a"], dryRun: true)))
        #expect(BackupEngine.isDryRunBackup(.backup(
            repo: repo, sources: ["/a"], excludes: ["x"], excludeCloudFiles: true, excludeCaches: true, dryRun: true
        )))
        #expect(!BackupEngine.isDryRunBackup(.backup(repo: repo, sources: ["/a"])))
        #expect(!BackupEngine.isDryRunBackup(.backup(repo: repo, sources: ["/a"], excludes: ["--dry-run"])))
        #expect(!BackupEngine.isDryRunBackup(.backup(repo: repo, sources: ["/a"], globalExcludes: ["--dry-run"])))
        #expect(!BackupEngine.isDryRunBackup(.snapshots(repo: repo)))
    }

    @Test("summaryConfirmsDryRun reads the last summary line and nothing else")
    func dryRunMarkerParsing() {
        let status = "{\"message_type\":\"status\",\"percent_done\":0.5,\"dry_run\":true}"
        #expect(BackupEngine.summaryConfirmsDryRun(Self.dryRunSummary() + "\n"))
        #expect(BackupEngine.summaryConfirmsDryRun(status + "\n" + Self.dryRunSummary()))
        #expect(!BackupEngine.summaryConfirmsDryRun(status))
        #expect(!BackupEngine.summaryConfirmsDryRun(Self.dryRunSummary(dryRun: nil)))
        #expect(!BackupEngine.summaryConfirmsDryRun(Self.dryRunSummary(dryRun: false)))
        #expect(!BackupEngine.summaryConfirmsDryRun(""))
    }

    // MARK: - restic outcomes

    @Test("exit 3 is a warning with figures, not a failure")
    func incompleteReadIsAWarning() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(
            Self.dryRunArgv(env.primary.repoURL),
            dest: T.primaryId,
            stdoutLines: [Self.dryRunSummary()],
            exitCode: 3
        )

        let report = try await env.engine.backupDryRun(env.set)

        #expect(report.outcome == .warning)
        #expect(report.resticExitCode == 3)
        #expect(report.warnings == ["some source files could not be read; the figures leave them out"])
        expectNothingRecorded(env)
    }

    @Test("a locked repository is reported, never unlocked and retried")
    func lockedRepositoryIsNotUnlocked() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(Self.dryRunArgv(env.primary.repoURL), dest: T.primaryId, exitCode: 11)

        await #expect(throws: BackupDryRunError.resticFailed(destinationId: T.primaryId, .repoLocked)) {
            try await env.engine.backupDryRun(env.set)
        }
        #expect(env.resticArgvs.count == 1, "no `unlock`, no second attempt: \(env.resticArgvs)")
        expectNothingRecorded(env)
    }

    @Test("a fatal restic exit is a failure, with no copy or retention after it")
    func fatalExitFails() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(Self.dryRunArgv(env.primary.repoURL), dest: T.primaryId, exitCode: 1)

        do {
            _ = try await env.engine.backupDryRun(env.set)
            Issue.record("expected a failure")
        } catch BackupDryRunError.resticFailed(let destinationId, .fatal) {
            #expect(destinationId == T.primaryId)
        }
        #expect(env.resticArgvs.count == 1)
        expectNothingRecorded(env)
    }

    // MARK: - Refusals before restic

    @Test("a busy set lock refuses without spawning restic or writing a skipped record")
    func busyLock() async throws {
        let env = T.makeEnv(script: [])
        defer { env.cleanUp() }
        try env.paths.ensureDirectories()
        let holder = FileLock(path: env.paths.setLockFile(setId: T.setId))
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        await #expect(throws: BackupDryRunError.busy) {
            try await env.engine.backupDryRun(env.set)
        }
        #expect(env.fake.invocations.isEmpty)
        expectNothingRecorded(env)
    }

    @Test("an offline primary refuses without spawning restic and without a repo-status write")
    func offlinePrimary() async throws {
        let env = T.makeEnv(script: [], primaryReachable: false)
        defer { env.cleanUp() }

        await #expect(throws: BackupDryRunError.offline(
            destinationId: T.primaryId, reason: "repository path does not exist"
        )) {
            try await env.engine.backupDryRun(env.set)
        }
        #expect(env.fake.invocations.isEmpty)
        expectNothingRecorded(env)
    }

    @Test("secrets: a missing password needs attention, a locked store is retryable; restic never runs")
    func secretRefusals() async throws {
        let missing = T.makeEnv(secretsUnavailableFor: [T.primaryId], secretFailure: .itemNotFound, script: [])
        defer { missing.cleanUp() }
        do {
            _ = try await missing.engine.backupDryRun(missing.set)
            Issue.record("expected a refusal")
        } catch BackupDryRunError.attention(let attention, let destinationId, _) {
            #expect(attention == .secretNotConfigured)
            #expect(destinationId == T.primaryId)
        }
        #expect(missing.fake.invocations.isEmpty)

        let locked = T.makeEnv(secretsUnavailableFor: [T.primaryId], script: [])
        defer { locked.cleanUp() }
        do {
            _ = try await locked.engine.backupDryRun(locked.set)
            Issue.record("expected a refusal")
        } catch BackupDryRunError.secretUnavailable(let destinationId, _) {
            #expect(destinationId == T.primaryId)
        }
        #expect(locked.fake.invocations.isEmpty)
        expectNothingRecorded(locked)
    }

    @Test("an unusable global exclusion list refuses, as a real backup does")
    func unusableGlobalExcludes() async throws {
        struct Unreadable: Error, CustomStringConvertible { var description: String { "bad json" } }
        let env = T.makeEnv(script: [], globalExcludes: .failure(Unreadable()))
        defer { env.cleanUp() }

        await #expect(throws: BackupDryRunError.globalExcludesUnusable(
            "this machine's global exclusion list is unusable — bad json"
        )) {
            try await env.engine.backupDryRun(env.set)
        }
        #expect(env.fake.invocations.isEmpty)
        expectNothingRecorded(env)
    }

    @Test("a primary in the cloud with online-only files refuses before restic")
    func notHydratedPrimary() async throws {
        let env = T.makeEnv(script: [], probeDatalessEntry: { _ in "data/00/pack" })
        defer { env.cleanUp() }

        do {
            _ = try await env.engine.backupDryRun(env.set)
            Issue.record("expected a refusal")
        } catch BackupDryRunError.attention(let attention, let destinationId, _) {
            #expect(attention == .cloudRepositoryNotHydrated)
            #expect(destinationId == T.primaryId)
        }
        #expect(env.resticArgvs.isEmpty)
    }

    // MARK: - Online-only files

    #if os(macOS)
    /// A set whose policy downloads online-only files still does not for a
    /// dry run: a preview that pulled them out of iCloud would not be side-
    /// effect free. The real backup of the same set does download.
    @Test("a dry run never downloads online-only files, even for a set that does")
    func neverDownloads() async throws {
        let env = T.makeEnv(script: [], sources: [T.cloudSource], onlineOnlyFiles: .download)
        defer { env.cleanUp() }
        env.fake.script = T.resticCall(
            Self.dryRunArgv(env.primary.repoURL, source: T.cloudSource),
            dest: T.primaryId,
            stdoutLines: [Self.dryRunSummary()]
        )

        let report = try await env.engine.backupDryRun(env.set)

        let policies = env.fake.datalessPolicies.filter { $0.argv.first == env.resticPath }
        #expect(policies.map(\.policy) == [.refuse])
        #expect(report.warnings.contains {
            $0.hasPrefix("online-only files were not downloaded for the dry run")
        })
        // The real backup's "are downloaded (set policy)" note would
        // contradict what this run did.
        #expect(!report.logNotes.contains { $0.contains("downloaded (set policy)") })
        #expect(!report.cloudFilesExcluded)
    }
    #endif

    /// A download set whose primary is itself in cloud storage does not
    /// download in its real backup either, so the dry run must not claim
    /// the real one would add more. Review finding on #185.
    @Test("a download set into a cloud-stored primary gets no 'a real backup downloads them' warning")
    func downloadSetIntoCloudPrimary() {
        let home = "/Users/example"
        let cloudSource = home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes"
        func notes(primaryRepo: String) -> (warning: String?, note: String?) {
            let primary = Destination(id: T.primaryId, label: "Primary", repoURL: primaryRepo, isPrimary: true)
            let set = BackupSet(
                id: T.setId, name: "Notes", sources: [cloudSource], onlineOnlyFiles: .download,
                schedule: .daily(hour: 2, minute: 30), destinations: [primary]
            )
            return BackupEngine.dryRunOnlineOnlyNotes(
                set: set, primary: primary, hasCloudSource: true, excludeCloudFiles: false,
                cloudSourceNote: "the real backup's note", homeDirectory: home
            )
        }

        let cloudPrimary = notes(primaryRepo: home + "/Library/Mobile Documents/com~apple~CloudDocs/repo")
        #expect(cloudPrimary.warning == nil)
        #expect(cloudPrimary.note == "the real backup's note")

        let localPrimary = notes(primaryRepo: "/Volumes/Backup/repo")
        #expect(localPrimary.warning?.contains("a real backup downloads them") == true)
        #expect(localPrimary.note == nil)
    }

    #if os(macOS)
    @Test("a cloud-backed source on restic 0.19 gets --exclude-cloud-files in the dry run too")
    func cloudSourceSkipsOnlineOnlyFiles() async throws {
        let env = T.makeEnv(script: [], sources: [T.cloudSource], reachableSecondaries: [])
        defer { env.cleanUp() }
        let argv = ["-r", env.primary.repoURL, "backup", "--json", "--dry-run", "--exclude-cloud-files", T.cloudSource]
        env.fake.script = T.versionCall("0.19.0")
            + T.resticCall(argv, dest: T.primaryId, stdoutLines: [Self.dryRunSummary()])

        let report = try await env.engine.backupDryRun(env.set)

        #expect(env.resticArgvs == [[env.resticPath, "version", "--json"], [env.resticPath] + argv])
        #expect(report.cloudFilesExcluded)
        #expect(report.warnings.isEmpty)
    }
    #endif

    // MARK: - CLI mapping

    /// A dry run writes no run log, so no refusal may send the caller to
    /// one. Codex on #185.
    @Test("restic failures keep restic's text and never point at a run log")
    func failureMessagesNameNoRunLog() {
        let cases: [ResticExitClass] = [.fatal(stderrSummary: "Fatal: unable to open config file"), .other(42)]
        for exitClass in cases {
            for error in [
                BackupDryRunError.resticFailed(destinationId: T.primaryId, exitClass),
                .probeFailed(destinationId: T.primaryId, exitClass),
            ] {
                let failure = CLIFailure.classifyBackupDryRun(error, setId: T.setId)
                #expect(!failure.message.contains("run log for"), "\(error): \(failure.message)")
                #expect(failure.message.contains("keeps no run log"), "\(error)")
                #expect(failure.code == .resticFailed)
                #expect(failure.details.resticExitCode != nil)
            }
        }
        let fatal = CLIFailure.classifyBackupDryRun(
            BackupDryRunError.resticFailed(destinationId: T.primaryId, .fatal(stderrSummary: "Fatal: unable to open config file")),
            setId: T.setId
        )
        #expect(fatal.message.hasPrefix("Fatal: unable to open config file"))
    }

    @Test("each refusal maps to its documented code and exit")
    func cliMapping() {
        let setId = T.setId
        let dest = T.primaryId
        let cases: [(BackupDryRunError, CLIErrorCode, HelperExitCode)] = [
            (.busy, .setBusy, .busy),
            (.offline(destinationId: dest, reason: "gone"), .repositoryOffline, .offline),
            (.resticFailed(destinationId: dest, .repoLocked), .repositoryLocked, .error),
            (.resticFailed(destinationId: dest, .wrongPassword), .secretRejected, .error),
            (.resticFailed(destinationId: dest, .fatal(stderrSummary: "boom")), .resticFailed, .error),
            (.attention(.secretNotConfigured, destinationId: dest, message: "m"), .secretNotConfigured, .error),
            (.attention(.cloudRepositoryNotHydrated, destinationId: dest, message: "m"),
             .cloudRepositoryNotHydrated, .error),
            (.secretUnavailable(destinationId: dest, message: "m"), .secretUnavailable, .error),
            (.globalExcludesUnusable("r"), .configInvalid, .error),
            (.lockUnusable("d"), .internalError, .error),
            (.unconfirmed(destinationId: dest, reason: "r"), .internalError, .error),
            (.notADryRun, .internalError, .error),
            (.resticDidNotRun(destinationId: dest, .timedOut), .operationTimedOut, .error),
        ]
        for (error, code, exit) in cases {
            let failure = CLIFailure.classifyBackupDryRun(error, setId: setId)
            #expect(failure.code == code, "\(error)")
            #expect(failure.exitCode == exit, "\(error)")
            #expect(failure.details.setId == setId, "\(error)")
        }
    }
}
