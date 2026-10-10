import ArgumentParser
import Foundation
import ResticStationCore

/// `backup …` — read-only questions about a set's backup. Today that is
/// `dry-run` alone (#78); a real backup is still `run-set`.
struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Inspect what a backup set's backup would do, without running it.",
        subcommands: [BackupDryRunCommand.self]
    )
}

/// `backup dry-run --set <uuid> [--json]` — what a backup of one set would
/// add right now, measured by `restic backup --dry-run` against the primary
/// (`docs/restic-cli.md` §backup dry-run).
///
/// Nothing is written: no snapshot, no run record, no schedule or
/// repo-status change, no copy, retention or `unlock`.
struct BackupDryRunCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "dry-run",
        abstract: "Show what a backup of one set would add, without writing a snapshot. "
            + "--json for scripting. Exit 0 done (including a warning), 1 error, "
            + "2 busy, 3 primary offline."
    )

    @Option(name: .long, help: "The backup set's UUID. Names are not accepted: they can change and repeat.")
    var set: UUID

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// `backup dry-run --json`'s `data` — see `docs/cli-json.md`.
    ///
    /// Path-free by construction: no source, no file name, no repository
    /// URL, and no `snapshot_id` — restic prints one for a dry run too, and
    /// it names a snapshot that was never saved.
    struct Report: Encodable {
        struct Primary: Encodable {
            let id: UUID
            let label: String
        }

        /// restic's figures, renamed to this contract's casing. Each is
        /// `null` when restic left it out, never `0`.
        struct Summary: Encodable {
            let filesNew: Int?
            let filesChanged: Int?
            let filesUnmodified: Int?
            let dirsNew: Int?
            let dirsChanged: Int?
            let dirsUnmodified: Int?
            let totalFilesProcessed: Int?
            let totalBytesProcessed: Int?
            let dataAdded: Int?
            let dataAddedPacked: Int?

            init(_ summary: BackupSummary) {
                filesNew = summary.filesNew
                filesChanged = summary.filesChanged
                filesUnmodified = summary.filesUnmodified
                dirsNew = summary.dirsNew
                dirsChanged = summary.dirsChanged
                dirsUnmodified = summary.dirsUnmodified
                totalFilesProcessed = summary.totalFilesProcessed
                totalBytesProcessed = summary.totalBytesProcessed
                dataAdded = summary.dataAdded
                dataAddedPacked = summary.dataAddedPacked
            }

            private enum CodingKeys: String, CodingKey {
                case filesNew, filesChanged, filesUnmodified
                case dirsNew, dirsChanged, dirsUnmodified
                case totalFilesProcessed, totalBytesProcessed
                case dataAdded, dataAddedPacked
            }

            // Explicit `null`, never an omitted key (`docs/data-model.md`
            // §Encoding conventions).
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(filesNew, forKey: .filesNew)
                try container.encode(filesChanged, forKey: .filesChanged)
                try container.encode(filesUnmodified, forKey: .filesUnmodified)
                try container.encode(dirsNew, forKey: .dirsNew)
                try container.encode(dirsChanged, forKey: .dirsChanged)
                try container.encode(dirsUnmodified, forKey: .dirsUnmodified)
                try container.encode(totalFilesProcessed, forKey: .totalFilesProcessed)
                try container.encode(totalBytesProcessed, forKey: .totalBytesProcessed)
                try container.encode(dataAdded, forKey: .dataAdded)
                try container.encode(dataAddedPacked, forKey: .dataAddedPacked)
            }
        }

        let operation = "backup-dry-run"
        let setId: UUID
        let setName: String
        let primary: Primary
        let outcome: String
        let resticExitCode: Int32
        let cloudFilesExcluded: Bool
        let excludeCaches: Bool
        let excludePatternCount: Int
        let summary: Summary
        let warnings: [String]

        init(_ report: BackupDryRunReport) {
            setId = report.setId
            setName = report.setName
            primary = Primary(id: report.primary.id, label: report.primary.label)
            outcome = report.outcome.rawValue
            resticExitCode = report.resticExitCode
            cloudFilesExcluded = report.cloudFilesExcluded
            excludeCaches = report.excludeCaches
            excludePatternCount = report.excludePatternCount
            summary = Summary(report.summary)
            warnings = report.warnings
        }
    }

    func run() async throws {
        let context = try await HelperContext.make()
        // `scheduled`, as `run-set` does: a dry run answers "what would this
        // machine's backup do", so it resolves the set exactly as this
        // machine's backup would — machine overrides applied, and a set
        // switched off here refused rather than previewed.
        guard let backupSet = context.scheduled.set(id: set) else {
            if let omission = context.scheduled.omissions.first(where: { $0.id == set }) {
                if case .disabledForMachine = omission.reason {
                    throw CLIFailure.setDisabledHere(setId: set, machineId: context.scheduled.machineId)
                }
                throw CLIFailure(
                    code: .configInvalid,
                    message: CLIFailure.bounded("\(omission) (\"\(context.scheduled.machineId)\")"),
                    details: CLIErrorDetails(setId: set, machineId: context.scheduled.machineId)
                )
            }
            throw CLIFailure.setNotFound(setId: set)
        }

        let report: BackupDryRunReport
        do {
            report = try await context.engine.backupDryRun(backupSet)
        } catch {
            throw CLIFailure.classifyBackupDryRun(error, setId: set)
        }

        if json {
            CLIJSON.print(Report(report))
        } else {
            for line in Self.humanLines(report) {
                print(line)
            }
        }
        HelperExit.code(HelperExitCode.ok.rawValue)
    }

    static func humanLines(_ report: BackupDryRunReport) -> [String] {
        let summary = report.summary
        func count(_ value: Int?) -> String { value.map(String.init) ?? "?" }
        func bytes(_ value: Int?) -> String { value.map(Self.byteCount) ?? "?" }
        var lines = [
            "dry run of \"\(report.setName)\" to \"\(report.primary.label)\" — nothing was written",
            "  files: \(count(summary.filesNew)) new, \(count(summary.filesChanged)) changed, "
                + "\(count(summary.filesUnmodified)) unmodified",
            "  processed: \(count(summary.totalFilesProcessed)) files, \(bytes(summary.totalBytesProcessed))",
            "  would add: \(bytes(summary.dataAdded)) (\(bytes(summary.dataAddedPacked)) packed)",
        ]
        lines += report.logNotes.map { "  \($0)" }
        lines += report.warnings.map { "  warning: \($0)" }
        return lines
    }

    /// Binary units, as restic prints them. Not `ByteCountFormatter`: the
    /// static Linux build's Foundation is not one to lean on for it.
    static func byteCount(_ value: Int) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f", amount) + " " + units[unit]
    }
}
