import ArgumentParser
import Foundation
import ResticStationCore

/// `run-set --set <uuid> [--kind backup|check|prune]` — the manual-trigger
/// entry point (`docs/tasks/T10-helper-cli.md`): "Back Up Now" and friends
/// from the app spawn exactly this.
struct RunSet: AsyncParsableCommand {
    enum Kind: String, ExpressibleByArgument, CaseIterable {
        case backup
        case check
        case prune
    }

    static let configuration = CommandConfiguration(
        commandName: "run-set",
        abstract: "Run one backup set now (manual trigger). "
            + "Exit 0 ok, 1 error, 2 busy (another operation for this set is already running)."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "Which operation to run.")
    var kind: Kind = .backup

    /// Refuse unless `config.json` is byte-identical to what the caller
    /// reviewed. The app sends this for **Apply retention now**, whose
    /// preview is app-direct and therefore has no helper-issued token the
    /// way `maintenance prune` does. Without it, a config change landing
    /// between the dialog and the click — a hand edit, or this fleet's
    /// config sync — silently applied a policy the operator never saw to a
    /// destination list they were never shown.
    @Option(name: .long, parsing: .unconditional,
            help: "Refuse unless config.json still matches this fingerprint.")
    var expectedConfig: String?

    func run() async throws {
        let context = try await HelperContext.make()
        if let expectedConfig {
            let current = ConfigStore(paths: context.paths).fileFingerprint()
            guard current == expectedConfig else {
                throw CLIFailure(
                    code: .operationNotAllowed,
                    message: "The configuration changed after this operation was reviewed. "
                        + "Review the updated settings and try again.",
                    details: CLIErrorDetails(setId: set)
                )
            }
        }
        // `scheduled`: backup, check and prune are all things this machine
        // *does to* a set, so a set disabled here must not run — unlike the
        // repository utilities, which use `addressable`.
        guard let backupSet = context.scheduled.set(id: set) else {
            // The set may exist in the shared `config.json` but not run on
            // this machine (T24). Say which, instead of "no such set" — a
            // per-machine omission is the one thing a scoping mistake looks
            // like from the outside.
            if let omission = context.scheduled.omissions.first(where: { $0.id == set }) {
                HelperExit.fail("\(omission) (\"\(context.scheduled.machineId)\")")
            }
            HelperExit.fail("no backup set with id \(set)")
        }

        switch kind {
        case .backup:
            let outcome = await context.engine.runSet(backupSet, trigger: .manual)
            handle(outcome)
        case .check:
            let before = Date()
            let status = await context.engine.runCheck(backupSet, trigger: .manual)
            handle(status, kind: .check, setId: backupSet.id, since: before, context: context)
        case .prune:
            let before = Date()
            let status = await context.engine.runPrune(backupSet)
            handle(status, kind: .prune, setId: backupSet.id, since: before, context: context)
        }
    }

    // MARK: - SetRunOutcome (backup)

    private func handle(_ outcome: SetRunOutcome) {
        switch outcome {
        case .completed(let status, _, let children):
            switch status {
            case .failed:
                HelperExit.fail("backup failed — see the run log")
            default:
                print("backup \(status.rawValue) (\(children.count) run\(children.count == 1 ? "" : "s"))")
            }
        case .skipped:
            // SetRunOutcome.skipped is unambiguous: it is written only when
            // the set lock was busy (BackupEngine.runSet's doc comment).
            HelperExit.fail("another operation for this backup set is already running", code: 2)
        case .retryable(let reason):
            // Not an error: nothing was recorded, so the next tick simply
            // tries again.
            print("backup deferred (\(reason)) — will retry next tick")
        case .misconfigured(let reason):
            HelperExit.fail("backup set is misconfigured: \(reason)")
        }
    }

    // MARK: - RunStatus (check / prune)

    /// `runCheck`/`runPrune` return a bare `RunStatus`, whose `.skipped`
    /// case is overloaded (lock busy *or* an unavailable keychain,
    /// unlike `SetRunOutcome`'s two distinct cases). Disambiguated here by
    /// checking whether a `.skipped` run record was *just* written with the
    /// lock-busy message (`BackupEngine.recordSkipped`) — no run record at
    /// all means the keychain-retryable path.
    private func handle(
        _ status: RunStatus,
        kind: RunKind,
        setId: UUID,
        since: Date,
        context: HelperContext
    ) {
        switch status {
        case .success, .warning:
            print("\(kind.rawValue) \(status.rawValue)")
        case .failed:
            HelperExit.fail("\(kind.rawValue) failed — see the run log")
        case .skipped:
            if isLockBusy(kind: kind, setId: setId, since: since, context: context) {
                HelperExit.fail("another operation for this backup set is already running", code: 2)
            } else {
                print("\(kind.rawValue) deferred — will retry next tick")
            }
        case .running:
            print("\(kind.rawValue) \(status.rawValue)")
        }
    }

    private func isLockBusy(kind: RunKind, setId: UUID, since: Date, context: HelperContext) -> Bool {
        guard let last = try? context.runStore.lastRun(setId: setId, kind: kind) else { return false }
        return last.start >= since
            && last.status == .skipped
            && last.errorSummary == "another operation for this backup set is already running"
    }
}
