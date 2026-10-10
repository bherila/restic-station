import Foundation

// MARK: - SnapshotListing

/// `snapshots list` (#80): one destination's snapshots, newest first.
///
/// Produced only by ``BackupEngine/listSnapshots(_:destination:limit:)``.
/// The snapshots keep their source `paths`; whether a surface publishes
/// them is that surface's decision (`docs/cli-json.md` omits them unless
/// asked, because they can reveal private structure).
public struct SnapshotListing: Sendable, Equatable {
    public let setId: UUID
    public let destination: Destination
    /// How many snapshots the repository holds, before ``limit``.
    public let totalCount: Int
    /// The cap that was applied.
    public let limit: Int
    /// At most ``limit`` snapshots, newest first; ties broken by id so the
    /// order is the same on every call.
    public let snapshots: [Snapshot]
}

// MARK: - RetentionPreview

/// `retention preview` (#80): what this set's configured policy would keep
/// and remove on one destination right now, from `restic forget --dry-run`.
///
/// Produced only by ``BackupEngine/previewRetention(_:destination:)``, which
/// never builds a command carrying `--prune` and never removes anything.
public struct RetentionPreview: Sendable, Equatable {
    /// A kept snapshot and restic's reasons for keeping it
    /// (`"last snapshot"`, `"daily snapshot"`, …).
    public struct Kept: Sendable, Equatable {
        public let snapshot: Snapshot
        public let reasons: [String]
    }

    /// One of restic's policy groups (by host and paths, restic's default
    /// grouping — the same one scheduled retention uses).
    public struct Group: Sendable, Equatable {
        public let host: String?
        public let tags: [String]
        public let paths: [String]
        /// Newest first.
        public let keep: [Kept]
        /// Newest first.
        public let remove: [Snapshot]
    }

    /// For a mirror only: what repo-status records about its last sync and
    /// the primary's. Timestamps are not evidence that two repositories
    /// agree (#111), so this can say a mirror is behind; it can never say a
    /// mirror is safe to prune.
    public struct MirrorSync: Sendable, Equatable {
        public let lastSyncedAt: Date?
        public let primaryLastSyncedAt: Date?

        /// Behind, or not known to be level: either side never recorded a
        /// sync, or the mirror's is older than the primary's.
        public var behindPrimary: Bool {
            guard let lastSyncedAt, let primaryLastSyncedAt else { return true }
            return lastSyncedAt < primaryLastSyncedAt
        }
    }

    public let setId: UUID
    public let destination: Destination
    public let policy: RetentionPolicy
    public let previewedAt: Date
    public let groups: [Group]
    /// `nil` for the primary.
    public let mirrorSync: MirrorSync?
    /// `sha256:<hex>` over the plan's inputs and result — set, destination,
    /// repository, policy and the exact keep and remove ids — and nothing
    /// time-dependent, so two previews of an unchanged repository agree.
    /// The binding the token-gated apply (#82) would check.
    public let fingerprint: String

    public var keepCount: Int { groups.reduce(0) { $0 + $1.keep.count } }
    public var removeCount: Int { groups.reduce(0) { $0 + $1.remove.count } }

    /// The canonical text behind ``fingerprint``. Ids are sorted within each
    /// list so restic's group order cannot change the result; the version
    /// prefix lets the layout change later without colliding.
    static func computeFingerprint(
        setId: UUID,
        destination: Destination,
        policy: RetentionPolicy,
        keepIDs: [String],
        removeIDs: [String]
    ) -> String {
        func value(_ number: Int?) -> String { number.map(String.init) ?? "-" }
        let lines = [
            "restic-station retention-preview v1",
            "set=\(setId.uuidString)",
            "destination=\(destination.id.uuidString)",
            "repository=\(destination.repoURL)",
            "policy=last:\(value(policy.keepLast)),hourly:\(value(policy.keepHourly)),"
                + "daily:\(value(policy.keepDaily)),weekly:\(value(policy.keepWeekly)),"
                + "monthly:\(value(policy.keepMonthly)),yearly:\(value(policy.keepYearly))",
            "keep=\(keepIDs.sorted().joined(separator: ","))",
            "remove=\(removeIDs.sorted().joined(separator: ","))",
        ]
        return "sha256:" + SHA256Digest.hex(Data(lines.joined(separator: "\n").utf8))
    }
}

// MARK: - RepositoryQueryError

/// Why `snapshots list` or `retention preview` produced no answer. Each case
/// maps to one `docs/cli-json.md` code through
/// ``CLIFailure/classifyRepositoryQuery(_:setId:)``.
public enum RepositoryQueryError: Error, Sendable, Equatable {
    /// Another operation holds the set lock (retention preview only).
    case busy
    /// The set lock could not be used at all.
    case lockUnusable(String)
    /// The set has no retention policy, or one with no `keep` rule. A
    /// `forget` with no rule is the one thing retention must never run,
    /// previewed or not.
    case noRetentionPolicy
    /// A permanent secret or hydration refusal: someone has to act.
    case attention(DestinationAttention, destinationId: UUID, message: String)
    /// The secret store answered badly and may answer well later.
    case secretUnavailable(destinationId: UUID, message: String)
    /// The destination did not answer.
    case offline(destinationId: UUID, reason: String)
    /// The reachability probe ran restic and restic failed.
    case probeFailed(destinationId: UUID, ResticExitClass)
    /// restic was never started, or produced no outcome.
    case resticDidNotRun(destinationId: UUID, ResticRunnerError)
    /// restic ran and failed.
    case resticFailed(destinationId: UUID, ResticExitClass)
    /// restic exited 0 but its JSON could not be read (or was cut short).
    case unreadableOutput(destinationId: UUID, reason: String)
    /// The `forget` about to launch carried `--prune` or lacked `--dry-run`.
    /// Unreachable through the engine's own builder; checked anyway.
    case notAPreview
}
