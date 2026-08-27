import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - ScheduleState (state/schedule-state.json)

/// `state/schedule-state.json` — see `docs/data-model.md`
/// §state/schedule-state.json. Keyed by `BackupSet.id`.
public struct ScheduleState: Codable, Equatable, Sendable {
    /// Current on-disk envelope version. Legacy documents without a version
    /// remain readable and are upgraded on their next successful mutation.
    public static let currentVersion = 1

    public var sets: [UUID: SetScheduleState]

    public init(sets: [UUID: SetScheduleState] = [:]) {
        self.sets = sets
    }

    private enum CodingKeys: String, CodingKey {
        case sets
    }

    /// `sets` is a JSON *object* keyed by the set's UUID string (not an
    /// array), which the compiler-synthesized `Codable` for `[UUID: _]`
    /// cannot produce (only `String`/`Int` keys get that treatment) — hence
    /// the dynamic-key container on both sides.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let setsContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        var result: [UUID: SetScheduleState] = [:]
        for key in setsContainer.allKeys {
            // Unlike regenerable state, this dictionary contains destructive
            // purge watermarks. Silently dropping one malformed key would
            // turn corruption into permission to run a rewrite again.
            guard let id = UUID(uuidString: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: setsContainer,
                    debugDescription: "Schedule-state set key is not a UUID: \(key.stringValue)"
                )
            }
            result[id] = try setsContainer.decode(SetScheduleState.self, forKey: key)
        }
        self.sets = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var setsContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        for (id, value) in sets {
            let key = DynamicCodingKey(stringValue: id.uuidString)!
            try setsContainer.encode(value, forKey: key)
        }
    }
}

/// One set's entry in `ScheduleState.sets`.
public struct SetScheduleState: Codable, Equatable, Sendable {
    /// Start time of the last **attempted** scheduled backup (success or
    /// failure); a manual backup also updates this. `nil` before any
    /// attempt.
    public var lastBackupStart: Date?
    /// Start time of the last attempted scheduled check. `nil` before any
    /// attempt.
    public var lastCheckStart: Date?
    /// The `n` most recently used in `--read-data-subset=n/t`. `nil` before
    /// any check has run.
    public var checkSliceCursor: Int?
    /// Number of **successful** checks of this set's primary so far, used
    /// only to decide when the secondaries get their structure-only check
    /// ("every 4th check", `docs/scheduling.md` §Check scheduling). `nil`
    /// before any check has succeeded.
    ///
    /// Added by T09 (`BackupEngine.runCheck`). Optional so a legacy
    /// unversioned `schedule-state.json` written before `checkCount` existed
    /// still decodes and can be upgraded to the checksummed envelope.
    public var checkCount: Int?
    /// Per destination, the purge patterns that have already been rewritten
    /// out of that repository. Removing a pattern deliberately does not
    /// remove it from this audit state: history cannot be restored, and a
    /// smaller list must never cause a wasteful rewrite.
    public var appliedPurgeExcludes: [UUID: [String]]

    public init(
        lastBackupStart: Date? = nil,
        lastCheckStart: Date? = nil,
        checkSliceCursor: Int? = nil,
        checkCount: Int? = nil,
        appliedPurgeExcludes: [UUID: [String]] = [:]
    ) {
        self.lastBackupStart = lastBackupStart
        self.lastCheckStart = lastCheckStart
        self.checkSliceCursor = checkSliceCursor
        self.checkCount = checkCount
        self.appliedPurgeExcludes = appliedPurgeExcludes
    }

    private enum CodingKeys: String, CodingKey {
        case lastBackupStart, lastCheckStart, checkSliceCursor, checkCount, appliedPurgeExcludes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastBackupStart = try container.decodeIfPresent(Date.self, forKey: .lastBackupStart)
        lastCheckStart = try container.decodeIfPresent(Date.self, forKey: .lastCheckStart)
        checkSliceCursor = try container.decodeIfPresent(Int.self, forKey: .checkSliceCursor)
        checkCount = try container.decodeIfPresent(Int.self, forKey: .checkCount)
        guard container.contains(.appliedPurgeExcludes), !(try container.decodeNil(forKey: .appliedPurgeExcludes)) else {
            appliedPurgeExcludes = [:]
            return
        }
        let nested = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .appliedPurgeExcludes)
        var values: [UUID: [String]] = [:]
        for key in nested.allKeys {
            guard let id = UUID(uuidString: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: nested,
                    debugDescription: "Schedule-state destination key is not a UUID: \(key.stringValue)"
                )
            }
            values[id] = try nested.decode([String].self, forKey: key)
        }
        appliedPurgeExcludes = values
    }

    // Explicit `null` for nil optionals — see AppConfig.encode(to:).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastBackupStart, forKey: .lastBackupStart)
        try container.encode(lastCheckStart, forKey: .lastCheckStart)
        try container.encode(checkSliceCursor, forKey: .checkSliceCursor)
        try container.encode(checkCount, forKey: .checkCount)
        var nested = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .appliedPurgeExcludes)
        for (id, patterns) in appliedPurgeExcludes {
            let key = DynamicCodingKey(stringValue: id.uuidString)!
            try nested.encode(patterns, forKey: key)
        }
    }
}

/// Versioned, checksummed representation of ``ScheduleState``. The digest is
/// over the canonical encoding of the logical state (`{"sets": ...}`), so
/// it is independent of envelope field order and identical on macOS/Linux.
private struct ScheduleStateDocument: Codable {
    let version: Int
    let checksum: String
    let sets: [UUID: SetScheduleState]

    init(state: ScheduleState) throws {
        version = ScheduleState.currentVersion
        checksum = try StateStore.scheduleStateChecksum(state)
        sets = state.sets
    }

    var state: ScheduleState { ScheduleState(sets: sets) }

    private enum CodingKeys: String, CodingKey {
        case version, checksum, sets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        checksum = try container.decode(String.self, forKey: .checksum)
        let nested = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        var decoded: [UUID: SetScheduleState] = [:]
        for key in nested.allKeys {
            guard let id = UUID(uuidString: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: nested,
                    debugDescription: "Schedule-state set key is not a UUID: \(key.stringValue)"
                )
            }
            decoded[id] = try nested.decode(SetScheduleState.self, forKey: key)
        }
        sets = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(checksum, forKey: .checksum)
        var nested = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        for (id, entry) in sets {
            try nested.encode(entry, forKey: DynamicCodingKey(stringValue: id.uuidString)!)
        }
    }
}

private struct ScheduleStateVersionProbe: Decodable {
    let version: Int?
    let hasChecksum: Bool

    private enum CodingKeys: String, CodingKey {
        case version, checksum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.version) {
            // An explicit null is not a legacy marker. Requiring an integer
            // prevents a damaged envelope from bypassing checksum validation
            // by changing its version field to null.
            version = try container.decode(Int.self, forKey: .version)
        } else {
            version = nil
        }
        hasChecksum = container.contains(.checksum)
    }
}

// MARK: - CurrentRunState (state/current-run-<setId>.json)

/// `state/current-run-<setId>.json` — live progress of an in-flight run,
/// deleted when the run group finishes. See `docs/data-model.md`
/// §state/current-run-<setId>.json.
public struct CurrentRunState: Codable, Equatable, Sendable {
    public var runId: String
    public var kind: RunKind
    /// `probing` | `backing-up-primary` | `purging-<destId>` |
    /// `copying-<destId>` | `retention` | `checking` — free-form because
    /// `purging-<destId>` and `copying-<destId>` embed a
    /// destination id, so this is not a fixed-case enum.
    public var phase: String
    public var percentDone: Double
    public var bytesDone: Int
    public var totalBytes: Int
    public var filesDone: Int
    public var totalFiles: Int
    public var currentFiles: [String]
    /// Wall-clock time of the helper's most recent liveness heartbeat. This
    /// advances even while restic emits no progress; `updatedAt` remains the
    /// time the visible progress fields last changed.
    public var heartbeatAt: Date?
    /// System uptime, in seconds, at `heartbeatAt`. Unlike wall time this
    /// clock pauses while the machine sleeps, so a laptop does not wake to a
    /// false "stalled" warning. Optional for compatibility with current-run
    /// files written by releases before heartbeats existed.
    public var heartbeatUptime: TimeInterval?
    public var updatedAt: Date

    public init(
        runId: String,
        kind: RunKind,
        phase: String,
        percentDone: Double,
        bytesDone: Int,
        totalBytes: Int,
        filesDone: Int,
        totalFiles: Int,
        currentFiles: [String],
        heartbeatAt: Date? = nil,
        heartbeatUptime: TimeInterval? = nil,
        updatedAt: Date
    ) {
        self.runId = runId
        self.kind = kind
        self.phase = phase
        self.percentDone = percentDone
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.filesDone = filesDone
        self.totalFiles = totalFiles
        self.currentFiles = currentFiles
        self.heartbeatAt = heartbeatAt
        self.heartbeatUptime = heartbeatUptime
        self.updatedAt = updatedAt
    }
}

// MARK: - RepoStatus (state/repo-status-<destId>.json)

/// `state/repo-status-<destId>.json` — reachability + last-synced info for
/// one destination. See `docs/data-model.md` §state/repo-status-<destId>.json.
public struct RepoStatus: Codable, Equatable, Sendable {
    public var destId: UUID
    public var reachable: Bool
    public var probedAt: Date
    /// For a secondary: end time of the last successful `copy`. For the
    /// primary: end of the last successful `backup`. `nil` before the first
    /// success.
    public var lastSyncedAt: Date?
    public var lastError: String?

    public init(
        destId: UUID,
        reachable: Bool,
        probedAt: Date,
        lastSyncedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.destId = destId
        self.reachable = reachable
        self.probedAt = probedAt
        self.lastSyncedAt = lastSyncedAt
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case destId, reachable, probedAt, lastSyncedAt, lastError
    }

    // Explicit `null` for nil optionals — see AppConfig.encode(to:).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(destId, forKey: .destId)
        try container.encode(reachable, forKey: .reachable)
        try container.encode(probedAt, forKey: .probedAt)
        try container.encode(lastSyncedAt, forKey: .lastSyncedAt)
        try container.encode(lastError, forKey: .lastError)
    }
}

// MARK: - FdaCheckResult (state/fda-check.json)

/// `state/fda-check.json` — result of the helper's Full Disk Access probe.
/// See `docs/data-model.md` §state/fda-check.json and
/// `docs/keychain-and-fda.md` §Verification protocol.
public struct FdaCheckResult: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var hasFullDiskAccess: Bool
    public var probedPath: String
    /// `"launchd"` or `"app"` — which process context ran the probe.
    public var context: String

    public init(checkedAt: Date, hasFullDiskAccess: Bool, probedPath: String, context: String) {
        self.checkedAt = checkedAt
        self.hasFullDiskAccess = hasFullDiskAccess
        self.probedPath = probedPath
        self.context = context
    }
}

// MARK: - StateStoreError

/// Which path under `state/` a permission refusal names. Structured rather
/// than spelled into free text because the operator remedy differs per
/// subject, and because `recoveryMessage` must dispatch on it rather than
/// substring-matching a human sentence.
public enum UnsafeStateSubject: Equatable, Sendable {
    case canonicalDocument
    case versionMarker
    case stateDirectory

    public var subject: String {
        switch self {
        case .canonicalDocument: return "the canonical schedule-state document"
        case .versionMarker: return "the schedule state version marker"
        case .stateDirectory: return "the state directory"
        }
    }

    /// The marker is refused for any group/world access; the canonical
    /// document and the directory are refused only for *write* access.
    fileprivate var refusal: String {
        switch self {
        case .versionMarker: return "accessible by other users"
        case .canonicalDocument, .stateDirectory: return "writable by other users"
        }
    }

    /// The mode that repairs the defect in place.
    public var repairMode: String {
        switch self {
        case .canonicalDocument, .versionMarker: return "600"
        case .stateDirectory: return "700"
        }
    }
}

public enum ScheduleStateReadFailureReason: Equatable, Sendable, CustomStringConvertible {
    case malformedDocument
    case checksumMismatch
    case versionDowngrade
    case versionMarkerMissing
    case unsupportedVersion(found: Int, current: Int)
    case unsafeFile(reason: String)
    /// A path under `state/` carries permissions another uid could exploit.
    /// Separate from ``unsafeFile`` because it is the one unsafe-path defect
    /// an operator repairs in place, so it must not inherit the
    /// replace-the-document recovery guidance.
    case unsafeMode(subject: UnsafeStateSubject, path: String, mode: mode_t)
    case ioFailure(operation: String, errno: Int32)
    case tooLarge(bytes: Int64, limit: Int64)

    public var description: String {
        switch self {
        case .malformedDocument:
            return "the document is malformed"
        case .checksumMismatch:
            return "the checksum does not match the schedule payload"
        case .versionDowngrade:
            return "the versioned schedule-state envelope was stripped after migration"
        case .versionMarkerMissing:
            return "the versioned schedule state is missing its durable migration marker"
        case .unsupportedVersion(let found, let current):
            return "the document version is \(found), but this build supports version \(current)"
        case .unsafeFile(let reason):
            return "the canonical path is unsafe: \(reason)"
        case .unsafeMode(let subject, let path, let mode):
            return "\(subject.subject) at \(path) is \(subject.refusal) "
                + "(mode \(String(mode & 0o777, radix: 8)))"
        case .ioFailure(let operation, let code):
            return "\(operation) failed with errno \(code)"
        case .tooLarge(let bytes, let limit):
            return "the document is \(bytes) bytes; the safety limit is \(limit) bytes"
        }
    }
}

/// Evidence retained when an existing schedule document cannot be trusted.
/// The canonical path is deliberately left in place as a fail-closed
/// sentinel; when bytes were readable, an immutable-by-name recovery copy is
/// also published beside it using the raw-byte SHA-256.
public struct ScheduleStateReadFailure: Equatable, Sendable, CustomStringConvertible {
    public let reason: ScheduleStateReadFailureReason
    public let canonicalPath: String
    /// SHA-256 of the exact canonical bytes, when those bytes were readable.
    /// Long-lived observers use it to avoid retrying a failed recovery-copy
    /// publication in response to the temp-file events generated by that
    /// same failed attempt.
    public let contentFingerprint: String?
    public let quarantinePath: String?
    public let quarantineWriteFailed: Bool

    public init(
        reason: ScheduleStateReadFailureReason,
        canonicalPath: String,
        contentFingerprint: String? = nil,
        quarantinePath: String? = nil,
        quarantineWriteFailed: Bool = false
    ) {
        self.reason = reason
        self.canonicalPath = canonicalPath
        self.contentFingerprint = contentFingerprint
        self.quarantinePath = quarantinePath
        self.quarantineWriteFailed = quarantineWriteFailed
    }

    public var description: String {
        var message = "schedule state is unreadable: \(reason); canonical file left unchanged at \(canonicalPath)"
        if let quarantinePath {
            message += "; recovery copy: \(quarantinePath)"
        } else if quarantineWriteFailed {
            message += "; writing a recovery copy also failed"
        }
        return message
    }

    public var recoveryMessage: String {
        // A permission defect is the only unsafe-path failure the operator
        // repairs in place. Both branches below prescribe replacing or
        // recreating a file; for a merely widened mode that would discard a
        // perfectly good purge watermark to fix something `chmod` fixes.
        if case .unsafeMode(let subject, let path, _) = reason {
            return description
                + ". Stop Restic Station and confirm no other user has written to "
                + "\(subject.subject), then repair it in place with "
                + "`chmod \(subject.repairMode) \(path)`. The contents are unchanged "
                + "and must not be replaced or deleted for this failure."
        }

        let markerFailure: Bool
        switch reason {
        case .versionMarkerMissing:
            markerFailure = true
        case .unsafeFile(let detail):
            markerFailure = detail.contains("schedule state version marker")
        case .ioFailure(let operation, _):
            markerFailure = operation.contains("schedule state version marker")
        default:
            markerFailure = false
        }

        if markerFailure {
            return description
                + ". Stop Restic Station and inspect both the canonical document and its version marker. "
                + "After verifying the v1 envelope and checksum, repair the owner-only marker as exactly `1\\n` "
                + "with mode 0600, or replace both files from a trusted recovery copy. Replacing only the canonical "
                + "JSON cannot repair a missing or unsafe marker."
        }

        return description
            + ". Stop Restic Station, inspect the preserved bytes, then explicitly replace the canonical file "
            + "with a valid document. Deleting it accepts loss of schedule, check, and purge-watermark bookkeeping."
    }
}

/// The outcome of reading the schedule state. Unlike the other regenerable
/// state files, this document holds destructive purge bookkeeping, so a
/// corrupt existing file must never be mistaken for an absent one.
public enum ScheduleStateReadResult: Equatable, Sendable {
    case missing
    case valid(ScheduleState)
    case corrupt(ScheduleStateReadFailure)

    public var state: ScheduleState? {
        guard case .valid(let state) = self else { return nil }
        return state
    }
}

public enum StateStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case durableWriteFailed(operation: String, errno: Int32, path: String)
    case renameFailed(errno: Int32, from: String, to: String)
    /// The schedule-state lock could not be used at all — distinct from
    /// ``scheduleStateLockTimeout``, which means a peer genuinely held it
    /// for the whole window (#110).
    case lockUnusable(LockFailure)
    /// `schedule-state.json`'s companion lock could not be acquired within
    /// the bounded retry window.
    case scheduleStateLockTimeout(path: String)
    case scheduleStateCorrupt(ScheduleStateReadFailure)
    case scheduleStateWriteTooLarge(bytes: Int64, limit: Int64, path: String)

    public var description: String {
        switch self {
        case .durableWriteFailed(let operation, let code, let path):
            return "\(operation) failed for \(path): errno \(code)"
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        case .scheduleStateLockTimeout(let path):
            return "timed out waiting for schedule state lock \(path)"
        case .lockUnusable(let failure):
            return "schedule-state lock unusable: \(failure)"
        case .scheduleStateCorrupt(let failure):
            return failure.recoveryMessage
        case .scheduleStateWriteTooLarge(let bytes, let limit, let path):
            return "refusing to publish schedule state at \(path): encoded document is "
                + "\(bytes) bytes; the safety limit is \(limit) bytes"
        }
    }
}

/// Narrow POSIX seam for schedule-state durability fault injection.
struct StateStoreFileOperations: @unchecked Sendable {
    let openAt: @Sendable (Int32, String, Int32, mode_t) -> Int32
    let read: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int
    let write: @Sendable (Int32, UnsafeRawPointer, Int) -> Int
    let sync: @Sendable (Int32) -> Int32
    let stat: @Sendable (Int32, UnsafeMutablePointer<stat>) -> Int32
    let setMode: @Sendable (Int32, mode_t) -> Int32
    let renameAt: @Sendable (Int32, String, Int32, String) -> Int32
    let unlinkAt: @Sendable (Int32, String) -> Int32
    let close: @Sendable (Int32) -> Int32

    static let live = StateStoreFileOperations(
        openAt: { directory, name, flags, mode in
            name.withCString { openat(directory, $0, flags, mode) }
        },
        read: { fd, buffer, count in
            #if canImport(Darwin)
            Darwin.read(fd, buffer, count)
            #elseif canImport(Glibc)
            Glibc.read(fd, buffer, count)
            #elseif canImport(Musl)
            Musl.read(fd, buffer, count)
            #endif
        },
        write: { fd, buffer, count in
            #if canImport(Darwin)
            Darwin.write(fd, buffer, count)
            #elseif canImport(Glibc)
            Glibc.write(fd, buffer, count)
            #elseif canImport(Musl)
            Musl.write(fd, buffer, count)
            #endif
        },
        sync: { fd in
            #if canImport(Darwin)
            Darwin.fsync(fd)
            #elseif canImport(Glibc)
            Glibc.fsync(fd)
            #elseif canImport(Musl)
            Musl.fsync(fd)
            #endif
        },
        stat: { fd, info in
            #if canImport(Darwin)
            Darwin.fstat(fd, info)
            #elseif canImport(Glibc)
            Glibc.fstat(fd, info)
            #elseif canImport(Musl)
            Musl.fstat(fd, info)
            #endif
        },
        setMode: { fd, mode in
            #if canImport(Darwin)
            Darwin.fchmod(fd, mode)
            #elseif canImport(Glibc)
            Glibc.fchmod(fd, mode)
            #elseif canImport(Musl)
            Musl.fchmod(fd, mode)
            #endif
        },
        renameAt: { oldDirectory, oldName, newDirectory, newName in
            oldName.withCString { oldNamePointer in
                newName.withCString { newNamePointer in
                    renameat(oldDirectory, oldNamePointer, newDirectory, newNamePointer)
                }
            }
        },
        unlinkAt: { directory, name in
            name.withCString { unlinkat(directory, $0, 0) }
        },
        close: { fd in
            #if canImport(Darwin)
            Darwin.close(fd)
            #elseif canImport(Glibc)
            Glibc.close(fd)
            #elseif canImport(Musl)
            Musl.close(fd)
            #endif
        }
    )
}

// MARK: - StateStore

/// Typed read/write access to the four `state/` files described in
/// `docs/data-model.md`. Writes are atomic (temp file + `rename(2)`, same
/// convention as `ConfigStore.save(_:)`). Schedule-state publication also
/// fsyncs the complete temp file and containing directory. Most reads
/// tolerate missing or corrupt files as regenerable cache. Schedule state is
/// the exception: it contains purge bookkeeping, so its typed read result
/// distinguishes a missing file from a corrupt existing one and mutations
/// fail closed.
///
/// After every write (including `clearCurrentRun`, which deletes a file),
/// posts the best-effort `DistributedNotificationCenter` nudge described in
/// `docs/architecture.md` §Process model — macOS only; the directory watcher
/// remains the source of truth on every platform.
public struct StateStore: Sendable {
    public let paths: AppPaths
    private let fileOperations: StateStoreFileOperations
    private let maximumScheduleStateBytes: Int64

    private static let defaultMaximumScheduleStateBytes: Int64 = 64 * 1_024 * 1_024

    public init(paths: AppPaths) {
        self.paths = paths
        fileOperations = .live
        maximumScheduleStateBytes = Self.defaultMaximumScheduleStateBytes
    }

    init(
        paths: AppPaths,
        fileOperations: StateStoreFileOperations,
        maximumScheduleStateBytes: Int64 = StateStore.defaultMaximumScheduleStateBytes
    ) {
        self.paths = paths
        self.fileOperations = fileOperations
        self.maximumScheduleStateBytes = maximumScheduleStateBytes
    }

    // MARK: - schedule-state.json

    /// Reads and validates the safety-authoritative schedule document.
    ///
    /// `suppressedRecoveryCopyFingerprint` is for long-lived event watchers:
    /// after recovery-copy publication failed for those exact bytes, the
    /// watcher can classify them again without creating another temp inode
    /// whose directory event would feed the same failure back into itself.
    public func readScheduleStateResult(
        suppressingRecoveryCopyFor suppressedRecoveryCopyFingerprint: String? = nil
    ) -> ScheduleStateReadResult {
        let directory: DirectoryHandle
        switch openStateDirectory() {
        case .opened(let handle):
            directory = handle
        case .missing:
            return .missing
        case .failed(let reason):
            return .corrupt(ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path
            ))
        }

        switch classifyScheduleState(
            suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
            generationIsStable: false,
            in: directory.descriptor
        ) {
        case .result(let result):
            return result
        case .generationMismatch:
            break
        }

        // A marker/document mismatch can be the small publication window of
        // the first legacy -> v1 mutation. The writer owns this same lock, so
        // re-reading beneath it binds both files to one stable generation and
        // prevents a healthy migration from being quarantined as downgrade.
        let lock: FileLock
        do {
            lock = try acquireScheduleStateLock(in: directory)
        } catch StateStoreError.scheduleStateLockTimeout {
            return .corrupt(ScheduleStateReadFailure(
                reason: .ioFailure(operation: "wait for stable schedule-state generation", errno: EBUSY),
                canonicalPath: paths.scheduleStateFile.path
            ))
        } catch StateStoreError.lockUnusable(let failure) {
            return .corrupt(ScheduleStateReadFailure(
                reason: .ioFailure(
                    operation: "lock stable schedule-state generation: \(failure.operation)",
                    errno: failure.errnoValue
                ),
                canonicalPath: paths.scheduleStateFile.path
            ))
        } catch {
            return .corrupt(ScheduleStateReadFailure(
                reason: .ioFailure(operation: "lock stable schedule-state generation", errno: EIO),
                canonicalPath: paths.scheduleStateFile.path
            ))
        }
        defer { lock.release() }

        switch classifyScheduleState(
            suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
            generationIsStable: true,
            in: directory.descriptor
        ) {
        case .result(let result):
            return result
        case .generationMismatch(let reason, let bytes):
            return .corrupt(scheduleStateFailure(
                reason: reason,
                bytes: bytes,
                suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                in: directory.descriptor
            ))
        }
    }

    private enum StateDirectoryOpen {
        case opened(DirectoryHandle)
        case missing
        case failed(ScheduleStateReadFailureReason)
    }

    /// Opens `state/` **once** and retains the descriptor.
    ///
    /// Every schedule-state name — canonical document, migration marker,
    /// recovery copy, durable temp, and the companion lock — is then resolved
    /// through this one descriptor. Between two pathname opens the directory
    /// can be renamed and recreated; between two uses of one descriptor it
    /// cannot, which is what binds a lease's evidence to the tree it writes
    /// into rather than re-checking it "recently" (`AGENTS.md` §Safety 1).
    ///
    /// Opened through `fileOperations` rather than `DirectoryHandle.open`, so
    /// the injectable syscall seam still governs this open; the handle adopts
    /// the verified descriptor and owns closing it.
    private func openStateDirectory() -> StateDirectoryOpen {
        let descriptor = fileOperations.openAt(
            AT_FDCWD,
            paths.stateDir.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard descriptor >= 0 else {
            let code = errno
            return code == ENOENT
                ? .missing
                : .failed(.ioFailure(operation: "open state directory", errno: code))
        }
        var info = stat()
        guard fileOperations.stat(descriptor, &info) == 0 else {
            let code = errno
            _ = fileOperations.close(descriptor)
            return .failed(.ioFailure(operation: "fstat state directory", errno: code))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            _ = fileOperations.close(descriptor)
            return .failed(.unsafeFile(reason: "state directory is not a directory"))
        }
        guard info.st_uid == geteuid() else {
            _ = fileOperations.close(descriptor)
            return .failed(.unsafeFile(
                reason: "state directory owned by uid \(info.st_uid), expected \(geteuid())"
            ))
        }
        // `FileLock.verifyDirectory` refuses a group/world-writable immediate
        // lock parent, and `state/` *is* that parent for
        // `schedule-state.lock`. Reads take that lock and publish quarantine
        // copies beside the canonical document, so a reader that skipped this
        // check would do both inside a directory another uid can rewrite —
        // it could unlink the canonical file between our open and our lock,
        // or swap the quarantine copy we just wrote. Refusing here keeps one
        // policy for the directory however it is reached.
        //
        // Write bits only, matching `verifyDirectory`: a legacy `0755`
        // `state/` exposes nothing another uid can act on, and refusing it
        // would strand installs that predate the `0700` tightening in
        // `AppPaths.ensureDirectories()`.
        guard info.st_mode & 0o022 == 0 else {
            _ = fileOperations.close(descriptor)
            return .failed(.unsafeMode(
                subject: .stateDirectory,
                path: paths.stateDir.path,
                mode: info.st_mode
            ))
        }
        return .opened(DirectoryHandle.adopting(descriptor: descriptor, path: paths.stateDir))
    }

    private enum ScheduleStateClassification {
        case result(ScheduleStateReadResult)
        case generationMismatch(ScheduleStateReadFailureReason, Data)
    }

    private func classifyScheduleState(
        suppressingRecoveryCopyFor suppressedRecoveryCopyFingerprint: String?,
        generationIsStable: Bool,
        in directoryFD: Int32
    ) -> ScheduleStateClassification {
        switch readScheduleStateBytes(in: directoryFD) {
        case .missing:
            // The marker is part of this capability boundary even when the
            // canonical document is absent. A valid marker followed by a
            // crash before first-envelope publication is still logically
            // missing, but an unsafe marker must never be hidden by that
            // same crash window.
            switch readScheduleStateVersionMarker(in: directoryFD) {
            case .missing, .present:
                return .result(.missing)
            case .failed(let reason):
                return .result(.corrupt(scheduleStateFailure(reason: reason, bytes: nil, in: directoryFD)))
            }
        case .failed(let reason):
            return .result(.corrupt(scheduleStateFailure(reason: reason, bytes: nil, in: directoryFD)))
        case .bytes(let data):
            do {
                let decoder = Self.makeDecoder()
                let probe = try decoder.decode(ScheduleStateVersionProbe.self, from: data)
                guard let version = probe.version else {
                    guard !probe.hasChecksum else {
                        return .result(.corrupt(scheduleStateFailure(
                            reason: .malformedDocument,
                            bytes: data,
                            suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                        )))
                    }
                    switch readScheduleStateVersionMarker(in: directoryFD) {
                    case .missing:
                        break
                    case .present:
                        if !generationIsStable {
                            return .generationMismatch(.versionDowngrade, data)
                        }
                        return .result(.corrupt(scheduleStateFailure(
                            reason: .versionDowngrade,
                            bytes: data,
                            suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                        )))
                    case .failed(let reason):
                        return .result(.corrupt(scheduleStateFailure(
                            reason: reason,
                            bytes: data,
                            suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                        )))
                    }
                    // Legacy v0: no checksum existed. Preserve compatibility,
                    // then upgrade under the mutation lock on the next write.
                    return .result(.valid(try decoder.decode(ScheduleState.self, from: data)))
                }
                // The marker is an independent part of the recovery
                // capability. Classify it before version compatibility so a
                // newer canonical document cannot hide a second repair the
                // operator must perform.
                switch readScheduleStateVersionMarker(in: directoryFD) {
                case .present:
                    break
                case .missing:
                    if !generationIsStable {
                        return .generationMismatch(.versionMarkerMissing, data)
                    }
                    return .result(.corrupt(scheduleStateFailure(
                        reason: .versionMarkerMissing,
                        bytes: data,
                        suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                    )))
                case .failed(let reason):
                    return .result(.corrupt(scheduleStateFailure(
                        reason: reason,
                        bytes: data,
                        suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                    )))
                }
                guard version == ScheduleState.currentVersion else {
                    return .result(.corrupt(scheduleStateFailure(
                        reason: .unsupportedVersion(found: version, current: ScheduleState.currentVersion),
                        bytes: data,
                        suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                    )))
                }
                let document = try decoder.decode(ScheduleStateDocument.self, from: data)
                let checksum = try Self.scheduleStateChecksum(document.state)
                guard document.checksum.count == 64,
                      document.checksum.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                      document.checksum == checksum else {
                    return .result(.corrupt(scheduleStateFailure(
                        reason: .checksumMismatch,
                        bytes: data,
                        suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                    )))
                }
                return .result(.valid(document.state))
            } catch {
                return .result(.corrupt(scheduleStateFailure(
                    reason: .malformedDocument,
                    bytes: data,
                    suppressingRecoveryCopyFor: suppressedRecoveryCopyFingerprint,
                            in: directoryFD
                )))
            }
        }
    }

    private enum ScheduleStateBytesRead {
        case missing
        case bytes(Data)
        case failed(ScheduleStateReadFailureReason)
    }

    /// Opens the owner-controlled state directory and canonical file without
    /// following a symlink. A schedule document is authority for destructive
    /// bookkeeping, so unlike regenerable caches it must be a regular file
    /// owned by the effective uid.
    /// Reads through the caller's retained `state/` descriptor, so the
    /// document, the migration marker, the lock and every later durable write
    /// resolve in one directory generation.
    private func readScheduleStateBytes(in directoryFD: Int32) -> ScheduleStateBytesRead {
        let filename = paths.scheduleStateFile.lastPathComponent
        let fd = fileOperations.openAt(
            directoryFD,
            filename,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fd >= 0 else {
            let code = errno
            return code == ENOENT
                ? .missing
                : .failed(.ioFailure(operation: "open schedule state", errno: code))
        }
        defer { _ = fileOperations.close(fd) }

        var info = stat()
        guard fileOperations.stat(fd, &info) == 0 else {
            return .failed(.ioFailure(operation: "fstat schedule state", errno: errno))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failed(.unsafeFile(reason: "not a regular file"))
        }
        guard info.st_uid == geteuid() else {
            return .failed(.unsafeFile(reason: "owned by uid \(info.st_uid), expected \(geteuid())"))
        }
        // The envelope checksum is unkeyed, so it authenticates nothing an
        // editor could not recompute. A canonical file another user can write
        // is therefore forged purge bookkeeping — a fabricated
        // `appliedPurgeExcludes` suppresses a required rewrite, which is the
        // dangerous direction of the watermark asymmetry
        // (`docs/scheduling.md` §Purge safety invariants). A transiently
        // widened mode (a recursive chmod that also exposed `state/`) must
        // not be consumed even after the directory is re-tightened.
        //
        // Only the *write* bits are refused, not `0o077`: a pre-v1 release
        // could publish `0644` under a permissive umask, and refusing to read
        // an install's own state would be a worse failure than the exposure
        // that mode represents.
        guard info.st_mode & 0o022 == 0 else {
            return .failed(.unsafeMode(
                subject: .canonicalDocument,
                path: paths.scheduleStateFile.path,
                mode: info.st_mode
            ))
        }
        let fileSize = Int64(info.st_size)
        guard fileSize >= 0,
              fileSize <= maximumScheduleStateBytes else {
            return .failed(.tooLarge(bytes: fileSize, limit: maximumScheduleStateBytes))
        }

        var data = Data()
        data.reserveCapacity(Int(fileSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return fileOperations.read(fd, base, raw.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return .failed(.ioFailure(operation: "read schedule state", errno: code))
            }
            if count == 0 { break }
            guard Int64(data.count + count) <= maximumScheduleStateBytes else {
                return .failed(.tooLarge(
                    bytes: Int64(data.count + count),
                    limit: maximumScheduleStateBytes
                ))
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return .bytes(data)
    }

    private enum ScheduleStateVersionMarkerRead {
        case missing
        case present
        case failed(ScheduleStateReadFailureReason)
    }

    private static let scheduleStateVersionMarkerBytes = Data("1\n".utf8)

    /// Reads the monotonic migration marker without ever blocking on a
    /// hostile FIFO. The filename is version-specific, while the tiny body
    /// catches truncated or substituted regular files.
    private func readScheduleStateVersionMarker(in directoryFD: Int32) -> ScheduleStateVersionMarkerRead {
        let fd = fileOperations.openAt(
            directoryFD,
            paths.scheduleStateVersionMarkerFile.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fd >= 0 else {
            let code = errno
            return code == ENOENT
                ? .missing
                : .failed(.ioFailure(operation: "open schedule state version marker", errno: code))
        }
        defer { _ = fileOperations.close(fd) }

        var info = stat()
        guard fileOperations.stat(fd, &info) == 0 else {
            return .failed(.ioFailure(operation: "fstat schedule state version marker", errno: errno))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failed(.unsafeFile(reason: "schedule state version marker is not a regular file"))
        }
        guard info.st_uid == geteuid() else {
            return .failed(.unsafeFile(
                reason: "schedule state version marker is owned by uid \(info.st_uid), expected \(geteuid())"
            ))
        }
        guard info.st_mode & 0o077 == 0 else {
            return .failed(.unsafeMode(
                subject: .versionMarker,
                path: paths.scheduleStateVersionMarkerFile.path,
                mode: info.st_mode
            ))
        }
        guard Int64(info.st_size) == Int64(Self.scheduleStateVersionMarkerBytes.count) else {
            return .failed(.unsafeFile(reason: "schedule state version marker has invalid contents"))
        }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: Self.scheduleStateVersionMarkerBytes.count + 1)
        while bytes.count <= Self.scheduleStateVersionMarkerBytes.count {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return fileOperations.read(fd, base, raw.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return .failed(.ioFailure(operation: "read schedule state version marker", errno: code))
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes == Self.scheduleStateVersionMarkerBytes
            ? .present
            : .failed(.unsafeFile(reason: "schedule state version marker has invalid contents"))
    }

    private func scheduleStateFailure(
        reason: ScheduleStateReadFailureReason,
        bytes: Data?,
        suppressingRecoveryCopyFor suppressedRecoveryCopyFingerprint: String? = nil,
        in directoryFD: Int32
    ) -> ScheduleStateReadFailure {
        guard let bytes else {
            return ScheduleStateReadFailure(reason: reason, canonicalPath: paths.scheduleStateFile.path)
        }
        let fingerprint = SHA256Digest.hex(bytes)
        let quarantine = paths.stateDir.appendingPathComponent(
            "schedule-state.corrupt-\(fingerprint).json",
            isDirectory: false
        )
        // A rename may have succeeded even when its following directory
        // fsync reported indeterminate durability. A later read can safely
        // recognize the exact owner-owned bytes without writing again.
        if existingOwnedRegularFile(at: quarantine, equals: bytes, in: directoryFD) {
            return ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path,
                contentFingerprint: fingerprint,
                quarantinePath: quarantine.path
            )
        }
        if fingerprint == suppressedRecoveryCopyFingerprint {
            return ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path,
                contentFingerprint: fingerprint,
                quarantineWriteFailed: true
            )
        }
        do {
            try preserveScheduleStateQuarantine(bytes, at: quarantine, in: directoryFD)
            return ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path,
                contentFingerprint: fingerprint,
                quarantinePath: quarantine.path
            )
        } catch {
            return ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path,
                contentFingerprint: fingerprint,
                quarantineWriteFailed: true
            )
        }
    }

    /// Compatibility view for callers that only need valid schedule data.
    /// Mutating and health-sensitive callers must use
    /// ``readScheduleStateResult()`` so they cannot treat corruption as absent.
    public func readScheduleState() -> ScheduleState? {
        readScheduleStateResult().state
    }

    /// How long to retry for the schedule-state lock before giving up. Most
    /// critical sections are a decode, one dictionary mutation and an atomic
    /// write. A purge deliberately keeps the same evidence-bound lease
    /// through rewrite completion and its watermark commit; another helper
    /// times out safely instead of running from state that purge may change.
    private static let stateLockTimeout: Duration = .seconds(5)
    private static let stateLockPollInterval: UInt32 = 20_000  // 20ms

    /// Loads the current `ScheduleState` (or an empty one), applies
    /// `mutate` to `setId`'s entry (creating it if absent), and writes the
    /// result back atomically.
    ///
    /// Held under ``AppPaths/scheduleStateLockFile`` for the whole
    /// read-modify-write (or, for purge, through destructive use and durable
    /// acknowledgement). The write itself was always atomic, but atomicity
    /// is not isolation: `schedule-state.json` is one document shared by
    /// every set, while the only other lock is per-set. A scheduled tick for
    /// set A and a manual operation on set B run in different processes,
    /// take no common lock, and each rewrite the whole file — so B could read
    /// before A's write and write after it, silently discarding A's entry.
    /// That entry now carries `appliedPurgeExcludes`, i.e. destructive
    /// bookkeeping, so a lost update is no longer merely scheduling hygiene.
    ///
    /// **This method blocks** while waiting for the lock. That is fine for the
    /// helper, which is a one-shot process whose contention is with *other
    /// processes*, but callers must not fan it out across Swift Concurrency
    /// tasks: blocking the cooperative pool prevents the lock holder from
    /// being scheduled to release, so waiters spin to the timeout. A test that
    /// did exactly that turned a 0.3s case into a 50s one on a two-core runner
    /// and stalled the whole suite behind it.
    /// Opens `state/`, creating it first if a mutation needs it.
    private func openStateDirectoryForWriting() throws -> DirectoryHandle {
        try paths.ensureDirectories()
        switch openStateDirectory() {
        case .opened(let handle):
            return handle
        case .missing:
            throw StateStoreError.durableWriteFailed(
                operation: "open state directory",
                errno: ENOENT,
                path: paths.stateDir.path
            )
        case .failed(let reason):
            throw StateStoreError.scheduleStateCorrupt(ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path
            ))
        }
    }

    /// Takes the companion lock **inside** the caller's already-open `state/`
    /// directory, so the locked inode and every file the holder subsequently
    /// reads or publishes are resolved through one descriptor. A `state/`
    /// renamed and recreated mid-lease therefore cannot receive this lease's
    /// writes while its lock still protects the retired tree.
    private func acquireScheduleStateLock(in directory: DirectoryHandle) throws -> FileLock {
        let lock = FileLock(
            name: paths.scheduleStateLockFile.lastPathComponent,
            in: directory
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.stateLockTimeout)
        // Only contention is worth waiting out. Polling a lock that failed
        // to *open* just burns the whole timeout and then reports a timeout,
        // which names contention as the cause of a permissions or filesystem
        // fault and sends the reader looking for a process that does not
        // exist (#110).
        while true {
            switch lock.acquire() {
            case .acquired:
                break
            case .busy:
                if clock.now > deadline {
                    throw StateStoreError.scheduleStateLockTimeout(path: paths.scheduleStateLockFile.path)
                }
                usleep(Self.stateLockPollInterval)
                continue
            case .failed(let failure):
                throw StateStoreError.lockUnusable(failure)
            }
            break
        }
        return lock
    }

    func lockScheduleState() throws -> LockedScheduleState {
        let directory = try openStateDirectoryForWriting()
        let lock = try acquireScheduleStateLock(in: directory)
        var state: ScheduleState
        let readResult: ScheduleStateReadResult
        switch classifyScheduleState(
            suppressingRecoveryCopyFor: nil,
            generationIsStable: true,
            in: directory.descriptor
        ) {
        case .result(let result):
            readResult = result
        case .generationMismatch(let reason, let bytes):
            readResult = .corrupt(scheduleStateFailure(
                reason: reason,
                bytes: bytes,
                in: directory.descriptor
            ))
        }
        switch readResult {
        case .missing:
            state = ScheduleState()
        case .valid(let loaded):
            state = loaded
        case .corrupt(let failure):
            lock.release()
            throw StateStoreError.scheduleStateCorrupt(failure)
        }
        return LockedScheduleState(store: self, lock: lock, directory: directory, state: state)
    }

    @discardableResult
    public func updateScheduleState(
        setId: UUID,
        mutate: (inout SetScheduleState) -> Void
    ) throws -> ScheduleState {
        let locked = try lockScheduleState()
        defer { locked.release() }
        return try locked.update(setId: setId, mutate: mutate)
    }

    // MARK: - current-run-<setId>.json

    public func readCurrentRun(setId: UUID) -> CurrentRunState? {
        read(CurrentRunState.self, from: paths.currentRunFile(setId: setId))
    }

    public func writeCurrentRun(setId: UUID, _ state: CurrentRunState) throws {
        try write(state, to: paths.currentRunFile(setId: setId))
    }

    /// Deletes the live-progress file for `setId` (a no-op, still posting
    /// the nudge, if it is already absent) — called when a run group
    /// finishes.
    public func clearCurrentRun(setId: UUID) throws {
        let url = paths.currentRunFile(setId: setId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        postStateChangedNotification()
    }

    // MARK: - repo-status-<destId>.json

    public func readRepoStatus(destId: UUID) -> RepoStatus? {
        read(RepoStatus.self, from: paths.repoStatusFile(destId: destId))
    }

    /// Loads the current `RepoStatus` for `destId` (or a fresh
    /// `reachable: false` record), applies `mutate`, and writes the result
    /// back atomically.
    @discardableResult
    public func updateRepoStatus(
        destId: UUID,
        mutate: (inout RepoStatus) -> Void
    ) throws -> RepoStatus {
        var status = readRepoStatus(destId: destId)
            ?? RepoStatus(destId: destId, reachable: false, probedAt: Date(timeIntervalSince1970: 0))
        mutate(&status)
        try write(status, to: paths.repoStatusFile(destId: destId))
        return status
    }

    // MARK: - fda-check.json

    public func readFdaCheck() -> FdaCheckResult? {
        read(FdaCheckResult.self, from: paths.fdaCheckFile)
    }

    public func writeFdaCheck(_ result: FdaCheckResult) throws {
        try write(result, to: paths.fdaCheckFile)
    }

    // MARK: - state/ enumeration

    /// Every `BackupSet.id` with a live `state/current-run-<setId>.json` —
    /// discovered by filename pattern (the same convention the app's
    /// `StateWatcher` uses to populate its `currentRuns` dictionary), not by
    /// cross-referencing `config.json`. That is what makes this correct for
    /// `HealthDerivation.appHealth(anyRunInFlight:...)`'s documented
    /// contract: a run that started before its set was deleted is still
    /// "in flight". A missing or momentarily-unreadable `state/` directory
    /// yields an empty list rather than throwing — state is a regenerable
    /// cache (`docs/data-model.md` §Versioning).
    public func currentRunSetIDs() -> [UUID] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.stateDir,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return entries.compactMap { entry in
            Self.extractUUID(from: entry.lastPathComponent, prefix: "current-run-", suffix: ".json")
        }
    }

    private static func extractUUID(from filename: String, prefix: String, suffix: String) -> UUID? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        guard filename.count >= prefix.count + suffix.count else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return UUID(uuidString: String(filename[start..<end]))
    }

    // MARK: - Generic read/write

    fileprivate static func scheduleStateChecksum(_ state: ScheduleState) throws -> String {
        SHA256Digest.hex(try makeEncoder().encode(state))
    }

    fileprivate func writeScheduleState(_ state: ScheduleState, in directoryFD: Int32) throws {
        let document = try ScheduleStateDocument(state: state)
        let data = try Self.makeEncoder().encode(document)
        guard Int64(data.count) <= maximumScheduleStateBytes else {
            // Validate the complete prospective envelope before publishing
            // the monotonic migration marker. Otherwise a legacy document
            // that fits the read limit could be stranded behind a v1 marker
            // when its envelope does not fit.
            throw StateStoreError.scheduleStateWriteTooLarge(
                bytes: Int64(data.count),
                limit: maximumScheduleStateBytes,
                path: paths.scheduleStateFile.path
            )
        }
        try ensureScheduleStateVersionMarker(in: directoryFD)
        try writeDurably(
            data,
            to: paths.scheduleStateFile,
            tempName: paths.scheduleStateFile.lastPathComponent + ".tmp",
            in: directoryFD,
            postNotification: true
        )
    }

    /// The marker commits before the first v1 envelope. A crash between the
    /// two publications can stop scheduling, but can never make an already
    /// migrated state look like unchecked legacy input.
    private func ensureScheduleStateVersionMarker(in directoryFD: Int32) throws {
        switch readScheduleStateVersionMarker(in: directoryFD) {
        case .present:
            return
        case .missing:
            try writeDurably(
                Self.scheduleStateVersionMarkerBytes,
                to: paths.scheduleStateVersionMarkerFile,
                tempName: paths.scheduleStateVersionMarkerFile.lastPathComponent + ".tmp",
                in: directoryFD,
                postNotification: false
            )
        case .failed(let reason):
            throw StateStoreError.scheduleStateCorrupt(ScheduleStateReadFailure(
                reason: reason,
                canonicalPath: paths.scheduleStateFile.path
            ))
        }
    }

    /// Retains the exact untrusted bytes under a content-addressed filename.
    /// The canonical file remains untouched and therefore continues to block
    /// mutations until an operator explicitly replaces it with valid state.
    private func preserveScheduleStateQuarantine(
        _ data: Data,
        at url: URL,
        in directoryFD: Int32
    ) throws {
        // Repeated health/status reads of the same bad canonical bytes must
        // not turn into repeated durable writes. The name binds the SHA-256,
        // and equality verifies that an existing name still holds those
        // exact bytes before it is reused.
        if existingOwnedRegularFile(at: url, equals: data, in: directoryFD) {
            return
        }
        try writeDurably(
            data,
            to: url,
            tempName: url.lastPathComponent + ".tmp-\(UUID().uuidString)",
            in: directoryFD,
            postNotification: false
        )
    }

    /// Descriptor-based equality check for an existing recovery copy. The
    /// state watcher performs a second read after the first copy's directory
    /// event; avoiding another rename stops that event from feeding itself.
    /// `O_NOFOLLOW` and descriptor metadata checks keep that optimization
    /// from trusting a symlink or foreign/non-regular inode.
    private func existingOwnedRegularFile(
        at url: URL,
        equals expected: Data,
        in directoryFD: Int32
    ) -> Bool {
        let fd = fileOperations.openAt(
            directoryFD,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW,
            0
        )
        guard fd >= 0 else { return false }
        defer { _ = fileOperations.close(fd) }

        var info = stat()
        guard fileOperations.stat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              Int64(info.st_size) == Int64(expected.count) else {
            return false
        }

        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < expected.count {
            let requested = min(buffer.count, expected.count - offset)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return fileOperations.read(fd, base, requested)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard count > 0,
                  expected[offset..<(offset + count)].elementsEqual(buffer.prefix(count)) else {
                return false
            }
            offset += count
        }

        // Reject a file that grew after fstat even when its prefix matched.
        let trailing = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return fileOperations.read(fd, base, 1)
        }
        return trailing == 0
    }

    /// Complete write + file fsync + descriptor-relative rename + directory
    /// fsync. Returning success means both bytes and directory entry crossed
    /// the durability boundary; an fsync failure is never reported as a
    /// successful schedule mutation.
    /// Publishes `data` through the caller's retained `state/` descriptor.
    ///
    /// It deliberately does **not** re-resolve the directory by pathname or
    /// call `ensureDirectories()`. Both would let a `state/` renamed and
    /// recreated mid-lease receive this write while the lease's lock still
    /// protects the retired tree — a second helper could then take the
    /// replacement lock and run a concurrent `rewrite --forget`.
    private func writeDurably(
        _ data: Data,
        to url: URL,
        tempName: String,
        in directoryFD: Int32,
        postNotification shouldPostNotification: Bool
    ) throws {
        let directory = url.deletingLastPathComponent()
        if fileOperations.unlinkAt(directoryFD, tempName) != 0 {
            let code = errno
            if code != ENOENT {
                throw StateStoreError.durableWriteFailed(
                    operation: "unlink stale state temp",
                    errno: code,
                    path: directory.appendingPathComponent(tempName).path
                )
            }
        }
        let tempPath = directory.appendingPathComponent(tempName).path
        let tempFD = fileOperations.openAt(
            directoryFD,
            tempName,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard tempFD >= 0 else {
            throw StateStoreError.durableWriteFailed(
                operation: "open state temp",
                errno: errno,
                path: tempPath
            )
        }

        do {
            try secureOwnerOnlyTemp(fd: tempFD, path: tempPath)
            try writeAll(data, to: tempFD, path: tempPath)
            try sync(tempFD, operation: "fsync state temp", path: tempPath)
        } catch {
            _ = fileOperations.close(tempFD)
            _ = fileOperations.unlinkAt(directoryFD, tempName)
            throw error
        }
        if fileOperations.close(tempFD) != 0 {
            let code = errno
            _ = fileOperations.unlinkAt(directoryFD, tempName)
            throw StateStoreError.durableWriteFailed(
                operation: "close state temp",
                errno: code,
                path: tempPath
            )
        }

        let targetName = url.lastPathComponent
        guard fileOperations.renameAt(directoryFD, tempName, directoryFD, targetName) == 0 else {
            let code = errno
            _ = fileOperations.unlinkAt(directoryFD, tempName)
            throw StateStoreError.renameFailed(errno: code, from: tempPath, to: url.path)
        }
        try sync(directoryFD, operation: "fsync state directory", path: directory.path)
        if shouldPostNotification {
            postStateChangedNotification()
        }
    }

    /// Creation mode is still filtered by the caller's umask. Pin and verify
    /// the authority-bearing temp inode through its already-trusted
    /// descriptor before any bytes are written or the inode is published.
    private func secureOwnerOnlyTemp(fd: Int32, path: String) throws {
        guard fileOperations.setMode(fd, 0o600) == 0 else {
            throw StateStoreError.durableWriteFailed(
                operation: "fchmod state temp",
                errno: errno,
                path: path
            )
        }
        var info = stat()
        guard fileOperations.stat(fd, &info) == 0 else {
            throw StateStoreError.durableWriteFailed(
                operation: "fstat state temp after fchmod",
                errno: errno,
                path: path
            )
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_mode & 0o7777 == 0o600 else {
            throw StateStoreError.durableWriteFailed(
                operation: "verify owner-only state temp",
                errno: EPERM,
                path: path
            )
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let count = fileOperations.write(fd, base.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw StateStoreError.durableWriteFailed(operation: "write", errno: code, path: path)
                }
                guard count > 0 else {
                    throw StateStoreError.durableWriteFailed(operation: "write", errno: EIO, path: path)
                }
                offset += count
            }
        }
    }

    private func sync(_ fd: Int32, operation: String, path: String) throws {
        while fileOperations.sync(fd) != 0 {
            let code = errno
            if code == EINTR { continue }
            throw StateStoreError.durableWriteFailed(operation: operation, errno: code, path: path)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(T.self, from: data)
    }

    /// Encodes `value`, writes it to a temp file in the same directory as
    /// `url`, then `rename(2)`s it over `url` — atomic even if a previous
    /// write crashed and left a stale temp file behind (same convention as
    /// `ConfigStore.save(_:)`). Posts the state-changed nudge on success.
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try paths.ensureDirectories()

        let data = try Self.makeEncoder().encode(value)
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp", isDirectory: false)
        try data.write(to: temp)

        let fromPath = temp.path
        let toPath = url.path
        let renameResult = fromPath.withCString { fromC in
            toPath.withCString { toC in
                rename(fromC, toC)
            }
        }
        if renameResult != 0 {
            let renameErrno = errno
            try? FileManager.default.removeItem(at: temp)
            throw StateStoreError.renameFailed(errno: renameErrno, from: fromPath, to: toPath)
        }
        postStateChangedNotification()
    }

    private func postStateChangedNotification() {
        #if os(macOS)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("net.herila.ResticStation.stateChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        #endif
    }

    // MARK: - Encoding

    /// Same `.sortedKeys` + `.prettyPrinted` + ISO 8601-with-fractional-
    /// seconds convention as `ConfigStore` (`docs/data-model.md`'s
    /// atomic-write preamble applies uniformly to every persisted file).
    static func makeEncoder() -> JSONEncoder {
        ConfigStore.makeEncoder()
    }

    /// Like `ConfigStore.makeDecoder()`, but also accepts ISO 8601 strings
    /// *without* fractional seconds — the literal examples in
    /// `docs/data-model.md` (e.g. `"2026-07-26T20:57:04Z"`) are written by
    /// hand and omit them, while everything this store itself writes
    /// includes them (`ConfigStore`'s formatter). Round-tripping both must
    /// work.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ConfigStore.makeISO8601Formatter().date(from: string) {
                return date
            }
            let lenient = ISO8601DateFormatter()
            lenient.formatOptions = [.withInternetDateTime]
            if let date = lenient.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO 8601 date: \(string)"
            )
        }
        return decoder
    }
}

/// Exclusive, process-wide authority over the schedule-state document.
/// Destructive purge keeps this lease from its trusted read through restic
/// completion and the watermark commit, so another helper cannot invalidate
/// the evidence between validation, use, and acknowledgement.
final class LockedScheduleState {
    private let store: StateStore
    private let lock: FileLock
    /// The `state/` generation this lease is bound to. The lock lives in this
    /// directory and every write goes back through the same descriptor, so a
    /// lease can never publish into a tree its lock does not protect.
    private let directory: DirectoryHandle
    private var isHeld = true
    private(set) var state: ScheduleState

    fileprivate init(
        store: StateStore,
        lock: FileLock,
        directory: DirectoryHandle,
        state: ScheduleState
    ) {
        self.store = store
        self.lock = lock
        self.directory = directory
        self.state = state
    }

    func update(
        setId: UUID,
        mutate: (inout SetScheduleState) -> Void
    ) throws -> ScheduleState {
        precondition(isHeld, "schedule-state lease used after release")
        var entry = state.sets[setId] ?? SetScheduleState()
        mutate(&entry)
        state.sets[setId] = entry
        try store.writeScheduleState(state, in: directory.descriptor)
        return state
    }

    func release() {
        guard isHeld else { return }
        isHeld = false
        lock.release()
    }

    deinit {
        release()
    }
}

// MARK: - DynamicCodingKey

/// A `CodingKey` that accepts any string — used to encode/decode
/// `ScheduleState.sets`, whose keys are UUID strings rather than a known,
/// fixed set of names.
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
