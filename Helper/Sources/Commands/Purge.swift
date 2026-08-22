import ArgumentParser
import Foundation
import ResticStationCore

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "purge",
        abstract: "Inspect snapshots that purge exclusions would rewrite.",
        subcommands: [PurgePreview.self, PurgeApply.self]
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
        /// One capability shared by every destination in this preview. It is
        /// intentionally data (a human must carry it to `purge apply`), not
        /// an error detail or a run-record field.
        let previewToken: String?

        private enum CodingKeys: String, CodingKey {
            case setId, destinationId, label, status, patterns, matched, changed
            case unattributed, rewriteOutput, message, previewToken
        }

        init(
            setId: UUID,
            destination: Destination,
            result: PurgePlanResult,
            previewToken: String?
        ) {
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
            self.previewToken = previewToken
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
            try container.encode(previewToken, forKey: .previewToken)
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

        // One session, so every destination's transcript and the token that
        // follows them describe the same restic binary. Previewing each
        // destination here and attaching an identity afterwards is exactly
        // the ordering #118 removed.
        let session: PurgePreviewSession
        do {
            session = try await context.engine.previewPurgeSession(
                set: backupSet,
                destinations: destinations
            )
        } catch {
            // Classified, not rethrown bare. `PurgeApplyError` means nothing
            // to the generic mapper, which lands every case on
            // `internal_error` — so "restic is missing" reached the operator
            // as an internal fault, in the one command whose entire job is
            // to tell them what is about to happen.
            throw CLIFailure.classifyPurgeOperation(error, setId: set)
        }
        // The session stops at the first destination that did not finish, so
        // this reports that destination's failure and never a later one's.
        for preview in session.previews {
            try Self.validate(result: preview.result, setId: set, destination: preview.destination)
        }
        let previewToken = session.token?.value
        let reports = session.previews.map {
            Report(setId: set, destination: $0.destination, result: $0.result, previewToken: previewToken)
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

    static func validate(
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
        case .infrastructureFailure:
            throw CLIFailure(
                code: .internalError,
                message: CLIFailure.bounded(
                    "The purge preview could not use local process-control state: "
                        + "\(result.message ?? "unknown infrastructure failure"). "
                        + "Check the permissions on the Restic Station data directory."
                ),
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
            // Attached form, so a copy-paste survives a token that starts
            // with `-` regardless of how the option is parsed. Suppressed
            // when nothing would change: there is nothing to apply.
            if let previewToken = report.previewToken, !report.changed.isEmpty {
                print("  apply with: purge apply --set \(report.setId.uuidString) --preview-token=\(previewToken)")
            }
        case .busy, .offline, .infrastructureFailure, .failed:
            // These states are rejected before a report is printed.
            break
        }
    }
}

/// The token-gated destructive half of purge. There is intentionally no
/// force/yes/environment bypass: `BackupEngine` refuses every request that
/// is not bound to a successful, current preview.
struct PurgeApply: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a reviewed purge preview token."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    /// `.unconditional` because the token is opaque base64url: roughly one
    /// in 64 begins with `-`, and ArgumentParser would otherwise read it as
    /// the next option and reject the exact space-separated form that
    /// `purge preview` prints. The user's 15-minute reviewed token would be
    /// burned on a usage error they had no way to avoid.
    @Option(name: .long, parsing: .unconditional, help: "The short-lived token returned by purge preview.")
    var previewToken: String

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    private struct ChildReport: Encodable {
        let runId: String
        let kind: RunKind
        let destinationId: UUID
        let status: RunStatus
    }

    private struct Report: Encodable {
        let setId: UUID
        let status: RunStatus
        let children: [ChildReport]
    }

    func run() async throws {
        let context = try await HelperContext.make()
        guard let backupSet = context.addressable.set(id: set) else {
            throw CLIFailure.setNotFound(setId: set)
        }

        let destinationIDs: [UUID]
        do {
            destinationIDs = try context.engine.purgeTokenDestinationIDs(previewToken)
        } catch {
            throw CLIFailure.classifyPurgeOperation(error, setId: set)
        }
        let destinations = destinationIDs.compactMap { id in
            backupSet.destinations.first(where: { $0.id == id })
        }
        guard destinations.count == destinationIDs.count else {
            throw CLIFailure(
                code: .operationNotAllowed,
                message: "The purge preview does not match the current backup set.",
                details: CLIErrorDetails(setId: set)
            )
        }

        let result: PurgeRunResult
        do {
            result = try await context.engine.runPurge(
                set: backupSet,
                destinations: destinations,
                token: previewToken
            )
        } catch {
            throw CLIFailure.classifyPurgeOperation(error, setId: set)
        }

        guard result.status == .success else {
            throw CLIFailure(
                code: .resticFailed,
                message: "Purge failed. See the run record for details.",
                details: CLIErrorDetails(
                    setId: set,
                    diagnosticReference: result.children.first?.runId
                )
            )
        }

        let report = Report(
            setId: set,
            status: result.status,
            children: result.children.map {
                ChildReport(runId: $0.runId, kind: $0.kind, destinationId: $0.destId, status: $0.status)
            }
        )
        if json {
            CLIJSON.print(report)
        } else if result.children.isEmpty {
            print("purge completed: no attributed snapshots needed rewriting")
        } else {
            print("purge \(result.status.rawValue): \(result.children.count) destination(s) processed")
        }
        HelperExit.code(0)
    }
}
