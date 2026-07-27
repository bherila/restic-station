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
        let context = HelperContext.make()
        guard let backupSet = context.config.sets.first(where: { $0.id == set }) else {
            HelperExit.fail("no backup set with id \(set)")
        }
        guard let destination = backupSet.destinations.first(where: { $0.id == dest }) else {
            HelperExit.fail("destination \(dest) does not belong to backup set \(set)")
        }

        let status = await context.engine.initSecondary(backupSet, dest: destination)
        switch status {
        case .success:
            print("secondary \"\(destination.label)\" initialized")
        case .warning:
            print("secondary \"\(destination.label)\" initialized with warnings — see the run log")
        case .failed:
            HelperExit.fail("init-secondary failed — see the run log")
        case .skipped:
            HelperExit.fail("init-secondary was skipped (set busy or keychain unavailable) — try again")
        case .running:
            print("init-secondary \(status.rawValue)")
        }
    }
}
