import ArgumentParser
import Foundation
import ResticStationCore

#if canImport(Darwin)
import Darwin
#endif

/// `status [--json]` — the headless equivalent of the menu bar
/// (`docs/tasks/T27`). Reads only existing state (`state/schedule-state.json`,
/// `state/current-run-*.json`, `state/repo-status-*.json`, `runs/index.jsonl`)
/// — no restic invocation, no network access, safe to run as often as a
/// monitoring check likes.
///
/// **Reuses `HealthDerivation`, never re-derives health** — the same rule
/// `HelperContext`'s doc comment states for resolution: if the CLI computed
/// "needs attention" itself, it and the app's menu bar could quietly drift
/// apart on what counts as a warning.
struct Status: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "The headless menu bar: per set, last run outcome+age, next due time, any "
            + "in-flight run's live progress, per-destination reachability+staleness, and last "
            + "check/prune. It also reports whether launchd (macOS) or the systemd --user "
            + "timer (Linux) will actually fire. Reads state and the host scheduler — no restic invocation. --json for "
            + "scripting (e.g. a Nagios/Icinga check). Exit 0 healthy (including a run in "
            + "flight), 1 if any set needs attention or the scheduler is broken."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let paths = AppPaths.default()
        let configStore = ConfigStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        let runStore = RunStore(paths: paths)

        let config: AppConfig
        do {
            config = try configStore.load()
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
        let machineId: String
        do {
            machineId = try MachineStore(paths: paths).load().machineId
        } catch {
            throw CLIFailure.machineIdentityUnreadable(path: paths.machineFile.path, underlying: error)
        }

        // `.scheduling`: this is exactly the view `HealthDerivation` is
        // documented to run on — what this machine backs up, staleness
        // included (docs/data-model.md §Per-machine scoping).
        let scheduled = config.resolved(for: machineId)

        let now = Date()
        let calendar = Calendar.current
        let configurationVisibleSince = paths.configurationVisibleSince()
        // The full index, not a capped window. `HealthDerivation.setHealths`
        // derives each set's `needsAttention` from that set's own most
        // recent run — but a shared, global cap applied *before* the
        // per-set filter can hide a quiet set's latest (possibly failed)
        // run behind busier sets' newer ones, silently reporting the quiet
        // set healthy and flipping this command's own exit code back to 0.
        // `--json`'s exit code is documented as a Nagios/Icinga check
        // (docs/data-model.md), so that is the worst failure mode available
        // here — worse than printing nothing at all. `RunStore.recentRuns`
        // already decodes the entire `runs/index.jsonl` before any `limit`
        // is applied (there is no way to stop early on a `.jsonl` tail
        // without a separate index), so `.max` costs nothing extra over the
        // previous cap on the read/decode side; it only keeps entries this
        // command would otherwise have discarded right after decoding them.
        //
        // Thrown, not swallowed. `recentRuns` already tolerates everything
        // that is *survivable* — a missing index reads as no runs, a corrupt
        // or truncated line is skipped with a warning — so anything left to
        // throw here is the file being unreadable outright (wrong owner,
        // wrong mode, I/O error). `(try? …) ?? []` turned that into "no runs
        // recorded", which derives to idle, which exits 0: this command
        // reporting healthy precisely because it could not read the evidence.
        let recentRuns: [RunIndexEntry]
        do {
            recentRuns = try runStore.recentRuns(limit: .max)
        } catch {
            throw CLIFailure.stateUnreadable(
                "could not read the run history (\(paths.runsIndexFile.path)): \(error)"
            )
        }

        var currentRuns: [UUID: CurrentRunState] = [:]
        for setId in stateStore.currentRunSetIDs() {
            if let state = stateStore.readCurrentRun(setId: setId) {
                currentRuns[setId] = state
            }
        }

        // One point-in-time answer per run, captured before the scheduler
        // probe below can spend time in subprocesses. A run may finish while
        // that probe is in flight, so this snapshot can intentionally be
        // stale by the time the report prints. Reusing it is what guarantees
        // the JSON body, human rendering, health and exit code all describe
        // the same instant instead of contradicting one another.
        let runLiveness = Self.runLivenessPredicate(
            currentRuns: currentRuns,
            liveness: runStore.liveness(ofCurrentRun:)
        )

        var repoStatuses: [UUID: RepoStatus] = [:]
        for (_, destination) in scheduled.destinations {
            if let status = stateStore.readRepoStatus(destId: destination.id) {
                repoStatuses[destination.id] = status
            }
        }
        let scheduleState = stateStore.readScheduleState()

        let setHealths = HealthDerivation.setHealths(
            config: scheduled.config,
            recentRuns: recentRuns,
            currentRuns: currentRuns,
            repoStatuses: repoStatuses,
            scheduleState: scheduleState,
            now: now,
            calendar: calendar,
            visibleSince: configurationVisibleSince,
            runLiveness: runLiveness
        )

        let fdaCheck = stateStore.readFdaCheck()
        let fdaDenied = HealthDerivation.fullDiskAccessDenied(from: fdaCheck)
        // `backgroundAgentEnabled` asks "is the scheduler actually going to
        // fire?" On Linux we inspect systemd; on macOS we ask launchd whether
        // the SMAppService agent is loaded. It used to pass `true`
        // unconditionally, which reads as "the scheduler is fine" and hid a
        // host whose timer or LaunchAgent had stopped firing.
        let scheduler = await Self.scheduler(paths: paths)
        // Live, not recorded. A host whose `locks/` cannot be created or
        // whose lock files are not ours has stopped backing up, and is also
        // unable to write the run record or health state that would say so —
        // so the only reliable place to notice is here, at read time (#110).
        let lockingFailure = LockingHealth.probe(
            paths: paths,
            configuredSetIds: Set(scheduled.config.sets.map(\.id))
        )
        let health = HealthDerivation.appHealth(
            setHealths: setHealths,
            // Every current-run file, including one for a set no longer in
            // the resolved config — `currentRunSetIDs()`'s documented
            // contract, which is what `appHealth`'s `runsInFlight` expects.
            runsInFlight: Array(currentRuns.values),
            fullDiskAccessDenied: fdaDenied,
            backgroundAgentEnabled: scheduler.flatMap(\.healthy),
            lockingBroken: lockingFailure != nil,
            runLiveness: runLiveness
        )

        let sets: [StatusReport.SetStatus] = setHealths.map { setHealth in
            let set = scheduled.set(id: setHealth.setId)
            let destinations = (set?.destinations ?? []).map { destination -> StatusReport.DestinationStatus in
                let status = repoStatuses[destination.id]
                return StatusReport.DestinationStatus(
                    id: destination.id,
                    label: destination.label,
                    isPrimary: destination.isPrimary,
                    reachable: status?.reachable,
                    stale: setHealth.staleDestinationIds.contains(destination.id),
                    lastSyncedAt: status?.lastSyncedAt,
                    lastError: status?.lastError
                )
            }
            return StatusReport.SetStatus(
                id: setHealth.setId,
                name: setHealth.name,
                needsAttention: setHealth.needsAttention,
                isRunning: setHealth.isRunning,
                firstBackupOverdue: setHealth.firstBackupOverdue,
                abandonedRun: StatusReport.CurrentRunSummary(setHealth.abandonedRun),
                abandonedRunFile: setHealth.hasAbandonedRun
                    ? paths.currentRunFile(setId: setHealth.setId).path
                    : nil,
                stalledRun: StatusReport.CurrentRunSummary(setHealth.stalledRun),
                stalledRunLog: setHealth.stalledRun.map { paths.runLogFile(runId: $0.runId).path },
                lastBackup: StatusReport.RunSummary(setHealth.lastBackup, now: now),
                lastCheck: StatusReport.RunSummary(try? runStore.lastRun(setId: setHealth.setId, kind: .check), now: now),
                lastPrune: StatusReport.RunSummary(try? runStore.lastRun(setId: setHealth.setId, kind: .prune), now: now),
                currentRun: StatusReport.CurrentRunSummary(setHealth.currentRun),
                nextDue: setHealth.nextDue,
                destinations: destinations
            )
        }

        // A current-run file can outlive the set it belonged to. It still
        // contributes to app health and the exit code, so omitting it from
        // the report would make those verdicts impossible to explain.
        // Reuse the point-in-time liveness snapshot above: this must not
        // re-probe a process after the scheduler subprocesses have run.
        let configuredSetIds = Set(scheduled.config.sets.map(\.id))
        let unattributedRuns: [StatusReport.UnattributedRun] = currentRuns
            .filter { !configuredSetIds.contains($0.key) }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { setId, run in
                StatusReport.UnattributedRun(
                    setId: setId,
                    liveness: {
                        switch runLiveness(run) {
                        case .live: return .live
                        case .stalled: return .stalled
                        case .abandoned: return .abandoned
                        }
                    }(),
                    currentRun: StatusReport.CurrentRunSummary(run),
                    currentRunFile: paths.currentRunFile(setId: setId).path
                )
            }

        let excludedHere: [StatusReport.Exclusion] = scheduled.omissions.map { omission in
            StatusReport.Exclusion(omission: omission)
        }

        let report = StatusReport(
            machineId: machineId,
            generatedAt: now,
            health: health.rawValue,
            fullDiskAccessDenied: fdaDenied,
            locking: StatusReport.LockingStatus(paths: paths, failure: lockingFailure),
            scheduler: scheduler,
            sets: sets,
            unattributedRuns: unattributedRuns,
            excludedHere: excludedHere
        )

        if json {
            CLIJSON.print(report)
        } else {
            for line in report.humanLines() {
                print(line)
            }
        }

        // Not `health == .warning`. `.running` outranks `.warning` in
        // `appHealth` — correctly, for a menu bar glyph — so exiting on it
        // would report a host healthy for the whole duration of a backup
        // while its timer was disabled and no *next* backup would ever
        // start. `hasWarningConditions` is the same rules without that
        // precedence, which is the right question for an exit code.
        let needsAttention = HealthDerivation.hasWarningConditions(
            setHealths: setHealths,
            runsInFlight: Array(currentRuns.values),
            fullDiskAccessDenied: fdaDenied,
            backgroundAgentEnabled: scheduler.flatMap(\.healthy),
            lockingBroken: lockingFailure != nil,
            runLiveness: runLiveness
        )
        HelperExit.code(needsAttention ? 1 : 0)
    }

    /// Captures one liveness answer per run ID and returns the predicate all
    /// health derivations in one `status` invocation share. Keying by run ID
    /// also avoids repeating the process probe if malformed state contains
    /// the same run under more than one set ID.
    static func runLivenessPredicate(
        currentRuns: [UUID: CurrentRunState],
        liveness: (CurrentRunState) -> CurrentRunLiveness
    ) -> (CurrentRunState) -> CurrentRunLiveness {
        var livenessByRunId: [String: CurrentRunLiveness] = [:]
        for run in currentRuns.values where livenessByRunId[run.runId] == nil {
            livenessByRunId[run.runId] = liveness(run)
        }
        return { run in
            livenessByRunId[run.runId] ?? .abandoned
        }
    }

    /// Is anything actually going to fire the tick on this host?
    ///
    /// On macOS, `launchctl print gui/<uid>/<label>` answers whether the
    /// `SMAppService`-registered agent is actually loaded. On Linux the
    /// systemd `--user` timer is fully inspectable and the answer is the same
    /// one `timer status` exits on — deliberately the same code path.
    ///
    /// This is the one place `status` spawns subprocesses (three short
    /// `systemctl --user` queries, each bounded by
    /// `SystemdTimerManager.commandTimeout`). Worth it: a status command that
    /// cannot see the scheduler reports a machine as healthy for as long as
    /// its last recorded run stays inside the staleness window, which for a
    /// quiet set is days.
    static func scheduler(
        paths: AppPaths,
        runner: any ProcessRunning = DefaultProcessRunner(),
        uid: UInt32? = nil
    ) async -> StatusReport.SchedulerStatus? {
        #if os(Linux)
        _ = runner
        _ = uid
        // No activity lines and no activity problems: this call is only for
        // the verdict, and `run()` has already loaded the config itself (and
        // exited non-zero if it could not).
        let health = await TimerCommand.makeManager().status(
            helperPath: nil,
            dataDirectory: paths.root.path,
            activity: TimerActivity(lines: []),
            // Bounded: this discards the log entirely, so the narrative
            // `list-timers` call is pure cost, and a wedged user bus must
            // not be able to hold a monitoring check for minutes.
            verdictOnly: true,
            log: { _ in }
        )
        // "No systemd here" is where `status` and `timer status` part ways,
        // deliberately. `timer status` is asked specifically about the
        // systemd timer, so no systemd is a definite no and it exits 1.
        // `status` is asked whether *anything* schedules backups — and the
        // documented answer for a host without systemd is the cron fallback
        // (`SystemdCommand.cronFallbackLine`), which nothing here can
        // inspect. Reporting `false` would make this command permanently red
        // inside every container, which is the always-red-check failure the
        // linger `.unknown` case avoids for the same reason.
        guard !health.problems.contains(.systemdUnavailable) else {
            return StatusReport.SchedulerStatus(
                kind: "unknown",
                healthy: nil,
                problems: health.problems.map(\.rawValue),
                summaries: ["no systemd on this host — if you set up the documented cron "
                    + "fallback, nothing here can see it either way"]
            )
        }
        return StatusReport.SchedulerStatus(
            kind: "systemd-timer",
            healthy: health.isHealthy,
            problems: health.problems.map(\.rawValue),
            summaries: health.problems.map(\.summary)
        )
        #else
        _ = paths
        let resolvedUID = uid ?? getuid()
        let argv = [LaunchctlCommand.executablePath] + LaunchctlCommand.printArgv(uid: resolvedUID)
        do {
            let result = try await runner.run(
                argv,
                env: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 5
            )
            if result.exitCode == 0 {
                return StatusReport.SchedulerStatus(
                    kind: "launchd-agent",
                    healthy: true,
                    problems: [],
                    summaries: []
                )
            }
            return StatusReport.SchedulerStatus(
                kind: "launchd-agent",
                healthy: false,
                problems: ["agentNotLoaded"],
                summaries: ["launchd does not have \(LaunchctlCommand.helperLabel) loaded for user \(resolvedUID)"]
            )
        } catch {
            return StatusReport.SchedulerStatus(
                kind: "launchd-agent",
                healthy: nil,
                problems: ["launchctlProbeFailed"],
                summaries: ["could not query launchd: \(error)"]
            )
        }
        #endif
    }
}

// MARK: - StatusReport (the `--json` shape — see docs/data-model.md)

struct StatusReport: Encodable {
    struct RunSummary: Encodable {
        let runId: String
        let status: String
        let start: Date
        let end: Date?
        /// Seconds since `end` (or `start`, if the entry is somehow still
        /// running by the time this ran — see `HealthDerivation.setHealth`'s
        /// filter, which excludes `.running` entries from `lastBackup`, so
        /// this is belt-and-braces, not an expected path).
        let ageSeconds: Double

        init?(_ entry: RunIndexEntry?, now: Date) {
            guard let entry else { return nil }
            runId = entry.runId
            status = entry.status.rawValue
            start = entry.start
            end = entry.end
            ageSeconds = now.timeIntervalSince(entry.end ?? entry.start)
        }

        private enum CodingKeys: String, CodingKey {
            case runId, status, start, end, ageSeconds
        }

        // Explicit `null` for `end` when still absent — see
        // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runId, forKey: .runId)
            try container.encode(status, forKey: .status)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(ageSeconds, forKey: .ageSeconds)
        }
    }

    struct CurrentRunSummary: Encodable {
        let runId: String
        let kind: String
        let phase: String
        let percentDone: Int
        let bytesDone: Int
        let totalBytes: Int
        let filesDone: Int
        let totalFiles: Int

        init(_ state: CurrentRunState) {
            runId = state.runId
            kind = state.kind.rawValue
            phase = state.phase
            percentDone = Int((min(max(state.percentDone, 0), 1) * 100).rounded())
            bytesDone = state.bytesDone
            totalBytes = state.totalBytes
            filesDone = state.filesDone
            totalFiles = state.totalFiles
        }

        init?(_ state: CurrentRunState?) {
            guard let state else { return nil }
            self.init(state)
        }
    }

    /// A `current-run-<setId>.json` whose set is absent from this machine's
    /// resolved configuration. These runs still affect global health; this
    /// record makes that effect attributable in JSON and human output.
    struct UnattributedRun: Encodable {
        enum Liveness: String, Encodable {
            case live
            case stalled
            case abandoned
        }

        let setId: UUID
        let liveness: Liveness
        let currentRun: CurrentRunSummary
        let currentRunFile: String
    }

    struct DestinationStatus: Encodable {
        let id: UUID
        let label: String
        let isPrimary: Bool
        /// `nil` — never probed, not "unreachable". Distinguishing "unknown"
        /// from "known bad" is exactly the anti-silent-failure rule
        /// `docs/data-model.md` §fda-check.json applies to a different
        /// field; the same principle holds here.
        let reachable: Bool?
        let stale: Bool
        let lastSyncedAt: Date?
        let lastError: String?

        private enum CodingKeys: String, CodingKey {
            case id, label, isPrimary, reachable, stale, lastSyncedAt, lastError
        }

        // Explicit `null` for the three "unknown until probed" fields — see
        // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(isPrimary, forKey: .isPrimary)
            try container.encode(reachable, forKey: .reachable)
            try container.encode(stale, forKey: .stale)
            try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
            try container.encode(lastError, forKey: .lastError)
        }
    }

    /// Whether anything is going to fire the tick on this host.
    ///
    /// Whether this machine's locking machinery is usable at all.
    ///
    /// `usable: false` means a production lock path is broken; `null` means
    /// the health-only probe is damaged and production usability is unknown.
    /// `scope` distinguishes a machine-wide shared-lock outage, one damaged
    /// per-set lock, an administrative-only lock outage, and an inconclusive
    /// diagnostic probe. Probed live — see ``LockingHealth``.
    struct LockingStatus: Encodable {
        let usable: Bool?
        let dataDirectory: String
        /// The specific fault, `null` when usable.
        let problem: String?
        /// `"machine"`, `"set"`, `"administrative"`, `"diagnostic"`, or
        /// `null` when healthy.
        let scope: String?
        /// The affected set for a partial outage; otherwise `null`.
        let setId: UUID?

        init(paths: AppPaths, failure: LockingHealthFailure?) {
            switch failure?.scope {
            case .machine, .set, .administrative:
                usable = false
            case .diagnostic:
                usable = nil
            case nil:
                usable = true
            }
            self.dataDirectory = paths.root.path
            self.problem = failure.map { String(describing: $0) }
            switch failure?.scope {
            case .machine:
                scope = "machine"
                setId = nil
            case .set(let id):
                scope = "set"
                setId = id
            case .administrative:
                scope = "administrative"
                setId = nil
            case .diagnostic:
                scope = "diagnostic"
                setId = nil
            case nil:
                scope = nil
                setId = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case usable, dataDirectory, problem, scope, setId
        }

        // Explicit `null` for optionals, including an inconclusive `usable`.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(usable, forKey: .usable)
            try container.encode(dataDirectory, forKey: .dataDirectory)
            try container.encode(problem, forKey: .problem)
            try container.encode(scope, forKey: .scope)
            try container.encode(setId, forKey: .setId)
        }
    }

    /// `healthy: null` means the platform's scheduler probe could not give a
    /// definite answer: no systemd on Linux, or `launchctl print` itself
    /// failed on macOS. That is distinct from a definite `false`.
    ///
    /// Only `healthy: false` is a finding, and only it makes `status` exit 1.
    struct SchedulerStatus: Encodable {
        /// `"systemd-timer"`, `"launchd-agent"`, or `"unknown"`. Present so
        /// a script can tell which scheduler answered without inferring it
        /// from the platform.
        let kind: String
        let healthy: Bool?
        /// `TimerProblem.rawValue`s — stable identifiers to branch on.
        let problems: [String]
        /// The same problems as prose, in the same order, for a human
        /// reading the JSON or an alert body quoting it.
        let summaries: [String]

        private enum CodingKeys: String, CodingKey {
            case kind, healthy, problems, summaries
        }

        // Explicit `null` for `healthy` — see
        // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(healthy, forKey: .healthy)
            try container.encode(problems, forKey: .problems)
            try container.encode(summaries, forKey: .summaries)
        }
    }

    struct SetStatus: Encodable {
        let id: UUID
        let name: String
        let needsAttention: Bool
        let isRunning: Bool
        /// No backup has ever been attempted and the first-run grace window
        /// derived from the configuration mtimes has elapsed.
        let firstBackupOverdue: Bool
        /// Live progress from a run that was killed and never cleaned up.
        /// Mutually exclusive with `currentRun`: a `current-run` file is
        /// either one or the other (`RunStore.liveness(ofCurrentRun:)`).
        let abandonedRun: CurrentRunSummary?
        /// The file to delete, spelled out — the fix for an abandoned run is
        /// `rm <this>`, and a message that does not name it makes the reader
        /// go and derive the path from a UUID.
        let abandonedRunFile: String?
        /// Process still exists, but its awake-time heartbeat is stale.
        let stalledRun: CurrentRunSummary?
        /// Run log to inspect before deciding whether to terminate a stalled
        /// process. Unlike abandoned wreckage, its current-run file is not a
        /// safe cleanup target while the process owns the set lock.
        let stalledRunLog: String?
        let lastBackup: RunSummary?
        let lastCheck: RunSummary?
        let lastPrune: RunSummary?
        let currentRun: CurrentRunSummary?
        let nextDue: Date
        let destinations: [DestinationStatus]

        private enum CodingKeys: String, CodingKey {
            case id, name, needsAttention, isRunning, firstBackupOverdue, lastBackup, lastCheck, lastPrune
            case currentRun, nextDue, destinations, abandonedRun, abandonedRunFile
            case stalledRun, stalledRunLog
        }

        // Explicit `null` for every optional — see
        // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(needsAttention, forKey: .needsAttention)
            try container.encode(isRunning, forKey: .isRunning)
            try container.encode(firstBackupOverdue, forKey: .firstBackupOverdue)
            try container.encode(abandonedRun, forKey: .abandonedRun)
            try container.encode(abandonedRunFile, forKey: .abandonedRunFile)
            try container.encode(stalledRun, forKey: .stalledRun)
            try container.encode(stalledRunLog, forKey: .stalledRunLog)
            try container.encode(lastBackup, forKey: .lastBackup)
            try container.encode(lastCheck, forKey: .lastCheck)
            try container.encode(lastPrune, forKey: .lastPrune)
            try container.encode(currentRun, forKey: .currentRun)
            try container.encode(nextDue, forKey: .nextDue)
            try container.encode(destinations, forKey: .destinations)
        }
    }

    struct Exclusion: Encodable {
        let subject: String
        let setId: UUID
        let id: UUID
        let name: String
        let reason: String
        let description: String

        init(omission: ResolvedOmission) {
            switch omission.subject {
            case .backupSet:
                subject = "backupSet"
                setId = omission.id
            case .destination(let owningSetId):
                subject = "destination"
                setId = owningSetId
            }
            id = omission.id
            name = omission.name
            switch omission.reason {
            case .disabledForMachine: reason = "disabledForMachine"
            case .noEnabledDestinations: reason = "noEnabledDestinations"
            case .noSources: reason = "noSources"
            }
            description = "\(omission)"
        }
    }

    let machineId: String
    let generatedAt: Date
    /// `"idle"` | `"running"` | `"warning"` — `AppHealth.rawValue` verbatim,
    /// the same string the app's menu bar state maps to an SF Symbol from.
    let health: String
    let fullDiskAccessDenied: Bool
    let locking: LockingStatus
    let scheduler: SchedulerStatus?
    let sets: [SetStatus]
    let unattributedRuns: [UnattributedRun]
    let excludedHere: [Exclusion]

    private enum CodingKeys: String, CodingKey {
        case machineId, generatedAt, health, fullDiskAccessDenied, locking, scheduler, sets
        case unattributedRuns, excludedHere
    }

    // Explicit `null` for `scheduler` — see
    // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention. It
    // matters more here than most: a missing key and `"healthy": false` are
    // very different findings.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(health, forKey: .health)
        try container.encode(fullDiskAccessDenied, forKey: .fullDiskAccessDenied)
        try container.encode(locking, forKey: .locking)
        try container.encode(scheduler, forKey: .scheduler)
        try container.encode(sets, forKey: .sets)
        try container.encode(unattributedRuns, forKey: .unattributedRuns)
        try container.encode(excludedHere, forKey: .excludedHere)
    }

    // MARK: Human rendering

    func humanLines() -> [String] {
        var lines: [String] = []
        lines.append("machine \"\(machineId)\" — \(health)"
            + (fullDiskAccessDenied ? " (Full Disk Access denied)" : ""))
        // Ahead of the scheduler line: if this is broken, the scheduler
        // firing perfectly on time changes nothing.
        if locking.usable == false {
            if locking.scope == "set", let setId = locking.setId {
                lines.append(
                    "locking: ONE OR MORE BACKUP SETS CANNOT RUN "
                        + "(first detected: \(setId.uuidString.lowercased()))"
                )
            } else if locking.scope == "administrative" {
                lines.append("locking: SECRET CHANGES CANNOT RUN ON THIS MACHINE")
            } else {
                lines.append("locking: NOTHING CAN RUN ON THIS MACHINE")
            }
            lines.append("  - \(locking.problem ?? "the data directory is unusable")")
            lines.append("  detail: check ownership and permissions on \(locking.dataDirectory)")
        } else if locking.usable == nil {
            lines.append("locking: LIVE LOCKING CHECK IS INCONCLUSIVE")
            lines.append("  - diagnostic probe could not run: \(locking.problem ?? "unknown problem")")
            lines.append(
                "  detail: repair the health-only probe under \(locking.dataDirectory); "
                    + "production locks were not proven unusable"
            )
        }
        if let scheduler {
            // `if let` rather than `switch` over the `Bool?`. Swift 6.3
            // accepts `case true / case false / case nil` as exhaustive;
            // Swift 6.1 — which the `linux` CI container and the macos-15
            // runner's Xcode both use — does not, and rejects it outright.
            // The oldest toolchain this project builds on wins.
            if let healthy = scheduler.healthy {
                lines.append(healthy
                    ? "scheduler (\(scheduler.kind)): scheduled backups will happen"
                    : "scheduler (\(scheduler.kind)): SCHEDULED BACKUPS WILL NOT HAPPEN")
            } else {
                lines.append("scheduler: could not be determined on this host")
            }
            for summary in scheduler.summaries {
                lines.append("  - \(summary)")
            }
            if scheduler.healthy == false {
                if scheduler.kind == "launchd-agent" {
                    lines.append("  detail: open Restic Station → Settings → General → Background backups")
                } else {
                    lines.append("  detail: restic-station-helper timer status")
                }
            }
        }
        lines.append("")

        if sets.isEmpty {
            lines.append("no backup sets run on this machine.")
        }
        for set in sets {
            let flags = [
                set.isRunning ? "running" : nil,
                set.needsAttention ? "NEEDS ATTENTION" : nil,
            ].compactMap { $0 }
            let suffix = flags.isEmpty ? "" : " — \(flags.joined(separator: ", "))"
            lines.append("set \"\(set.name)\" (\(set.id.uuidString.lowercased()))\(suffix)")
            lines.append("    last backup: \(Self.describe(set.lastBackup))")
            if set.firstBackupOverdue {
                lines.append("                  FIRST BACKUP OVERDUE — no backup attempt since this set became visible")
            }
            lines.append("    last check:  \(Self.describe(set.lastCheck))")
            lines.append("    last prune:  \(Self.describe(set.lastPrune))")
            lines.append("    next due:    \(ConfigStore.makeISO8601Formatter().string(from: set.nextDue))")
            if let currentRun = set.currentRun {
                lines.append(
                    "    in progress: \(currentRun.kind) — \(currentRun.phase), "
                        + "\(currentRun.percentDone)% (\(currentRun.filesDone)/\(currentRun.totalFiles) files)"
                )
            }
            if let abandoned = set.abandonedRun {
                lines.append(
                    "    ABANDONED:   \(abandoned.kind) run \(abandoned.runId) was killed "
                        + "(stopped at \(abandoned.phase), \(abandoned.percentDone)%)"
                )
                if let file = set.abandonedRunFile {
                    // Quoted: a data directory may contain spaces, and this
                    // is printed as a command for someone to paste. An
                    // unquoted path with a `;` in it would run whatever
                    // followed (`@codex review` on #51).
                    lines.append("                 the next tick clears it; to clear it now: "
                        + "rm \(ShellQuoting.quoteIfNeeded(file))")
                }
            }
            if let stalled = set.stalledRun {
                lines.append(
                    "    STALLED:     \(stalled.kind) run \(stalled.runId) still has a process, "
                        + "but no heartbeat for more than 5 minutes of awake time "
                        + "(stopped at \(stalled.phase), \(stalled.percentDone)%)"
                )
                if let log = set.stalledRunLog {
                    lines.append("                 inspect the run log before terminating it: \(log)")
                }
            }
            for destination in set.destinations {
                let role = destination.isPrimary ? "primary" : "secondary"
                let reach = destination.reachable.map { $0 ? "reachable" : "UNREACHABLE" } ?? "not yet probed"
                let error = destination.lastError.map { " (\($0))" } ?? ""
                let staleFlag = destination.stale ? ", STALE" : ""
                lines.append("      - \(role) \"\(destination.label)\": \(reach)\(error)\(staleFlag)")
            }
        }

        if !unattributedRuns.isEmpty {
            lines.append("")
            lines.append("current runs for sets no longer configured:")
            for item in unattributedRuns {
                let run = item.currentRun
                let state = item.liveness.rawValue.uppercased()
                lines.append(
                    "  - \(state): \(run.kind) run \(run.runId) for set "
                        + "\(item.setId.uuidString.lowercased()) "
                        + "(\(run.phase), \(run.percentDone)%)"
                )
                switch item.liveness {
                case .abandoned:
                    lines.append("    the next tick clears it; to clear it now: rm "
                        + ShellQuoting.quoteIfNeeded(item.currentRunFile))
                case .stalled:
                    lines.append("    the process still owns this run; inspect it before terminating it")
                case .live:
                    lines.append("    the running helper should clear it when it finishes")
                }
            }
        }

        if !excludedHere.isEmpty {
            lines.append("")
            lines.append("excluded here, and why:")
            for exclusion in excludedHere {
                lines.append("  - \(exclusion.description)")
            }
        }
        return lines
    }

    private static func describe(_ summary: RunSummary?) -> String {
        guard let summary else { return "never" }
        return "\(summary.status), \(Int(summary.ageSeconds))s ago (\(summary.runId))"
    }
}
