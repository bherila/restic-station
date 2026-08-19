import ArgumentParser
import Foundation
import ResticStationCore

/// `sets …` — inventory of the backup sets in `config.json`.
struct Sets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sets",
        abstract: "Inspect the backup sets in config.json. Exit 0 ok, 1 error.",
        subcommands: [SetsList.self]
    )
}

// MARK: - sets list

struct SetsList: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every backup set: id, name, enabled-here, sources, destination count, "
            + "and schedule. --json for scripting. Exit 0 ok, 1 error."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let paths = AppPaths.default()
        let config: AppConfig
        do {
            config = try ConfigStore(paths: paths).load()
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
        let machineId: String
        do {
            machineId = try MachineStore(paths: paths).load().machineId
        } catch {
            throw CLIFailure.machineIdentityUnreadable(path: paths.machineFile.path, underlying: error)
        }

        let scheduledIds = Set(config.resolved(for: machineId).config.sets.map(\.id))
        // `.addressable`: an inventory command must list every set this
        // machine knows about, not just the ones it backs up — silently
        // omitting an excluded set from `sets list` is exactly the failure
        // mode this task exists to prevent (`enabledHere` says which is
        // which; nothing is ever left out because of it).
        let addressable = config.addressable(for: machineId)

        let entries = addressable.config.sets.map { set in
            SetsListEntry(
                id: set.id,
                name: set.name,
                enabledHere: scheduledIds.contains(set.id),
                sources: set.sources,
                destinationCount: set.destinations.count,
                schedule: set.schedule
            )
        }

        if json {
            CLIJSON.print(entries)
        } else if entries.isEmpty {
            print("no backup sets configured")
        } else {
            for entry in entries {
                let here = entry.enabledHere ? "enabled here" : "excluded here"
                print(
                    "\(entry.id.uuidString.lowercased())  \"\(entry.name)\"  \(here)  "
                        + "\(entry.destinationCount) destination(s)  \(EffectiveConfigReport.describe(entry.schedule))"
                )
                for source in entry.sources {
                    print("    \(source)")
                }
            }
        }
        HelperExit.code(0)
    }
}

/// `sets list --json`'s per-element shape — see `docs/data-model.md`.
struct SetsListEntry: Encodable {
    let id: UUID
    let name: String
    let enabledHere: Bool
    let sources: [String]
    let destinationCount: Int
    let schedule: Schedule
}
