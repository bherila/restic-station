import ArgumentParser
import Foundation
import ResticStationCore

// MARK: - Selection

/// Which set and destination a read-only command acts on (#78, #80).
///
/// Two views, per `docs/data-model.md` §Two views. `backup dry-run` asks
/// "what would this machine's backup do", so it reads the **scheduling**
/// view and refuses a set switched off here. `snapshots list` and
/// `retention preview` read repositories, so they use the **addressable**
/// view, like `restore` and `probe-repo`: a host that disabled a set (a
/// restore or mirror target) can still inspect every repository the shared
/// config names. Both views apply the same overrides, so they agree on what
/// a repository is.
enum RepositorySelection {
    /// The set from the scheduling view: machine overrides applied, a set
    /// switched off here refused with `set_disabled_here`.
    static func set(_ id: UUID, scheduled: ResolvedConfig) throws -> BackupSet {
        if let backupSet = scheduled.set(id: id) {
            return backupSet
        }
        if let omission = scheduled.omissions.first(where: { $0.id == id }) {
            if case .disabledForMachine = omission.reason {
                throw CLIFailure.setDisabledHere(setId: id, machineId: scheduled.machineId)
            }
            throw CLIFailure(
                code: .configInvalid,
                message: CLIFailure.bounded("\(omission) (\"\(scheduled.machineId)\")"),
                details: CLIErrorDetails(setId: id, machineId: scheduled.machineId)
            )
        }
        throw CLIFailure.setNotFound(setId: id)
    }

    /// The set from the addressable view: overrides applied, nothing dropped.
    static func set(_ id: UUID, addressable: ResolvedConfig) throws -> BackupSet {
        guard let backupSet = addressable.set(id: id) else {
            throw CLIFailure.setNotFound(setId: id)
        }
        return backupSet
    }

    /// `id`, or the set's primary when `id` is nil.
    static func destination(_ id: UUID?, of backupSet: BackupSet) throws -> Destination {
        guard let id else {
            guard let primary = backupSet.destinations.first(where: { $0.isPrimary }) else {
                throw CLIFailure(
                    code: .configInvalid,
                    message: "This backup set has no primary destination.",
                    details: CLIErrorDetails(setId: backupSet.id)
                )
            }
            return primary
        }
        guard let destination = backupSet.destinations.first(where: { $0.id == id }) else {
            throw CLIFailure.destinationNotFound(setId: backupSet.id, destinationId: id)
        }
        return destination
    }
}

// MARK: - Shared JSON shapes

/// A destination as `snapshots list` and `retention preview` publish it:
/// no repository URL.
struct DestinationJSON: Encodable {
    let id: UUID
    let label: String
    /// `primary` or `secondary`.
    let role: String

    init(_ destination: Destination) {
        id = destination.id
        label = destination.label
        role = destination.isPrimary ? "primary" : "secondary"
    }
}

/// One snapshot, normalized (`docs/cli-json.md` §`snapshots list`).
///
/// `paths` is `null` unless the caller passed `--include-paths`: source
/// paths can reveal private structure, so the default is `pathCount` alone.
/// `reasons` is present only inside `retention preview`.
struct SnapshotJSON: Encodable {
    let id: String
    let shortId: String
    let time: Date
    let hostname: String
    let username: String
    let tags: [String]
    let parent: String?
    let pathCount: Int
    let paths: [String]?
    let reasons: [String]?

    init(_ snapshot: Snapshot, includePaths: Bool, reasons: [String]? = nil) {
        id = snapshot.id
        shortId = snapshot.shortId
        time = snapshot.time
        hostname = snapshot.hostname
        username = snapshot.username
        tags = snapshot.tags ?? []
        parent = snapshot.parent
        pathCount = snapshot.paths.count
        paths = includePaths ? snapshot.paths : nil
        self.reasons = reasons
    }

    private enum CodingKeys: String, CodingKey {
        case id, shortId, time, hostname, username, tags, parent, pathCount, paths, reasons
    }

    // Explicit `null` for `parent` and `paths` (`docs/data-model.md`
    // §Encoding conventions); `reasons` is part of one command's shape only.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(shortId, forKey: .shortId)
        try container.encode(time, forKey: .time)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(username, forKey: .username)
        try container.encode(tags, forKey: .tags)
        try container.encode(parent, forKey: .parent)
        try container.encode(pathCount, forKey: .pathCount)
        try container.encode(paths, forKey: .paths)
        try container.encodeIfPresent(reasons, forKey: .reasons)
    }
}

/// RFC 3339 in UTC, second precision, for human output.
func humanTime(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

// MARK: - snapshots list

/// `snapshots …` — read-only questions about one destination's snapshots.
struct Snapshots: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshots",
        abstract: "Inspect a destination's snapshots.",
        subcommands: [SnapshotsList.self]
    )
}

/// `snapshots list --set <uuid> [--dest <uuid>] [--limit <n>] [--include-paths] [--json]`
/// (#80). Read-only: no lock, no run record, no repo-status write.
struct SnapshotsList: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List one destination's snapshots, newest first. Source paths are left out "
            + "unless --include-paths. --json for scripting. Exit 0 ok, 1 error, 3 destination offline."
    )

    @Option(name: .long, help: "The backup set's UUID.")
    var set: UUID

    @Option(name: .long, help: "Destination UUID. Defaults to the set's primary.")
    var dest: UUID?

    @Option(
        name: .long,
        help: "At most this many snapshots, newest first (1–\(BackupEngine.snapshotListMaximumLimit), default \(BackupEngine.snapshotListDefaultLimit))."
    )
    var limit: Int = BackupEngine.snapshotListDefaultLimit

    @Flag(name: .long, help: "Include each snapshot's source paths. Left out by default: they can reveal private structure.")
    var includePaths = false

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// `snapshots list --json`'s `data` — see `docs/cli-json.md`.
    struct Report: Encodable {
        let setId: UUID
        let destination: DestinationJSON
        let totalCount: Int
        let limit: Int
        let pathsIncluded: Bool
        let snapshots: [SnapshotJSON]

        init(_ listing: SnapshotListing, includePaths: Bool) {
            setId = listing.setId
            destination = DestinationJSON(listing.destination)
            totalCount = listing.totalCount
            limit = listing.limit
            pathsIncluded = includePaths
            snapshots = listing.snapshots.map { SnapshotJSON($0, includePaths: includePaths) }
        }
    }

    func run() async throws {
        guard (1...BackupEngine.snapshotListMaximumLimit).contains(limit) else {
            throw CLIFailure.invalidArguments(
                "--limit must be between 1 and \(BackupEngine.snapshotListMaximumLimit)."
            )
        }
        let context = try await HelperContext.make()
        let backupSet = try RepositorySelection.set(set, addressable: context.addressable)
        let destination = try RepositorySelection.destination(dest, of: backupSet)

        let listing: SnapshotListing
        do {
            listing = try await context.engine.listSnapshots(backupSet, destination: destination, limit: limit)
        } catch {
            throw CLIFailure.classifyRepositoryQuery(error, setId: set)
        }

        if json {
            CLIJSON.print(Report(listing, includePaths: includePaths))
        } else {
            for line in Self.humanLines(listing, setName: backupSet.name, includePaths: includePaths) {
                print(line)
            }
        }
        HelperExit.code(HelperExitCode.ok.rawValue)
    }

    static func humanLines(_ listing: SnapshotListing, setName: String, includePaths: Bool) -> [String] {
        let role = listing.destination.isPrimary ? "primary" : "secondary"
        var lines = [
            "\"\(listing.destination.label)\" (\(role)) of \"\(setName)\": "
                + "\(listing.snapshots.count) of \(listing.totalCount) snapshot(s), newest first",
        ]
        for snapshot in listing.snapshots {
            var line = "  \(snapshot.shortId)  \(humanTime(snapshot.time))  \(snapshot.hostname)  "
                + "\(snapshot.paths.count) path(s)"
            if let tags = snapshot.tags, !tags.isEmpty {
                line += "  tags: \(tags.joined(separator: ","))"
            }
            lines.append(line)
            if includePaths {
                lines += snapshot.paths.map { "      \($0)" }
            }
        }
        if !includePaths && !listing.snapshots.isEmpty {
            lines.append("  (source paths left out; pass --include-paths to show them)")
        }
        return lines
    }
}
