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

    func run() async throws {
        let context = await HelperContext.make()
        guard let backupSet = context.config.sets.first(where: { $0.id == set }) else {
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
