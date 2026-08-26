import Foundation

/// The operation a run performs. Raw values are exactly the strings used in
/// `runId` (see `RunStore.makeRunId`) and in persisted JSON — see
/// `docs/architecture.md` §AppPaths (`runId` format) and
/// `docs/data-model.md` §runs/index.jsonl.
public enum RunKind: String, Codable, Equatable, Sendable, CaseIterable {
    case backup
    case copy
    case check
    case prune
    /// A token-gated `restic rewrite --forget` purge. Unlike `prune`, this
    /// changes snapshot history but does not reclaim pack space.
    case purge
    case restore
    /// Repository initialization. `init` is a reserved word, hence the
    /// backticks — the raw value (and every persisted representation) is
    /// still the plain string `"init"`.
    case `init`

    /// Repository operations whose effects cannot be safely repeated when
    /// their audit outcome is unknown. `prune` covers both retention
    /// `forget --prune` and standalone pack reclamation; `purge` is
    /// `rewrite --forget`.
    public var isDestructive: Bool {
        self == .prune || self == .purge
    }
}

/// Why a destructive run is not represented by a complete canonical
/// metadata record plus its derived index entry.
public enum RunAuditFailureReason: String, Codable, Equatable, Sendable {
    /// The derived index claims a destructive run completed, but the
    /// canonical per-run directory/metadata record is gone entirely.
    case canonicalMetadataMissing = "canonical_metadata_missing"
    /// The pre-spawn launch marker exists, the owning helper is gone, and no
    /// terminal metadata was committed. The repository outcome is unknown.
    case launchedWithoutTerminalMetadata = "launched_without_terminal_metadata"
    /// Terminal metadata is canonical and present, but its derived index
    /// projection is absent or its durable publication is still pending.
    case terminalMetadataMissingIndex = "terminal_metadata_missing_index"
    /// The index contains one or more projections for the run, but not
    /// exactly one byte-semantic projection of the canonical metadata.
    case terminalMetadataIndexMismatch = "terminal_metadata_index_mismatch"
    /// The process crossed the launch boundary but returned no trustworthy
    /// repository outcome (for example cancellation or timeout).
    case repositoryOutcomeUnknown = "repository_outcome_unknown"
}

/// An unresolved destructive-operation audit failure. This is deliberately
/// reconstructible from `runs/*/metadata.json` plus `runs/index.jsonl`; it is
/// not a second mutable source of truth.
public struct RunAuditFailure: Codable, Equatable, Sendable {
    public let runId: String
    public let kind: RunKind
    public let setId: UUID
    public let destId: UUID
    public let start: Date
    public let reason: RunAuditFailureReason

    public init(
        runId: String,
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        start: Date,
        reason: RunAuditFailureReason
    ) {
        self.runId = runId
        self.kind = kind
        self.setId = setId
        self.destId = destId
        self.start = start
        self.reason = reason
    }
}

/// Outcome of a run. See `docs/architecture.md` §RunStatus.
///
/// A crash mid-run leaves a `running` metadata record with no `end` time;
/// `RunStore.recoverInterrupted()` finds these and rewrites them `.failed`
/// once the recorded `pid` is confirmed dead.
public enum RunStatus: String, Codable, Equatable, Sendable {
    case success
    case warning
    case failed
    case skipped
    case running
}

/// What caused a run to start. See `docs/architecture.md` error taxonomy.
public enum RunTrigger: String, Codable, Equatable, Sendable {
    case scheduled
    case manual
}

/// One compact line in `runs/index.jsonl` — see `docs/data-model.md`
/// §runs/index.jsonl. Encoded without pretty-printing, one JSON object per
/// line, `sortedKeys`, ISO 8601 dates with fractional seconds (per the
/// data-model.md atomic-write preamble); optional fields are encoded as
/// explicit `null` rather than omitted, matching the documented example
/// (`"errorSummary":null`).
///
/// A scheduled set run produces multiple index lines (one `backup`, one
/// `copy` per attempted secondary, one `prune` per repo where retention
/// ran) that share a `groupId` — the primary backup's `runId` — so the UI
/// can nest them.
public struct RunIndexEntry: Codable, Equatable, Sendable {
    public var runId: String
    public var kind: RunKind
    public var setId: UUID
    public var destId: UUID
    /// The primary backup's `runId` for a scheduled set run; for a
    /// standalone run this equals `runId` itself.
    public var groupId: String
    public var status: RunStatus
    public var start: Date
    public var end: Date?
    public var trigger: RunTrigger
    public var snapshotId: String?
    public var filesNew: Int?
    public var filesChanged: Int?
    public var dataAdded: Int?
    public var errorSummary: String?

    public init(
        runId: String,
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        groupId: String,
        status: RunStatus,
        start: Date,
        end: Date?,
        trigger: RunTrigger,
        snapshotId: String?,
        filesNew: Int?,
        filesChanged: Int?,
        dataAdded: Int?,
        errorSummary: String?
    ) {
        self.runId = runId
        self.kind = kind
        self.setId = setId
        self.destId = destId
        self.groupId = groupId
        self.status = status
        self.start = start
        self.end = end
        self.trigger = trigger
        self.snapshotId = snapshotId
        self.filesNew = filesNew
        self.filesChanged = filesChanged
        self.dataAdded = dataAdded
        self.errorSummary = errorSummary
    }

    private enum CodingKeys: String, CodingKey {
        case runId, kind, setId, destId, groupId, status, start, end, trigger
        case snapshotId, filesNew, filesChanged, dataAdded, errorSummary
    }

    // Explicit `null` for nil optionals rather than omitting the key — see
    // AppConfig.encode(to:) for the same convention and rationale.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(kind, forKey: .kind)
        try container.encode(setId, forKey: .setId)
        try container.encode(destId, forKey: .destId)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(status, forKey: .status)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(snapshotId, forKey: .snapshotId)
        try container.encode(filesNew, forKey: .filesNew)
        try container.encode(filesChanged, forKey: .filesChanged)
        try container.encode(dataAdded, forKey: .dataAdded)
        try container.encode(errorSummary, forKey: .errorSummary)
    }
}

/// `runs/<runId>/metadata.json` — see `docs/data-model.md`
/// §runs/<runId>/metadata.json. A superset of `RunIndexEntry` plus `pid`,
/// `resticExitCode`, `argvRedacted` (argv with env not included), and
/// `stats` (the full decoded summary message where applicable).
///
/// Written once at run start (`status: .running`, `end: nil`) and
/// atomically rewritten on completion by `RunStore.finish(_:status:...)`.
public struct RunMetadata: Codable, Equatable, Sendable {
    public var runId: String
    public var kind: RunKind
    public var setId: UUID
    public var destId: UUID
    public var groupId: String
    public var status: RunStatus
    public var trigger: RunTrigger
    public var start: Date
    public var end: Date?
    public var pid: Int32
    public var resticExitCode: Int32?
    /// argv actually executed, with environment variables not included
    /// (never contains secrets — those only ever travel via env).
    public var argvRedacted: [String]
    public var snapshotId: String?
    public var filesNew: Int?
    public var filesChanged: Int?
    public var dataAdded: Int?
    public var errorSummary: String?
    /// Full decoded summary message where applicable (e.g. a `backup` or
    /// `copy` run). `nil` for kinds with no such summary (e.g. `prune`).
    public var stats: BackupSummary?
    /// Old full snapshot id → new snapshot id reported by `restic rewrite
    /// --forget`. Present only for successful/partially successful purge
    /// runs; historical run records deliberately remain untouched.
    public var purgeSnapshotRewrites: [String: String]?
    /// Exact exclusion patterns bound to a purge launch. A terminal success
    /// is durable evidence that these patterns completed for this run's
    /// destination, even if the later schedule watermark commit was lost.
    public var purgePatterns: [String]?
    /// Restic repository config id read during apply-time revalidation and
    /// bound to the purge launch. Watermark recovery may trust terminal
    /// purge evidence only when this id still matches the live repository.
    public var purgeRepositoryId: String?
    /// Version of the destructive audit contract understood when this run
    /// was created. A current-version destructive run with no launch marker
    /// is known to be safely pre-launch; a markerless pre-contract running
    /// record has no such evidence and must fail closed.
    public var destructiveAuditContractVersion: Int?
    /// Written immediately before a destructive argv is handed to the
    /// process runner, after secret/executable/token preflights. A terminal
    /// record preserves it. If the helper dies with this marker on a
    /// `.running` record, the operation may have changed repository data and
    /// must never be retried automatically.
    public var destructiveLaunchAuthorizedAt: Date?
    /// Persistent audit condition for a destructive launch whose repository
    /// outcome could not be captured. Unlike a missing derived index entry,
    /// reconciliation must not clear this without explicit human inspection.
    public var auditFailureReason: RunAuditFailureReason?
    /// Two-phase publication marker. Terminal metadata sets this before its
    /// derived index append and clears it only after that append is durable.
    /// Recovery may finish this mechanical transaction automatically.
    public var indexPublicationPending: Bool?
    /// Version of the crash-durability contract used to publish this
    /// canonical metadata record. Missing on legacy records whose visible
    /// rename may not have been synced to stable storage.
    public var publicationDurabilityContractVersion: Int?

    public init(
        runId: String,
        kind: RunKind,
        setId: UUID,
        destId: UUID,
        groupId: String,
        status: RunStatus,
        trigger: RunTrigger,
        start: Date,
        end: Date?,
        pid: Int32,
        resticExitCode: Int32?,
        argvRedacted: [String],
        snapshotId: String?,
        filesNew: Int?,
        filesChanged: Int?,
        dataAdded: Int?,
        errorSummary: String?,
        stats: BackupSummary?,
        purgeSnapshotRewrites: [String: String]? = nil,
        purgePatterns: [String]? = nil,
        purgeRepositoryId: String? = nil,
        destructiveAuditContractVersion: Int? = nil,
        destructiveLaunchAuthorizedAt: Date? = nil,
        auditFailureReason: RunAuditFailureReason? = nil,
        indexPublicationPending: Bool? = nil,
        publicationDurabilityContractVersion: Int? = nil
    ) {
        self.runId = runId
        self.kind = kind
        self.setId = setId
        self.destId = destId
        self.groupId = groupId
        self.status = status
        self.trigger = trigger
        self.start = start
        self.end = end
        self.pid = pid
        self.resticExitCode = resticExitCode
        self.argvRedacted = argvRedacted
        self.snapshotId = snapshotId
        self.filesNew = filesNew
        self.filesChanged = filesChanged
        self.dataAdded = dataAdded
        self.errorSummary = errorSummary
        self.stats = stats
        self.purgeSnapshotRewrites = purgeSnapshotRewrites
        self.purgePatterns = purgePatterns
        self.purgeRepositoryId = purgeRepositoryId
        self.destructiveAuditContractVersion = destructiveAuditContractVersion
        self.destructiveLaunchAuthorizedAt = destructiveLaunchAuthorizedAt
        self.auditFailureReason = auditFailureReason
        self.indexPublicationPending = indexPublicationPending
        self.publicationDurabilityContractVersion = publicationDurabilityContractVersion
    }

    private enum CodingKeys: String, CodingKey {
        case runId, kind, setId, destId, groupId, status, trigger, start, end
        case pid, resticExitCode, argvRedacted
        case snapshotId, filesNew, filesChanged, dataAdded, errorSummary, stats, purgeSnapshotRewrites
        case purgePatterns, purgeRepositoryId
        case destructiveAuditContractVersion, destructiveLaunchAuthorizedAt
        case auditFailureReason, indexPublicationPending, publicationDurabilityContractVersion
    }

    // Explicit `null` for nil optionals — see AppConfig.encode(to:).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(kind, forKey: .kind)
        try container.encode(setId, forKey: .setId)
        try container.encode(destId, forKey: .destId)
        try container.encode(groupId, forKey: .groupId)
        try container.encode(status, forKey: .status)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(pid, forKey: .pid)
        try container.encode(resticExitCode, forKey: .resticExitCode)
        try container.encode(argvRedacted, forKey: .argvRedacted)
        try container.encode(snapshotId, forKey: .snapshotId)
        try container.encode(filesNew, forKey: .filesNew)
        try container.encode(filesChanged, forKey: .filesChanged)
        try container.encode(dataAdded, forKey: .dataAdded)
        try container.encode(errorSummary, forKey: .errorSummary)
        try container.encode(stats, forKey: .stats)
        try container.encode(purgeSnapshotRewrites, forKey: .purgeSnapshotRewrites)
        try container.encode(purgePatterns, forKey: .purgePatterns)
        try container.encode(purgeRepositoryId, forKey: .purgeRepositoryId)
        try container.encode(destructiveAuditContractVersion, forKey: .destructiveAuditContractVersion)
        try container.encode(destructiveLaunchAuthorizedAt, forKey: .destructiveLaunchAuthorizedAt)
        try container.encode(auditFailureReason, forKey: .auditFailureReason)
        try container.encode(indexPublicationPending, forKey: .indexPublicationPending)
        try container.encode(
            publicationDurabilityContractVersion,
            forKey: .publicationDurabilityContractVersion
        )
    }

    /// The compact index-line projection of this metadata, appended to
    /// `runs/index.jsonl` by `RunStore.finish(_:...)` /
    /// `RunStore.recoverInterrupted()`.
    public var indexEntry: RunIndexEntry {
        RunIndexEntry(
            runId: runId,
            kind: kind,
            setId: setId,
            destId: destId,
            groupId: groupId,
            status: status,
            start: start,
            end: end,
            trigger: trigger,
            snapshotId: snapshotId,
            filesNew: filesNew,
            filesChanged: filesChanged,
            dataAdded: dataAdded,
            errorSummary: errorSummary
        )
    }
}
