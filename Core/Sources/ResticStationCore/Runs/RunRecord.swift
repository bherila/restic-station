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
    case restore
    /// Repository initialization. `init` is a reserved word, hence the
    /// backticks — the raw value (and every persisted representation) is
    /// still the plain string `"init"`.
    case `init`
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
        stats: BackupSummary?
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
    }

    private enum CodingKeys: String, CodingKey {
        case runId, kind, setId, destId, groupId, status, trigger, start, end
        case pid, resticExitCode, argvRedacted
        case snapshotId, filesNew, filesChanged, dataAdded, errorSummary, stats
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
