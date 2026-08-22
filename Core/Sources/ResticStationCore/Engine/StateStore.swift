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
        guard container.contains(.sets) else {
            self.sets = [:]
            return
        }
        let setsContainer = try container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        var result: [UUID: SetScheduleState] = [:]
        for key in setsContainer.allKeys {
            // Unknown/malformed keys are skipped, not fatal — state files
            // are regenerable caches (docs/data-model.md §Versioning).
            guard let id = UUID(uuidString: key.stringValue) else { continue }
            result[id] = try setsContainer.decode(SetScheduleState.self, forKey: key)
        }
        self.sets = result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var setsContainer = container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .sets)
        for (id, value) in sets {
            guard let key = DynamicCodingKey(stringValue: id.uuidString) else { continue }
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
    /// Added by T09 (`BackupEngine.runCheck`) — the rotation rule needs a
    /// counter and `docs/data-model.md` §schedule-state.json documents no
    /// field for it. Optional, so a `schedule-state.json` written by an
    /// earlier build (which has no `checkCount` key) still decodes: state
    /// files carry no version and are regenerable caches
    /// (`docs/data-model.md` §Versioning & migration).
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
            guard let id = UUID(uuidString: key.stringValue) else { continue }
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
            guard let key = DynamicCodingKey(stringValue: id.uuidString) else { continue }
            try nested.encode(patterns, forKey: key)
        }
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

public enum StateStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case renameFailed(errno: Int32, from: String, to: String)
    /// The schedule-state lock could not be used at all — distinct from
    /// ``scheduleStateLockTimeout``, which means a peer genuinely held it
    /// for the whole window (#110).
    case lockUnusable(LockFailure)
    /// `schedule-state.json`'s companion lock could not be acquired within
    /// the bounded retry window.
    case scheduleStateLockTimeout(path: String)

    public var description: String {
        switch self {
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        case .scheduleStateLockTimeout(let path):
            return "timed out waiting for schedule state lock \(path)"
        case .lockUnusable(let failure):
            return "schedule-state lock unusable: \(failure)"
        }
    }
}

// MARK: - StateStore

/// Typed read/write access to the four `state/` files described in
/// `docs/data-model.md`. Writes are atomic (temp file + `rename(2)`, same
/// convention as `ConfigStore.save(_:)`); reads return `nil` on a missing or
/// corrupt file rather than throwing — state is a regenerable cache, never a
/// source of truth callers must trust blindly (`docs/data-model.md`
/// §Versioning & migration).
///
/// After every write (including `clearCurrentRun`, which deletes a file),
/// posts the best-effort `DistributedNotificationCenter` nudge described in
/// `docs/architecture.md` §Process model — macOS only; the directory watcher
/// remains the source of truth on every platform.
public struct StateStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    // MARK: - schedule-state.json

    public func readScheduleState() -> ScheduleState? {
        read(ScheduleState.self, from: paths.scheduleStateFile)
    }

    /// How long to retry for the schedule-state lock before giving up. The
    /// critical section is a decode, one dictionary mutation and an atomic
    /// write, so real contention is measured in milliseconds.
    private static let stateLockTimeout: TimeInterval = 5
    private static let stateLockPollInterval: UInt32 = 20_000  // 20ms

    /// Loads the current `ScheduleState` (or an empty one), applies
    /// `mutate` to `setId`'s entry (creating it if absent), and writes the
    /// result back atomically.
    ///
    /// Held under ``AppPaths/scheduleStateLockFile`` for the whole
    /// read-modify-write. The write itself was always atomic, but atomicity
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
    @discardableResult
    public func updateScheduleState(
        setId: UUID,
        mutate: (inout SetScheduleState) -> Void
    ) throws -> ScheduleState {
        try paths.ensureDirectories()
        let lock = FileLock(path: paths.scheduleStateLockFile)
        let deadline = Date().addingTimeInterval(Self.stateLockTimeout)
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
                if Date() > deadline {
                    throw StateStoreError.scheduleStateLockTimeout(path: paths.scheduleStateLockFile.path)
                }
                usleep(Self.stateLockPollInterval)
                continue
            case .failed(let failure):
                throw StateStoreError.lockUnusable(failure)
            }
            break
        }
        defer { lock.release() }

        var state = readScheduleState() ?? ScheduleState()
        var entry = state.sets[setId] ?? SetScheduleState()
        mutate(&entry)
        state.sets[setId] = entry
        try write(state, to: paths.scheduleStateFile)
        return state
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
