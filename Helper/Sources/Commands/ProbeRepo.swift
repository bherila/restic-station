import ArgumentParser
import Foundation
import ResticStationCore

/// `probe-repo --set <uuid> --dest <uuid>` — an on-demand reachability
/// probe (the app's manual "check now" action; also what `tick` does for
/// every destination every 30 minutes, inline).
struct ProbeRepo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe-repo",
        abstract: "Probe one destination's reachability and record the result. "
            + "Exit 0 reachable, 3 offline, 1 error."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "The destination UUID to probe.")
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

        let probe = await context.reachability.probe(destination)
        let now = Date()
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
            FileHandle.standardError.write(Data("probe-repo: could not write repo-status: \(error)\n".utf8))
        }

        switch probe {
        case .reachable:
            print("\"\(destination.label)\": reachable")
            HelperExit.code(0)
        case .offline(let reason):
            print("\"\(destination.label)\": offline — \(reason)")
            HelperExit.code(3)
        case .error(let exitClass):
            print("\"\(destination.label)\": error — \(exitClass.userFacingMessage)")
            HelperExit.code(1)
        }
    }
}
