import ArgumentParser
import Foundation
import ResticStationCore

/// `retention …` — read-only questions about a set's retention policy.
///
/// There is no `retention apply`: manual retention apply is contained until
/// #82 and #111 land (`docs/cli-json.md` §Confirmation capabilities), and
/// scheduled retention runs through `run-set --kind backup` and `tick`.
struct Retention: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retention",
        abstract: "Inspect what a backup set's retention policy would keep and remove.",
        subcommands: [RetentionPreviewCommand.self]
    )
}

/// `retention preview --set <uuid> [--dest <uuid>] [--include-paths] [--json]`
/// (#80): `restic forget --json --dry-run` with the set's configured policy,
/// never `--prune`, under the set lock. Nothing is removed and nothing is
/// recorded.
struct RetentionPreviewCommand: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Show what the set's retention policy would keep and remove on one destination, "
            + "without removing anything. --json for scripting. Exit 0 ok, 1 error, 2 busy, 3 destination offline."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "Destination UUID. Defaults to the set's primary.")
    var dest: UUID?

    @Flag(name: .long, help: "Include source paths. Left out by default: they can reveal private structure.")
    var includePaths = false

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// The note every mirror's preview carries, in both output modes.
    static let mirrorNote = "a preview of a mirror is not evidence that it is safe to prune: "
        + "scheduled retention prunes a mirror only after that run's copy to it succeeds"
    static let behindNote = "this mirror's recorded last sync is older than the primary's, or was never recorded"

    static func warnings(_ preview: RetentionPreview) -> [String] {
        guard let mirror = preview.mirrorSync else { return [] }
        return mirror.behindPrimary ? [mirrorNote, behindNote] : [mirrorNote]
    }

    /// `retention preview --json`'s `data` — see `docs/cli-json.md`.
    struct Report: Encodable {
        struct Policy: Encodable {
            let keepLast: Int?
            let keepHourly: Int?
            let keepDaily: Int?
            let keepWeekly: Int?
            let keepMonthly: Int?
            let keepYearly: Int?

            init(_ policy: RetentionPolicy) {
                keepLast = policy.keepLast
                keepHourly = policy.keepHourly
                keepDaily = policy.keepDaily
                keepWeekly = policy.keepWeekly
                keepMonthly = policy.keepMonthly
                keepYearly = policy.keepYearly
            }

            private enum CodingKeys: String, CodingKey {
                case keepLast, keepHourly, keepDaily, keepWeekly, keepMonthly, keepYearly
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(keepLast, forKey: .keepLast)
                try container.encode(keepHourly, forKey: .keepHourly)
                try container.encode(keepDaily, forKey: .keepDaily)
                try container.encode(keepWeekly, forKey: .keepWeekly)
                try container.encode(keepMonthly, forKey: .keepMonthly)
                try container.encode(keepYearly, forKey: .keepYearly)
            }
        }

        struct Group: Encodable {
            let host: String?
            let tags: [String]
            let pathCount: Int
            let paths: [String]?
            let keep: [SnapshotJSON]
            let remove: [SnapshotJSON]

            init(_ group: RetentionPreview.Group, includePaths: Bool) {
                host = group.host
                tags = group.tags
                pathCount = group.paths.count
                paths = includePaths ? group.paths : nil
                keep = group.keep.map { SnapshotJSON($0.snapshot, includePaths: includePaths, reasons: $0.reasons) }
                remove = group.remove.map { SnapshotJSON($0, includePaths: includePaths, reasons: []) }
            }

            private enum CodingKeys: String, CodingKey {
                case host, tags, pathCount, paths, keep, remove
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(host, forKey: .host)
                try container.encode(tags, forKey: .tags)
                try container.encode(pathCount, forKey: .pathCount)
                try container.encode(paths, forKey: .paths)
                try container.encode(keep, forKey: .keep)
                try container.encode(remove, forKey: .remove)
            }
        }

        struct Mirror: Encodable {
            let lastSyncedAt: Date?
            let primaryLastSyncedAt: Date?
            let behindPrimary: Bool

            private enum CodingKeys: String, CodingKey {
                case lastSyncedAt, primaryLastSyncedAt, behindPrimary
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
                try container.encode(primaryLastSyncedAt, forKey: .primaryLastSyncedAt)
                try container.encode(behindPrimary, forKey: .behindPrimary)
            }
        }

        let setId: UUID
        let destination: DestinationJSON
        let previewedAt: Date
        let policy: Policy
        let keepCount: Int
        let removeCount: Int
        let pathsIncluded: Bool
        let groups: [Group]
        let mirror: Mirror?
        let fingerprint: String
        let warnings: [String]

        init(_ preview: RetentionPreview, includePaths: Bool) {
            setId = preview.setId
            destination = DestinationJSON(preview.destination)
            previewedAt = preview.previewedAt
            policy = Policy(preview.policy)
            keepCount = preview.keepCount
            removeCount = preview.removeCount
            pathsIncluded = includePaths
            groups = preview.groups.map { Group($0, includePaths: includePaths) }
            mirror = preview.mirrorSync.map {
                Mirror(
                    lastSyncedAt: $0.lastSyncedAt,
                    primaryLastSyncedAt: $0.primaryLastSyncedAt,
                    behindPrimary: $0.behindPrimary
                )
            }
            fingerprint = preview.fingerprint
            warnings = RetentionPreviewCommand.warnings(preview)
        }

        private enum CodingKeys: String, CodingKey {
            case setId, destination, previewedAt, policy, keepCount, removeCount
            case pathsIncluded, groups, mirror, fingerprint, warnings
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(setId, forKey: .setId)
            try container.encode(destination, forKey: .destination)
            try container.encode(previewedAt, forKey: .previewedAt)
            try container.encode(policy, forKey: .policy)
            try container.encode(keepCount, forKey: .keepCount)
            try container.encode(removeCount, forKey: .removeCount)
            try container.encode(pathsIncluded, forKey: .pathsIncluded)
            try container.encode(groups, forKey: .groups)
            try container.encode(mirror, forKey: .mirror)
            try container.encode(fingerprint, forKey: .fingerprint)
            try container.encode(warnings, forKey: .warnings)
        }
    }

    func run() async throws {
        let context = try await HelperContext.make()
        let backupSet = try RepositorySelection.set(set, addressable: context.addressable)
        let destination = try RepositorySelection.destination(dest, of: backupSet)

        let preview: RetentionPreview
        do {
            preview = try await context.engine.previewRetention(backupSet, destination: destination)
        } catch {
            throw CLIFailure.classifyRepositoryQuery(error, setId: set)
        }

        if json {
            CLIJSON.print(Report(preview, includePaths: includePaths))
        } else {
            for line in Self.humanLines(preview, setName: backupSet.name, includePaths: includePaths) {
                print(line)
            }
        }
        HelperExit.code(HelperExitCode.ok.rawValue)
    }

    static func describe(_ policy: RetentionPolicy) -> String {
        let rules: [(String, Int?)] = [
            ("keep-last", policy.keepLast),
            ("keep-hourly", policy.keepHourly),
            ("keep-daily", policy.keepDaily),
            ("keep-weekly", policy.keepWeekly),
            ("keep-monthly", policy.keepMonthly),
            ("keep-yearly", policy.keepYearly),
        ]
        return rules.compactMap { name, value in value.map { "\(name) \($0)" } }.joined(separator: ", ")
    }

    static func humanLines(_ preview: RetentionPreview, setName: String, includePaths: Bool) -> [String] {
        let role = preview.destination.isPrimary ? "primary" : "secondary"
        var lines = [
            "retention preview of \"\(setName)\" on \"\(preview.destination.label)\" (\(role)) — nothing was removed",
            "  policy: \(describe(preview.policy))",
            "  would keep \(preview.keepCount), remove \(preview.removeCount)",
        ]
        for group in preview.groups {
            var header = "  group: host \(group.host ?? "(any)"), \(group.paths.count) path(s)"
            if !group.tags.isEmpty {
                header += ", tags \(group.tags.joined(separator: ","))"
            }
            lines.append(header)
            if includePaths {
                lines += group.paths.map { "      \($0)" }
            }
            for kept in group.keep {
                let why = kept.reasons.isEmpty ? "" : "  \(kept.reasons.joined(separator: ", "))"
                lines.append("    keep    \(kept.snapshot.shortId)  \(humanTime(kept.snapshot.time))\(why)")
            }
            for removed in group.remove {
                lines.append("    remove  \(removed.shortId)  \(humanTime(removed.time))")
            }
        }
        if let mirror = preview.mirrorSync {
            let synced = mirror.lastSyncedAt.map(humanTime) ?? "never recorded"
            let primary = mirror.primaryLastSyncedAt.map(humanTime) ?? "never recorded"
            lines.append("  mirror last synced: \(synced); primary: \(primary)")
        }
        lines.append("  fingerprint: \(preview.fingerprint)")
        lines += warnings(preview).map { "  warning: \($0)" }
        return lines
    }
}
