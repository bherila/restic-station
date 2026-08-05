import ArgumentParser
import Foundation
import ResticStationCore

/// The 7-step tick algorithm from `docs/scheduling.md` §Tick algorithm,
/// verbatim — the single code path launchd's `StartInterval`/`RunAtLoad`
/// fires invoke.
struct Tick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tick",
        abstract: "Run one scheduling pass (invoked by launchd every 2 minutes). "
            + "Exit 0 always, except a hard config-load error (exit 1)."
    )

    func run() async throws {
        let paths = AppPaths.default()
        try? paths.ensureDirectories()

        // ── Step 1: tick.lock — busy means a previous tick is still
        // evaluating/running; exit 0 silently. ───────────────────────────
        let lock = FileLock(path: paths.tickLockFile)
        guard lock.tryAcquire() else {
            return
        }
        defer { lock.release() }

        // Record launchd-context FDA evidence on every tick, before any
        // config gating: the Settings "Re-check" flow and the Background-
        // agent badge depend on this file being fresh, and it must be
        // written even when no sets or restic are configured yet.
        FdaCheck.probeAndRecord(context: "launchd", stateStore: StateStore(paths: paths))

        // ── Step 2: load config; no config or no sets → exit 0. ─────────
        let configStore = ConfigStore(paths: paths)
        let config: AppConfig
        do {
            config = try configStore.load()
        } catch {
            HelperExit.fail("tick: could not load configuration: \(error)")
        }
        guard !config.sets.isEmpty else {
            print("no backup sets")
            return
        }
        guard let context = await HelperContext.makeTolerant(
            paths: paths,
            config: config,
            configStore: configStore
        ) else {
            // RunAtLoad tolerance: nothing usable configured yet, and
            // discovery found no restic either — not a hard error, tick just
            // has nothing to do.
            print(HelperContext.resticNotFoundMessage(paths: paths))
            return
        }

        // ── Step 3: recover interrupted runs. ────────────────────────────
        do {
            let recovered = try context.runStore.recoverInterrupted()
            for runId in recovered {
                print("recovered interrupted run \(runId)")
            }
        } catch {
            FileHandle.standardError.write(Data("tick: could not recover interrupted runs: \(error)\n".utf8))
        }

        // ── Step 4/5: sequential due sets (config order). ────────────────
        let now = Date()
        let calendar = Calendar.current

        for set in config.sets {
            let scheduleState = context.stateStore.readScheduleState()?.sets[set.id]

            let backupDue = ScheduleMath.isDue(
                schedule: set.schedule,
                lastRunStart: scheduleState?.lastBackupStart,
                now: now,
                calendar: calendar
            )
            if backupDue {
                let outcome = await context.engine.runSet(set, trigger: .scheduled)
                print("set \"\(set.name)\": \(describe(outcome))")
            }

            // "Backup wins": skip this set's check when its backup was due
            // in the same tick (the check runs on a later tick instead).
            let checkEnabled = set.checkPolicy?.enabled ?? false
            if !backupDue, checkEnabled {
                let checkDue = ScheduleMath.checkIsDue(lastCheckStart: scheduleState?.lastCheckStart, now: now)
                if checkDue {
                    let status = await context.engine.runCheck(set, trigger: .scheduled)
                    print("set \"\(set.name)\": check \(status.rawValue)")
                }
            }
        }

        // ── Step 6: 30-minute destination reprobe. ────────────────────────
        let reprobeThreshold: TimeInterval = 30 * 60
        for set in config.sets {
            for destination in set.destinations {
                let existing = context.stateStore.readRepoStatus(destId: destination.id)
                let dueForReprobe = existing.map { now.timeIntervalSince($0.probedAt) > reprobeThreshold } ?? true
                guard dueForReprobe else { continue }

                let probe = await context.reachability.probe(destination)
                do {
                    try context.stateStore.updateRepoStatus(destId: destination.id) { status in
                        status.probedAt = now
                        switch probe {
                        case .reachable:
                            status.reachable = true
                            status.lastError = nil
                        case .offline(let reason):
                            status.reachable = false
                            status.lastError = reason
                        case .error(let exitClass):
                            status.reachable = false
                            status.lastError = exitClass.userFacingMessage
                        }
                    }
                } catch {
                    FileHandle.standardError.write(
                        Data("tick: could not write repo-status for \(destination.id): \(error)\n".utf8)
                    )
                }
            }
        }

        // ── Step 7: tick.lock released by the `defer` above; exit 0. ────
    }

    private func describe(_ outcome: SetRunOutcome) -> String {
        switch outcome {
        case .completed(let status, _, let children):
            return "\(status.rawValue) (\(children.count) run\(children.count == 1 ? "" : "s"))"
        case .skipped:
            return "skipped — another operation for this set is already running"
        case .retryable(let reason):
            return "retryable: \(reason)"
        case .misconfigured(let reason):
            return "misconfigured: \(reason)"
        }
    }
}
