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
            + "Exit 0 always, except a hard config-load error, or a data directory or "
            + "tick lock that cannot be used at all (exit 1)."
    )

    func run() async throws {
        let paths = AppPaths.default()
        // Not `try?`. A data directory that cannot be created means this
        // tick can do nothing at all, and discarding the error handed that
        // to the lock below to express — which it did, as `false`, i.e. as
        // contention (#110).
        do {
            try paths.ensureDirectories()
        } catch {
            HelperExit.fail("tick: could not create the data directories under \(paths.root.path): \(error)")
        }

        // ── Step 1: tick.lock — busy means a previous tick is still
        // evaluating/running; exit 0 silently. ───────────────────────────
        let lock = FileLock(path: paths.tickLockFile, trustedRoot: paths.root)
        switch lock.acquire() {
        case .acquired:
            break
        case .busy:
            // The overwhelmingly common case, and not a fault: `tick` holds
            // this lock for the whole of any backup it starts, so on a host
            // with a backup running longer than the two-minute interval
            // *every* intervening tick lands here. Exit 0 — the issue text
            // proposed exit 2 for a contended lock, which would report the
            // agent as failing for the entire duration of every long backup.
            return
        case .failed(let failure):
            // The case this branch exists for: unopenable, wrong owner, or a
            // symlink at the lock path. Nothing this tick could do would
            // work, and reporting success would leave launchd/systemd — and
            // `status` — believing the schedule is being kept.
            HelperExit.fail("tick: could not acquire the tick lock: \(failure)")
        }
        defer { lock.release() }

        // Record launchd-context FDA evidence on every tick, before any
        // config gating: the Settings "Re-check" flow and the Background-
        // agent badge depend on this file being fresh, and it must be
        // written even when no sets or restic are configured yet.
        FdaCheck.probeAndRecord(context: "launchd", stateStore: StateStore(paths: paths))

        // ── Step 2: recover interrupted runs. ────────────────────────────
        //
        // Hoisted above the config and restic gates below, which it used to
        // sit after (it was step 3). Crash recovery needs only `RunStore` and `StateStore` —
        // no config, no restic — and the states where those gates return
        // early are exactly the ones where wreckage is most likely to be
        // stranded: the killed run's set was deleted afterwards, or restic
        // was uninstalled. Running it last meant `status` stayed in warning
        // forever on those hosts, contradicting this project's own promise
        // that the next tick clears it. Found by `@codex review` on #51.
        recoverInterruptedRuns(paths: paths)

        // ── Step 3: load config, resolve it for this machine; no config or
        // no sets that run here → exit 0. ────────────────────────────────
        let configStore = ConfigStore(paths: paths)
        let views: HelperContext.Views
        do {
            views = try HelperContext.loadViews(paths: paths, configStore: configStore)
        } catch {
            HelperExit.fail("tick: could not load configuration: \(error)")
        }
        // The scheduling view throughout: tick decides what to *back up*.
        let scheduled = views.scheduled
        let config = scheduled.config
        // Say *why* nothing ran rather than printing a bare "no backup sets"
        // for a config that plainly has some — an omission is the one thing
        // a scoping mistake looks like from the outside.
        for omission in scheduled.omissions {
            print("skipping \(omission) (machine \"\(scheduled.machineId)\")")
        }
        guard !config.sets.isEmpty else {
            print("no backup sets")
            return
        }
        let context: HelperContext
        switch try await HelperContext.makeTolerant(
            paths: paths,
            views: views,
            configStore: configStore
        ) {
        case .ready(let ready):
            context = ready
        case .noRestic(let result):
            // RunAtLoad tolerance: nothing usable configured yet, and
            // discovery found no usable restic either — not a hard error,
            // tick just has nothing to do. It still says *why*: a tick that
            // prints "restic not found" every two minutes on a host with a
            // too-old restic installed is the loop issue #50 is about.
            print(HelperContext.resticNotFoundMessage(paths: paths, result: result))
            return
        }

        // ── Step 4/5: sequential due sets (config order). ────────────────
        let now = Date()
        let calendar = Calendar.current
        /// Sets whose lock could not be *used* this tick. Non-empty means the
        /// tick exits non-zero, however much other work succeeded.
        var infrastructureFailures: [String] = []

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
                // A set that cannot take its own lock is a broken machine,
                // not a skipped cycle. Recorded here and reported at the end
                // rather than thrown immediately: the remaining sets are
                // still worth attempting, and the reprobe below still has
                // value — but this tick must not exit 0 (#110).
                if case .infrastructureFailure = outcome {
                    infrastructureFailures.append("set \"\(set.name)\": \(describe(outcome))")
                }
            }

            // "Backup wins": skip this set's check when its backup was due
            // in the same tick (the check runs on a later tick instead).
            let checkEnabled = set.checkPolicy?.enabled ?? false
            if !backupDue, checkEnabled {
                let checkDue = ScheduleMath.checkIsDue(lastCheckStart: scheduleState?.lastCheckStart, now: now)
                if checkDue {
                    let outcome = await context.engine.runCheck(set, trigger: .scheduled)
                    print("set \"\(set.name)\": check \(describe(outcome))")
                    if case .infrastructureFailure = outcome {
                        infrastructureFailures.append(
                            "set \"\(set.name)\": check \(describe(outcome))"
                        )
                    }
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
                    StandardStream.writeToStandardError(
                        Data("tick: could not write repo-status for \(destination.id): \(error)\n".utf8)
                    )
                }
            }
        }

        // ── Step 7: tick.lock released by the `defer` above. ─────────────
        //
        // Exit 0 only if every due set could actually be attempted. A tick
        // that printed "backup-set lock unusable" and then exited 0 is the
        // exact shape of the silent stoppage this whole change is about: the
        // set never runs again, and launchd/systemd keeps seeing success.
        guard infrastructureFailures.isEmpty else {
            HelperExit.fail(
                "tick: this machine could not run "
                    + "\(infrastructureFailures.count) scheduled operation(s):\n  "
                    + infrastructureFailures.joined(separator: "\n  ")
            )
        }
    }

    /// Rewrites dead runs as `failed` and clears the progress files they
    /// left behind. Needs only `RunStore`/`StateStore`, which is why it runs
    /// before this tick has a config or a restic binary.
    private func recoverInterruptedRuns(paths: AppPaths) {
        let runStore = RunStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        do {
            for run in try runStore.recoverInterrupted() {
                print("recovered interrupted run \(run.runId)")
            }
        } catch {
            StandardStream.write(Data("tick: could not recover interrupted runs: \(error)\n".utf8), to: .standardError)
        }

        // Unconditionally, not only for what `recoverInterrupted()` just
        // returned — see `clearAbandonedProgress`.
        clearAbandonedProgress(runStore: runStore, stateStore: stateStore, paths: paths)
    }

    /// Deletes every `state/current-run-<setId>.json` whose recorded process
    /// is gone. A stalled process still owns the set lock and is never swept.
    ///
    /// **Driven by `currentRunSetIDs()` rather than by what
    /// `recoverInterrupted()` returned**, which is not a refactor but the
    /// fix for a second way the warning could become permanent.
    /// `recoverInterrupted()` only returns runs it *itself* transitioned
    /// from `.running` to `.failed` (`RunStore`'s `guard metadata.status ==
    /// .running`), so wreckage whose metadata was already terminal was
    /// returned by nothing and cleared by nothing here. Two ways to get
    /// there, one of them routine:
    ///
    /// - **The upgrade cohort — every host this PR exists to rescue.** On
    ///   the previous release the first post-kill tick already rewrote the
    ///   run's metadata to `.failed` while nothing deleted the current-run
    ///   file. Those hosts arrive here with exactly the state the old
    ///   condition skipped.
    /// - **A tick killed** between `writeMetadataAtomic` and this call.
    ///
    /// Left unswept, and if the set was since deleted from the config, the
    /// consequence is the worst shape a health check has: `status` counts
    /// the run in `hasWarningConditions` (deliberately — an abandoned run
    /// for an unconfigured set has no `SetHealth` to carry it, so deleting a
    /// set must not silence it) and exits 1 forever, while `sets[]` covers
    /// only the resolved config and so names nothing. A permanent alarm with
    /// no stated reason is one a user learns to ignore, which lands back at
    /// the false-assurance failure this PR is about.
    ///
    /// Liveness is re-derived per file instead of matching a `runId`: under
    /// the lock, a current-run file whose own metadata says the process is
    /// gone is wreckage no matter which run left it.
    ///
    /// Without this the file survives forever, and a `current-run` file is
    /// what "a run is in flight" means to every reader — so one `SIGKILL`
    /// used to pin `AppHealth` to `.running`, which outranks `.warning`, and
    /// the menu bar stayed blue and `status` kept exiting 0 on a machine that
    /// had stopped backing up. Readers now detect that themselves
    /// (`RunStore.liveness(ofCurrentRun:)`), but detecting wreckage every
    /// time is not the same as clearing it: this is what makes the warning go
    /// away once it has been acted on.
    ///
    /// **Under the set lock**, which is the only thing that makes the
    /// liveness check sound. A newer run for the same set may already be
    /// underway (the crash was days ago; this tick only just noticed), and
    /// deleting its live progress would break the running backup's UI and
    /// make the health checks lie in the other direction. Deciding and then
    /// deleting without the lock left a window where a manual `run-set`
    /// could write its first phase marker in between and have it deleted —
    /// `tick.lock` does not exclude manual operations, so that race was
    /// real (`@codex review` on #51).
    ///
    /// Holding the lock inverts it: a live run for this set holds the same
    /// lock for its whole duration (`BackupEngine.makeSetLock`), so failing
    /// to acquire it *is* the answer — someone is running, the file is
    /// theirs, leave it alone.
    private func clearAbandonedProgress(runStore: RunStore, stateStore: StateStore, paths: AppPaths) {
        for setId in stateStore.currentRunSetIDs() {
            let lock = FileLock(path: paths.setLockFile(setId: setId), trustedRoot: paths.root)
            switch lock.acquire() {
            case .acquired:
                break
            case .busy:
                // Someone is running this set; the progress file is theirs.
                continue
            case .failed(let failure):
                // Reported but not fatal. Sweeping abandoned progress is
                // best-effort housekeeping, and this tick may still have
                // real backups to attempt — each of which now reports the
                // same fault itself, as a failed run, when it hits it.
                StandardStream.writeToStandardError(
                    Data("tick: could not acquire the lock for set \(setId): \(failure)\n".utf8)
                )
                continue
            }
            defer { lock.release() }

            // Re-read inside the lock: whatever was there before we held it
            // is not evidence of anything.
            guard let current = stateStore.readCurrentRun(setId: setId) else { continue }
            guard runStore.liveness(ofCurrentRun: current) == .abandoned else { continue }
            do {
                try stateStore.clearCurrentRun(setId: setId)
                print("  cleared abandoned progress \(paths.currentRunFile(setId: setId).lastPathComponent)")
            } catch {
                StandardStream.writeToStandardError(
                    Data("tick: could not clear abandoned progress for set \(setId): \(error)\n".utf8)
                )
            }
        }
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
        case .infrastructureFailure(let reason):
            return "cannot run here: \(reason)"
        }
    }

    private func describe(_ outcome: CheckRunOutcome) -> String {
        switch outcome {
        case .completed(let status):
            return status.rawValue
        case .skipped:
            return "skipped — another operation for this set is already running"
        case .retryable(let reason):
            return "retryable: \(reason)"
        case .misconfigured(let reason):
            return "misconfigured: \(reason)"
        case .infrastructureFailure(let reason):
            return "cannot run here: \(reason)"
        }
    }
}
