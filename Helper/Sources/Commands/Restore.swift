import ArgumentParser
import Foundation
import ResticStationCore

/// `restic-cli.md`/`RestoreRequest`'s overwrite policy is a plain
/// `String`-backed enum in Core (which must not depend on ArgumentParser) —
/// conformance is added here, in the Helper target, instead. The default
/// `init(argument:)` for `RawRepresentable where RawValue == String` covers
/// the whole implementation.
extension ResticCommand.OverwriteMode: @retroactive ExpressibleByArgument {}

/// `restore --set <uuid> --dest <uuid> --snapshot <id> --target <path>
/// [--sub <in-snapshot-path>] [--include <pat>]… [--overwrite <mode>]`
struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore files from a snapshot. Exit 0 ok (incl. partial-restore warnings), 1 error."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "The destination UUID to restore from.")
    var dest: UUID

    @Option(name: .long, help: "The snapshot id to restore.")
    var snapshot: String

    @Option(name: .long, help: "Filesystem path to restore into.")
    var target: String

    @Option(name: .long, help: "In-snapshot path to restore (default: the whole snapshot).")
    var sub: String?

    @Option(name: .long, help: "Restrict the restore to paths matching this pattern. Repeatable.")
    var include: [String] = []

    @Option(name: .long, help: "Overwrite policy: always, if-changed, if-newer, never. Default: restic's own (always).")
    var overwrite: ResticCommand.OverwriteMode?

    func run() async throws {
        let context = await HelperContext.make()
        guard let backupSet = context.config.sets.first(where: { $0.id == set }) else {
            HelperExit.fail("no backup set with id \(set)")
        }
        guard backupSet.destinations.contains(where: { $0.id == dest }) else {
            HelperExit.fail("destination \(dest) does not belong to backup set \(set)")
        }

        let request = RestoreRequest(
            destId: dest,
            snapshotID: snapshot,
            subpath: sub,
            targetPath: target,
            includes: include,
            overwriteMode: overwrite
        )
        let status = await context.engine.runRestore(request: request)
        switch status {
        case .success:
            print("restore completed")
        case .warning:
            print("restore completed with warnings — some items could not be restored, see the run log")
        case .failed:
            HelperExit.fail("restore failed — see the run log")
        case .skipped:
            HelperExit.fail("restore was skipped (set busy or keychain unavailable) — try again", code: 2)
        case .running:
            print("restore \(status.rawValue)")
        }
    }
}
