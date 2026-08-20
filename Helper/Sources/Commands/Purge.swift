import ArgumentParser
import Foundation
import ResticStationCore

/// `purge preview` is intentionally the only purge surface in #87.  Apply is
/// introduced later, behind a preview token, in #88.
struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Inspect snapshots that purge exclusions would rewrite.",
        subcommands: [PurgePreview.self]
    )
}

struct PurgePreview: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Preview purge exclusions without modifying a repository."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "Preview only this destination UUID.")
    var dest: UUID?

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    private struct SnapshotReport: Encodable {
        let id: String
        let shortId: String
        let time: Date
        let paths: [String]
        let hostname: String

        init(_ snapshot: Snapshot) {
            id = snapshot.id
            shortId = snapshot.shortId
            time = snapshot.time
            paths = snapshot.paths
            hostname = snapshot.hostname
        }
    }

    private struct Report: Encodable {
        let setId: UUID
        let destinationId: UUID
        let label: String
        let status: PurgePlanResult.Status
        let patterns: [String]
        let matched: [SnapshotReport]
        let changed: [SnapshotReport]
        let unattributed: [SnapshotReport]
        let rewriteOutput: String?
        let message: String?

        private enum CodingKeys: String, CodingKey {
            case setId, destinationId, label, status, patterns, matched, changed
            case unattributed, rewriteOutput, message
        }

        init(setId: UUID, destination: Destination, result: PurgePlanResult) {
            self.setId = setId
            self.destinationId = destination.id
            self.label = destination.label
            self.status = result.status
            self.patterns = result.plan.patterns
            self.matched = result.plan.matched.map(SnapshotReport.init)
            self.changed = result.changed.map(SnapshotReport.init)
            self.unattributed = result.plan.unattributed.map(SnapshotReport.init)
            self.rewriteOutput = result.rewrite?.rawOutput
            self.message = result.message
        }

        // The optional fields are part of a reported payload, so they are
        // explicit null rather than synthesized-encoder omissions.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(setId, forKey: .setId)
            try container.encode(destinationId, forKey: .destinationId)
            try container.encode(label, forKey: .label)
            try container.encode(status.rawValue, forKey: .status)
            try container.encode(patterns, forKey: .patterns)
            try container.encode(matched, forKey: .matched)
            try container.encode(changed, forKey: .changed)
            try container.encode(unattributed, forKey: .unattributed)
            try container.encode(rewriteOutput, forKey: .rewriteOutput)
            try container.encode(message, forKey: .message)
        }
    }

    func run() async throws {
        let context = try await HelperContext.make()
        guard let backupSet = context.addressable.set(id: set) else {
            throw CLIFailure.setNotFound(setId: set)
        }

        let destinations: [Destination]
        if let dest {
            guard let destination = backupSet.destinations.first(where: { $0.id == dest }) else {
                throw CLIFailure.destinationNotFound(setId: set, destinationId: dest)
            }
            destinations = [destination]
        } else {
            destinations = backupSet.destinations
        }

        var reports: [Report] = []
        for destination in destinations {
            let result = await context.engine.previewPurge(set: backupSet, destination: destination)
            try Self.validate(result: result, setId: set, destination: destination)
            reports.append(Report(setId: set, destination: destination, result: result))
        }

        if json {
            CLIJSON.print(reports)
        } else {
            for report in reports {
                Self.printHuman(report)
            }
        }
        HelperExit.code(0)
    }

    private static func validate(
        result: PurgePlanResult,
        setId: UUID,
        destination: Destination
    ) throws {
        switch result.status {
        case .empty, .ready:
            return
        case .busy:
            throw CLIFailure.setBusy(setId: setId)
        case .offline:
            throw CLIFailure(
                code: .repositoryOffline,
                message: CLIFailure.bounded("Destination \(destination.label) is offline: \(result.message ?? "try again later")"),
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        case .failed:
            throw CLIFailure(
                code: .resticFailed,
                message: CLIFailure.bounded(result.message ?? "Purge preview failed."),
                details: CLIErrorDetails(setId: setId, destinationId: destination.id)
            )
        }
    }

    private static func printHuman(_ report: Report) {
        switch report.status {
        case .empty:
            print("\"\(report.label)\": nothing to do — purgeExcludes is empty")
        case .ready:
            if report.changed.isEmpty {
                print("\"\(report.label)\": no matching snapshots would change")
            } else {
                print("\"\(report.label)\": \(report.changed.count) snapshot(s) would be rewritten")
                for snapshot in report.changed {
                    print("  \(snapshot.shortId) — \(snapshot.paths.joined(separator: ", "))")
                }
            }
            if !report.unattributed.isEmpty {
                print("  declined to attribute \(report.unattributed.count) snapshot(s):")
                for snapshot in report.unattributed {
                    print("    \(snapshot.shortId) [\(snapshot.hostname)] — \(snapshot.paths.joined(separator: ", "))")
                }
            }
            print("  space is not reclaimed until a prune runs")
        case .busy, .offline, .failed:
            // These states are rejected before a report is printed.
            break
        }
    }
}
