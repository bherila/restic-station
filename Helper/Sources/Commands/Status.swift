import ArgumentParser
import Foundation
import ResticStationCore

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
struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "The headless menu bar: per set, last run outcome+age, next due time, any "
            + "in-flight run's live progress, per-destination reachability+staleness, and last "
            + "check/prune. Reads only existing state — no restic invocation. --json for scripting "
            + "(e.g. a Nagios/Icinga check). Exit 0 healthy (including a run in flight), 1 if any "
            + "set needs attention."
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
            HelperExit.fail("could not load configuration: \(error)")
        }
        let machineId: String
        do {
            machineId = try MachineStore(paths: paths).load().machineId
        } catch {
            HelperExit.fail("could not read this machine's identity (\(paths.machineFile.path)): \(error)")
        }

        // `.scheduling`: this is exactly the view `HealthDerivation` is
        // documented to run on — what this machine backs up, staleness
        // included (docs/data-model.md §Per-machine scoping).
        let scheduled = config.resolved(for: machineId)

        let now = Date()
        let calendar = Calendar.current
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
        let recentRuns = (try? runStore.recentRuns(limit: .max)) ?? []

        var currentRuns: [UUID: CurrentRunState] = [:]
        for setId in stateStore.currentRunSetIDs() {
            if let state = stateStore.readCurrentRun(setId: setId) {
                currentRuns[setId] = state
            }
        }
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
            calendar: calendar
        )

        let fdaCheck = stateStore.readFdaCheck()
        let fdaDenied = HealthDerivation.fullDiskAccessDenied(from: fdaCheck)
        // Every live current-run file counts, including one for a set no
        // longer in the resolved config — `currentRunSetIDs()`'s documented
        // contract, which is what `HealthDerivation.appHealth`'s
        // `anyRunInFlight` parameter expects.
        let anyRunInFlight = !stateStore.currentRunSetIDs().isEmpty
        // `backgroundAgentEnabled` asks "is the scheduler (SMAppService /
        // the systemd --user timer) actually registered?" — a genuinely
        // platform-specific fact `status` has no view into today (Linux has
        // `timer status` for exactly this; macOS's SMAppService state is
        // app-only). Passing `true` keeps that dimension neutral rather than
        // guessing either a false "healthy" or a false "warning" into every
        // invocation. Documented here rather than silently baked in.
        let health = HealthDerivation.appHealth(
            setHealths: setHealths,
            anyRunInFlight: anyRunInFlight,
            fullDiskAccessDenied: fdaDenied,
            backgroundAgentEnabled: true
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
                lastBackup: StatusReport.RunSummary(setHealth.lastBackup, now: now),
                lastCheck: StatusReport.RunSummary(try? runStore.lastRun(setId: setHealth.setId, kind: .check), now: now),
                lastPrune: StatusReport.RunSummary(try? runStore.lastRun(setId: setHealth.setId, kind: .prune), now: now),
                currentRun: StatusReport.CurrentRunSummary(setHealth.currentRun),
                nextDue: setHealth.nextDue,
                destinations: destinations
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
            sets: sets,
            excludedHere: excludedHere
        )

        if json {
            CLIJSON.print(report)
        } else {
            for line in report.humanLines() {
                print(line)
            }
        }

        HelperExit.code(health == .warning ? 1 : 0)
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

        init?(_ state: CurrentRunState?) {
            guard let state else { return nil }
            runId = state.runId
            kind = state.kind.rawValue
            phase = state.phase
            percentDone = Int((min(max(state.percentDone, 0), 1) * 100).rounded())
            bytesDone = state.bytesDone
            totalBytes = state.totalBytes
            filesDone = state.filesDone
            totalFiles = state.totalFiles
        }
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

    struct SetStatus: Encodable {
        let id: UUID
        let name: String
        let needsAttention: Bool
        let isRunning: Bool
        let lastBackup: RunSummary?
        let lastCheck: RunSummary?
        let lastPrune: RunSummary?
        let currentRun: CurrentRunSummary?
        let nextDue: Date
        let destinations: [DestinationStatus]

        private enum CodingKeys: String, CodingKey {
            case id, name, needsAttention, isRunning, lastBackup, lastCheck, lastPrune
            case currentRun, nextDue, destinations
        }

        // Explicit `null` for every optional — see
        // `EffectiveConfigReport.SetEntry.encode(to:)` for the convention.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(needsAttention, forKey: .needsAttention)
            try container.encode(isRunning, forKey: .isRunning)
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
    let sets: [SetStatus]
    let excludedHere: [Exclusion]

    // MARK: Human rendering

    func humanLines() -> [String] {
        var lines: [String] = []
        lines.append("machine \"\(machineId)\" — \(health)"
            + (fullDiskAccessDenied ? " (Full Disk Access denied)" : ""))
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
            lines.append("    last check:  \(Self.describe(set.lastCheck))")
            lines.append("    last prune:  \(Self.describe(set.lastPrune))")
            lines.append("    next due:    \(ConfigStore.makeISO8601Formatter().string(from: set.nextDue))")
            if let currentRun = set.currentRun {
                lines.append(
                    "    in progress: \(currentRun.kind) — \(currentRun.phase), "
                        + "\(currentRun.percentDone)% (\(currentRun.filesDone)/\(currentRun.totalFiles) files)"
                )
            }
            for destination in set.destinations {
                let role = destination.isPrimary ? "primary" : "secondary"
                let reach = destination.reachable.map { $0 ? "reachable" : "UNREACHABLE" } ?? "not yet probed"
                let error = destination.lastError.map { " (\($0))" } ?? ""
                let staleFlag = destination.stale ? ", STALE" : ""
                lines.append("      - \(role) \"\(destination.label)\": \(reach)\(error)\(staleFlag)")
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
