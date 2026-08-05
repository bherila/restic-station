import ArgumentParser
import Foundation
import ResticStationCore

/// `unlock --set <uuid> --dest <uuid>` — removes stale repository locks from
/// one destination (`docs/ui-spec.md` §Maintenance: "Repository reports
/// locked? Remove stale locks"). `restic unlock` only removes locks whose
/// owning process is dead, so this is safe to offer as a one-click utility
/// (`docs/restic-cli.md` §Stale locks).
///
/// **Documented exception — this subcommand writes NO run record.** Every
/// other repository-touching subcommand goes through `BackupEngine`, which
/// begins a run, streams into `runs/<runId>/log.txt`, and finishes with a
/// `RunStatus`. `unlock` deliberately does not, for three reasons:
///
/// 1. `RunKind` has no case that describes it. Recording it as `check` or
///    `prune` would put a lie in `runs/index.jsonl` — the file the Runs
///    screen, `HealthDerivation.setHealth`, and the menu bar all read to
///    decide "what happened last" — and a stale-lock cleanup that made a
///    set's last run look like a check is worse than no record at all.
///    Adding a `RunKind` case is a data-model change (`docs/data-model.md`
///    §runs/index.jsonl), out of scope for the Maintenance UI task.
/// 2. It takes no per-set lock. The whole point of the button is to run when
///    something else appears stuck; blocking on `locks/set-<setId>.lock`
///    would make it useless exactly when it is needed.
/// 3. It is trivially observable without one: restic prints what it removed
///    ("successfully removed 1 locks", fixture `unlock.txt`), and that line
///    is echoed to stdout for the app to show. Nothing about the repository's
///    *contents* changes, so there is no history worth keeping.
///
/// The engine's own automatic exit-11 recovery (`docs/architecture.md`
/// §Error taxonomy) is unaffected — it unlocks and retries inside the run
/// that hit the lock, and that run *is* recorded.
struct Unlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Remove stale locks from one destination's repository (restic unlock; only locks of "
            + "dead processes are removed). Writes no run record — see the source for why. "
            + "Exit 0 ok, 1 error."
    )

    /// restic's `unlock` only rewrites the repository's lock files, so it is
    /// fast even on remote backends; a minute is a generous ceiling that
    /// still stops a hung network backend from wedging the UI's spinner
    /// forever.
    private static let timeout: TimeInterval = 60

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "The destination UUID whose repository should be unlocked.")
    var dest: UUID

    func run() async throws {
        let context = await HelperContext.make()
        // Repository utilities address every repository in the shared config,
        // including sets this machine does not back up (T24): `addressable`,
        // not `scheduled`.
        guard let backupSet = context.addressable.set(id: set) else {
            HelperExit.fail("no backup set with id \(set)")
        }
        guard let destination = backupSet.destinations.first(where: { $0.id == dest }) else {
            HelperExit.fail("destination \(dest) does not belong to backup set \(set)")
        }

        let outcome: ResticOutcome
        do {
            outcome = try await context.restic.run(
                .unlock(repo: destination.repoURL),
                for: ResticInvocation(destination: destination),
                timeout: Self.timeout
            )
        } catch let error as ResticRunnerError {
            HelperExit.fail("\"\(destination.label)\": \(error.userFacingMessage)")
        } catch {
            HelperExit.fail("\"\(destination.label)\": could not run restic unlock: \(error)")
        }

        guard outcome.status.isSuccess else {
            HelperExit.fail("\"\(destination.label)\": \(outcome.status.userFacingMessage)")
        }

        // `unlock` has no JSON mode; its whole output is one human line
        // (fixture `unlock.txt`: "successfully removed 1 locks"). A repo with
        // nothing to remove prints nothing at all.
        let output = outcome.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            print("\"\(destination.label)\": no stale locks to remove")
        } else {
            print("\"\(destination.label)\": \(output)")
        }
        HelperExit.code(0)
    }
}
