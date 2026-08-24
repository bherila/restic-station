import ArgumentParser
import Foundation
import ResticStationCore

/// `init-secondary --set <uuid> --dest <uuid>` — `restic init --from-repo`
/// against a newly-added secondary destination.
struct InitSecondary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init-secondary",
        abstract: "Initialize a secondary repository from the set's primary. Exit 0 ok, 1 error."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "The secondary destination's UUID.")
    var dest: UUID

    func run() async throws {
        let context = try await HelperContext.make()
        // Repository utilities address every repository in the shared config,
        // including sets this machine does not back up (T24): `addressable`,
        // not `scheduled`.
        guard let backupSet = context.addressable.set(id: set) else {
            HelperExit.fail("no backup set with id \(set)")
        }
        guard let destination = backupSet.destinations.first(where: { $0.id == dest }) else {
            HelperExit.fail("destination \(dest) does not belong to backup set \(set)")
        }

        let outcome = await context.engine.initSecondary(backupSet, dest: destination)
        switch outcome {
        case .completed(let status):
            switch status {
            case .success:
                print("secondary \"\(destination.label)\" initialized")
            case .warning:
                print("secondary \"\(destination.label)\" initialized with warnings — see the run log")
            case .failed:
                HelperExit.fail("init-secondary failed — see the run log")
            case .skipped:
                HelperExit.fail("init-secondary was skipped — try again")
            case .running:
                print("init-secondary \(status.rawValue)")
            }
        case .skipped:
            HelperExit.fail("init-secondary was skipped (set busy or keychain unavailable) — try again")
        case .infrastructureFailure(let reason, let operationMayHaveRun):
            HelperExit.fail(operationMayHaveRun
                ? "init-secondary may have run, but its result could not be recorded or trusted: \(reason). "
                    + "Inspect the repository before retrying."
                : "this machine cannot run init-secondary: \(reason)")
        case .operationNotAllowed(let reason):
            // Not reachable today: only manual retention apply is
            // contained. Exhaustive so that containing another
            // operation later cannot silently fall through here. If that
            // day comes, refuse in `run()` before `HelperContext.make()`
            // with a structured `CLIFailure`, as `RunSet` does — this arm
            // is a last-resort sink, not the refusal pattern.
            HelperExit.fail(reason)
        }
    }
}
