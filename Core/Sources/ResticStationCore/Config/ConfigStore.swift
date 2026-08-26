import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Loads and atomically persists `config.json` at the location described by
/// an `AppPaths`. No caching — callers hold the decoded `AppConfig` value
/// and pass it back in to `save(_:)`.
public struct ConfigStore: Sendable {
    public let paths: AppPaths

    /// Collaborator for the migration step that leaves
    /// `config.json`: relocating `resticPath` into `machine.json`. Held
    /// rather than constructed per call so the store stays a value with a
    /// single `paths` source of truth.
    ///
    /// Deliberately the **persistent-identity** store: migration does a
    /// load-mutate-save round trip on `machine.json`, and going through the
    /// override-aware store would write back whatever
    /// `RESTIC_STATION_MACHINE_ID` happened to say, permanently rebinding
    /// the host to a temporary profile. Migration only cares about
    /// `resticPath`; the id it round-trips must be the one already on disk.
    private let machineStore: MachineStore

    public init(paths: AppPaths) {
        self.paths = paths
        self.machineStore = MachineStore.persistentIdentity(paths: paths)
    }

    /// The temp file `save(_:)` writes before `rename(2)`-ing it over
    /// `configFile`. Fixed (not randomized) so a crash between the write
    /// and the rename leaves a deterministic, recognizable leftover that
    /// the next `save(_:)` simply overwrites.
    var tempConfigFile: URL {
        paths.configFile.deletingLastPathComponent()
            .appendingPathComponent(paths.configFile.lastPathComponent + ".tmp", isDirectory: false)
    }

    /// One read of `config.json`: the bytes, their fingerprint, and the
    /// configuration decoded **from those same bytes**.
    ///
    /// `load()` followed by `fileFingerprint()` is two reads, so the decoded
    /// value and the hashed value are not guaranteed to be the same snapshot
    /// — a file replaced between them yields a configuration that does not
    /// correspond to the fingerprint a destructive confirmation is checked
    /// against. This closes that window.
    ///
    /// A migration rewrites the file, so when one happens the snapshot is
    /// retaken over the post-migration bytes. Migration is one-way and
    /// terminates, so the retry cannot loop.
    public func snapshot() throws -> ConfigSnapshot {
        try withConfigReadLock { migrationAllowed in
            try snapshotLocked(migrationAllowed: migrationAllowed)
        }
    }

    private func snapshotLocked(migrationAllowed: Bool) throws -> ConfigSnapshot {
        guard let bytes = try readConfigBytes() else {
            return ConfigSnapshot(bytes: Data(), fingerprint: "absent", config: AppConfig())
        }
        let decoded = try Self.makeDecoder().decode(AppConfig.self, from: bytes)
        if decoded.version > AppConfig.currentVersion {
            throw ConfigError.newerVersion(found: decoded.version, supported: AppConfig.currentVersion)
        }
        try decoded.validate()
        guard decoded.version == AppConfig.currentVersion else {
            guard migrationAllowed else {
                return ConfigSnapshot(
                    bytes: bytes,
                    fingerprint: SHA256Digest.hex(bytes),
                    config: decoded
                )
            }
            _ = try loadLocked(migrationAllowed: true)   // migrates and rewrites under this lock
            return try snapshotAfterMigration()
        }
        return ConfigSnapshot(bytes: bytes, fingerprint: SHA256Digest.hex(bytes), config: decoded)
    }

    private func snapshotAfterMigration() throws -> ConfigSnapshot {
        guard let bytes = try readConfigBytes() else {
            return ConfigSnapshot(bytes: Data(), fingerprint: "absent", config: AppConfig())
        }
        let decoded = try Self.makeDecoder().decode(AppConfig.self, from: bytes)
        try decoded.validate()
        return ConfigSnapshot(bytes: bytes, fingerprint: SHA256Digest.hex(bytes), config: decoded)
    }

    /// Fingerprint of `machine.json`'s bytes. It is not part of
    /// `config.json`, but it decides machine identity, which overrides apply,
    /// which destinations are enabled here, and the restic path — so a
    /// destructive confirmation that binds only the shared config can still
    /// be honoured against a materially different effective set.
    public func machineFileFingerprint() -> String {
        guard let data = try? Data(contentsOf: paths.machineFile) else { return "absent" }
        return SHA256Digest.hex(data)
    }

    /// A fingerprint of `config.json` **as bytes on disk**, for binding a
    /// destructive confirmation to the configuration the operator reviewed.
    ///
    /// Deliberately hashes the file rather than a decoded `AppConfig`: the
    /// app and the helper are separate processes that resolve and migrate
    /// config differently, so hashing decoded objects would make them
    /// disagree and refuse legitimate operations. The bytes are the one
    /// thing both sides see identically.
    ///
    /// A missing file is a valid, empty configuration (see ``load()``), so
    /// it fingerprints as a fixed sentinel rather than failing.
    public func fileFingerprint() -> String {
        (try? currentFileFingerprint()) ?? "unreadable"
    }

    /// The exact on-disk revision used by compare-and-swap saves. Unlike the
    /// convenience ``fileFingerprint()``, an unreadable existing file throws
    /// rather than being collapsed into the same sentinel as absence.
    public func currentFileFingerprint() throws -> String {
        guard let data = try readConfigBytes() else { return "absent" }
        return SHA256Digest.hex(data)
    }

    /// Missing file → default empty config. Version newer than this build
    /// supports → `ConfigError.newerVersion`. Otherwise decodes, validates
    /// (`AppConfig.validate()` is called on every load) and, for an older
    /// schema version, migrates — see ``migrateToCurrentVersion(_:original:)``.
    ///
    /// The returned config still carries every `machines` override key: it
    /// is the *shared*, machine-agnostic view. Call
    /// `AppConfig.resolved(for:)` to get the effective one for this host.
    public func load() throws -> AppConfig {
        try withConfigReadLock { migrationAllowed in
            try loadLocked(migrationAllowed: migrationAllowed)
        }
    }

    /// The read/validate/migrate body. A usable `config.lock` lets the caller
    /// pass `migrationAllowed: true`; otherwise this remains a read-only load
    /// of the original schema. Keeping migrations and ordinary readers on the
    /// same lock as writers means a rejected Darwin exchange can never expose
    /// its candidate to a helper between swap and rollback.
    private func loadLocked(migrationAllowed: Bool) throws -> AppConfig {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            return AppConfig()
        }

        let data = try Data(contentsOf: paths.configFile)
        let config = try Self.makeDecoder().decode(AppConfig.self, from: data)

        if config.version > AppConfig.currentVersion {
            throw ConfigError.newerVersion(found: config.version, supported: AppConfig.currentVersion)
        }

        // Validate the file as it was written, before migrating: a config
        // that is not valid at its own version is a hard error, and must not
        // cause a backup file or a rewritten config.json to be produced.
        try config.validate()

        guard config.version < AppConfig.currentVersion else {
            return config
        }
        guard migrationAllowed else { return config }
        let migration = migrateToCurrentVersion(config, originalBytes: data)
        // Mirrors the original single-function behavior exactly: config.json
        // is never overwritten unless the v1 backup is confirmed on disk —
        // see the ordering note on `migrateToCurrentVersion`.
        guard migration.backupWritten else {
            return migration.config
        }
        do {
            try migration.config.validate()
            try persist(Self.makeEncoder().encode(migration.config))
        } catch {
            Self.warn("could not write the migrated config.json: \(error)")
        }
        return migration.config
    }

    // MARK: - Migration

    /// Any older version → current (`docs/data-model.md` §Versioning &
    /// migration).
    ///
    /// Neither step so far needs a data change, because both new keys have a
    /// meaning when absent:
    ///
    /// - **v1 → v2.** An absent `machines` key already means "this
    ///   set/destination runs everywhere", so a v1 config *is* a valid v2
    ///   config once the version number is bumped. The only value that moves
    ///   is `resticPath`, which is inherently host-local and belongs in
    ///   `machine.json`.
    /// - **v2 → v3.** An absent `purgeExcludes` decodes as `[]` (see
    ///   `BackupSet.init(from:)`), which is "no patterns are purged" — the
    ///   behaviour every pre-v3 config already had. A pure version bump.
    ///
    /// The pre-migration bytes are copied to `config.v<from>.backup.json`,
    /// keyed by the version being migrated *from*, so each step of the chain
    /// leaves its own recoverable copy.
    ///
    /// Performs the migration's persistence side effects — in this order:
    /// 1. Adopt `resticPath` into `machine.json` (only if it has none), and
    ///    clear it from the returned config **only once that write
    ///    succeeded**.
    /// 2. Copy `originalBytes` to the source-versioned
    ///    `config.v<from>.backup.json` — never
    ///    overwriting an existing backup, so a second migration cannot
    ///    clobber the first one's copy.
    ///
    /// Every step is best-effort: a data directory that cannot be written
    /// must not stop the helper from *running* backups, and the in-memory
    /// result is correct either way (the migration is a pure function of the
    /// file, so an unwritten migration simply reruns next load).
    ///
    /// **Deliberately stops short of installing the result as this store's
    /// `config.json`.** `load()` does that itself, immediately, and only
    /// when `backupWritten` is `true` — mirroring exactly what the
    /// pre-refactor single function did (see below). `config import` (T27)
    /// is the other caller: it needs to back up any config already
    /// installed *before* overwriting it, and `--dry-run` must not install
    /// at all — both of which require the install step to stay under the
    /// caller's control. That is also why this is `public`: it is the
    /// sanctioned way to reuse this migration outside `ConfigStore` itself,
    /// per `docs/data-model.md` §Versioning — "do not reimplement it".
    ///
    /// - Returns: the migrated value, and whether the source-versioned
    ///   migration backup is confirmed on disk (already existing, or just
    ///   written). **Every
    ///   caller must skip installing `config` as `config.json` when this is
    ///   `false`** — that is the property "the source file is never overwritten
    ///   unless a backup of it exists" (`docs/data-model.md` §Versioning)
    ///   actually rests on. `false` leaves `machine.json` however far the
    ///   `resticPath` adoption above got (best-effort, already durable if it
    ///   happened); only the final config.json install is gated.
    public func migrateToCurrentVersion(
        _ loaded: AppConfig,
        originalBytes: Data
    ) -> (config: AppConfig, backupWritten: Bool) {
        var migrated = loaded
        migrated.version = AppConfig.currentVersion

        if let configResticPath = loaded.resticPath, !configResticPath.isEmpty {
            do {
                var machine = try machineStore.load()
                if machine.resticPath?.isEmpty ?? true {
                    machine.resticPath = configResticPath
                    // `savePreservingIdentity`, not `save`: relocating a
                    // restic path is not an identity change, so it goes
                    // through the one write path that cannot alter the
                    // host's `machineId` — the same rule the app's
                    // `updateMachine(_:)` follows. `machineStore` is already
                    // the persistent-identity store, so this is belt and
                    // braces; the point is that no reader has to check which
                    // store it is to know the write is safe.
                    try machineStore.savePreservingIdentity(machine)
                }
                // Recorded host-locally (either just now, or by an earlier
                // run / the user) — the deprecated top-level field can go.
                migrated.resticPath = nil
            } catch {
                // Leave `resticPath` where it is: as a v2 field it is still
                // read as the fallback when `machine.json` has none, so the
                // config keeps working exactly as it did.
                Self.warn("could not move resticPath into machine.json: \(error)")
            }
        }

        do {
            try writeBackupIfAbsent(originalBytes, fromVersion: loaded.version)
        } catch {
            Self.warn("could not write \(paths.configBackupFile(fromVersion: loaded.version).lastPathComponent): "
                + "\(error). Leaving config.json at version \(loaded.version).")
            return (migrated, false)
        }

        return (migrated, true)
    }

    /// A pure, side-effect-free **preview** of what
    /// ``migrateToCurrentVersion(_:originalBytes:)`` would produce: only the
    /// version number is bumped. No `machine.json` read or write, no
    /// source-versioned migration-backup write — nothing touches disk.
    ///
    /// For `config import --dry-run` (T27), which must not write anything at
    /// all. The real migration additionally relocates a deprecated
    /// `resticPath` into `machine.json` and clears it from the config; that
    /// step is intentionally not simulated here; a dry run is a preview; the
    /// exact `resticPath` handling is only guaranteed by actually installing.
    public static func previewMigration(_ loaded: AppConfig) -> AppConfig {
        var migrated = loaded
        migrated.version = AppConfig.currentVersion
        return migrated
    }

    /// Copies the pre-migration bytes verbatim. `O_EXCL` is what makes
    /// "never overwrite an existing backup" a property of the filesystem
    /// rather than of a check-then-write race: a second migration finds the
    /// file there and leaves it alone.
    private func writeBackupIfAbsent(_ original: Data, fromVersion version: Int) throws {
        let backupFile = paths.configBackupFile(fromVersion: version)
        guard !FileManager.default.fileExists(atPath: backupFile.path) else {
            return
        }
        try paths.ensureDirectories()
        do {
            try original.write(to: backupFile, options: .withoutOverwriting)
        } catch let error as NSError where error.code == NSFileWriteFileExistsError {
            return // lost a race with another process; its copy is just as good
        }
    }

    private static func warn(_ message: String) {
        StandardStream.write(Data("restic-station: config migration: \(message)\n".utf8), to: .standardError)
    }

    /// Validates, encodes (`.sortedKeys` + `.prettyPrinted` + ISO 8601 with
    /// fractional seconds), writes to a temp file in the same directory,
    /// then `rename(2)`s it over `configFile` — atomic even if a previous
    /// write crashed and left a stale temp file behind.
    public func save(_ config: AppConfig) throws {
        try config.validate()
        try paths.ensureDirectories()

        let data = try Self.makeEncoder().encode(config)
        try withConfigWriteLock {
            try persist(data)
        }
    }

    /// Saves only when `config.json` is still the exact byte revision the
    /// caller began editing. Every Restic Station writer is serialized by
    /// `locks/config.lock`. On Darwin, where the app runs, the candidate is
    /// atomically exchanged with `config.json` and the displaced bytes are
    /// checked, so even a non-cooperating fleet replacement cannot land in
    /// the old check-to-rename window. Other platforms rely on the shared
    /// lock used by the helper's supported config writers.
    ///
    /// - Returns: the fingerprint of the bytes installed by this save.
    @discardableResult
    public func save(_ config: AppConfig, ifUnchangedFrom expectedFingerprint: String) throws -> String {
        try config.validate()
        try paths.ensureDirectories()

        let data = try Self.makeEncoder().encode(config)
        return try withConfigWriteLock {
            try data.write(to: tempConfigFile)
            let installed = try AtomicFile.replaceIfMatches(
                from: tempConfigFile,
                to: paths.configFile,
                expectedFingerprint: expectedFingerprint,
                candidateFingerprint: SHA256Digest.hex(data)
            )
            guard installed else {
                try? FileManager.default.removeItem(at: tempConfigFile)
                throw ConfigStoreError.changedOnDisk
            }
            return SHA256Digest.hex(data)
        }
    }

    /// Refuses an edit before it performs a related side effect outside
    /// `config.json` (the destination editor's keychain write). The config
    /// save still performs the authoritative atomic compare-and-swap.
    public func assertUnchanged(from expectedFingerprint: String) throws {
        try withConfigWriteLock {
            guard try currentFileFingerprint() == expectedFingerprint else {
                throw ConfigStoreError.changedOnDisk
            }
        }
    }

    /// Runs a related asynchronous mutation while the exact edit-start
    /// revision remains protected by `config.lock`. A second fingerprint
    /// check catches a raw, non-cooperating filesystem replacement during
    /// the operation; the caller can then restore the related mutation.
    public func withUnchangedRevision<T>(
        from expectedFingerprint: String,
        operation: () async throws -> T
    ) async throws -> T {
        try paths.ensureDirectories()
        let lock = FileLock(path: paths.configLockFile, trustedRoot: paths.root)
        switch lock.acquire() {
        case .acquired:
            break
        case .busy:
            throw ConfigStoreError.writeLockBusy(path: paths.configLockFile.path)
        case .failed(let failure):
            throw ConfigStoreError.writeLockUnusable(failure)
        }
        defer { lock.release() }

        guard try currentFileFingerprint() == expectedFingerprint else {
            throw ConfigStoreError.changedOnDisk
        }
        let result = try await operation()
        guard try currentFileFingerprint() == expectedFingerprint else {
            throw ConfigStoreError.changedOnDisk
        }
        return result
    }

    private func persist(_ data: Data) throws {
        try data.write(to: tempConfigFile)
        try AtomicFile.rename(from: tempConfigFile, to: paths.configFile)
    }

    private func readConfigBytes() throws -> Data? {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else {
            return nil
        }
        return try Data(contentsOf: paths.configFile)
    }

    private func withConfigWriteLock<T>(_ body: () throws -> T) throws -> T {
        let lock = FileLock(path: paths.configLockFile, trustedRoot: paths.root)
        switch lock.acquire() {
        case .acquired:
            defer { lock.release() }
            return try body()
        case .busy:
            throw ConfigStoreError.writeLockBusy(path: paths.configLockFile.path)
        case .failed(let failure):
            throw ConfigStoreError.writeLockUnusable(failure)
        }
    }

    /// Readers wait out ordinary writer contention, so a keychain-backed
    /// destination edit cannot turn a valid config into a transient helper
    /// outage and none can observe Darwin's exchange/rollback window. A
    /// structurally unusable lock falls back to a strictly non-migrating
    /// read: backups remain readable, but no schema side effect can run
    /// without the administrative lock.
    private func withConfigReadLock<T>(_ body: (Bool) throws -> T) throws -> T {
        // A pre-lock release legitimately has no locks/ directory yet. Give
        // the normal upgrade path a chance to establish it before deciding
        // that migration is unavailable. A real setup failure still falls
        // back to a strictly read-only load below.
        do {
            try paths.ensureDirectories()
        } catch {
            return try body(false)
        }
        let lock = FileLock(path: paths.configLockFile, trustedRoot: paths.root)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while true {
            switch lock.acquire() {
            case .acquired:
                defer { lock.release() }
                return try body(true)
            case .busy:
                guard clock.now < deadline else {
                    throw ConfigStoreError.writeLockBusy(path: paths.configLockFile.path)
                }
                usleep(20_000)
            case .failed:
                return try body(false)
            }
        }
    }

    // MARK: - Encoding

    /// The house JSON convention for every persisted file (`docs/data-model.md`
    /// preamble): `.sortedKeys` + `.prettyPrinted`, ISO 8601 dates with
    /// fractional seconds. `public` so callers outside this module — the
    /// helper's `--json` subcommands (T27) chief among them — encode their
    /// own output with the exact same conventions instead of reimplementing
    /// them, keeping every JSON surface in the app byte-for-byte consistent.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeISO8601Formatter().string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = makeISO8601Formatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }

    /// ISO 8601 with fractional seconds, per `docs/data-model.md`. `config.json`
    /// itself has no `Date` fields today, but this keeps the store consistent
    /// with the rest of the persisted-JSON policy for when it does. A fresh
    /// formatter is created per call — `ISO8601DateFormatter` is a mutable,
    /// non-`Sendable` class, and encode/decode can run concurrently.
    public static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

// MARK: - AtomicFile

/// The `rename(2)` half of the "write a temp file in the same directory,
/// then rename over the target" convention every writer in this package
/// follows. Shared by `ConfigStore` and `MachineStore` so the two files get
/// byte-identical atomicity guarantees.
enum AtomicFile {
    /// Renames `from` over `to`, removing the temp file on failure so a
    /// half-written leftover cannot be mistaken for a valid file.
    static func rename(from source: URL, to destination: URL) throws {
        let fromPath = source.path
        let toPath = destination.path
        let renameResult = fromPath.withCString { fromC in
            toPath.withCString { toC in
                #if canImport(Darwin)
                Darwin.rename(fromC, toC)
                #elseif canImport(Glibc)
                Glibc.rename(fromC, toC)
                #elseif canImport(Musl)
                Musl.rename(fromC, toC)
                #endif
            }
        }
        if renameResult != 0 {
            let renameErrno = errno
            try? FileManager.default.removeItem(at: source)
            throw ConfigStoreError.renameFailed(errno: renameErrno, from: fromPath, to: toPath)
        }
    }

    /// Atomically installs `source` only when `destination` is the revision
    /// the caller edited. Darwin's `RENAME_SWAP` supplies the missing atomic
    /// boundary: the bytes displaced by the swap are the exact bytes that
    /// were present when the candidate became visible. A mismatch is rolled
    /// back with exclusive renames so a later raw replacement always wins.
    static func replaceIfMatches(
        from source: URL,
        to destination: URL,
        expectedFingerprint: String,
        candidateFingerprint: String
    ) throws -> Bool {
        #if canImport(Darwin)
        if expectedFingerprint == "absent" {
            let result = renameX(from: source, to: destination, flags: UInt32(RENAME_EXCL))
            if result == 0 { return true }
            let failure = errno
            if failure == EEXIST { return false }
            throw ConfigStoreError.renameFailed(
                errno: failure, from: source.path, to: destination.path
            )
        }

        let swap = renameX(from: source, to: destination, flags: UInt32(RENAME_SWAP))
        if swap != 0 {
            let failure = errno
            if failure == ENOENT { return false }
            throw ConfigStoreError.renameFailed(
                errno: failure, from: source.path, to: destination.path
            )
        }

        let displacedFingerprint: String
        do {
            displacedFingerprint = SHA256Digest.hex(try Data(contentsOf: source))
        } catch {
            _ = try rollbackCandidateIfCurrent(
                displaced: source,
                destination: destination,
                candidateFingerprint: candidateFingerprint
            )
            throw error
        }

        guard displacedFingerprint != expectedFingerprint else {
            try? FileManager.default.removeItem(at: source)
            return true
        }

        _ = try rollbackCandidateIfCurrent(
            displaced: source,
            destination: destination,
            candidateFingerprint: candidateFingerprint
        )
        return false
        #else
        // The Linux helper's supported writers all use `config.lock`.
        // Linux has renameat2(RENAME_EXCHANGE), but Swift's Glibc/Musl
        // overlays do not expose it consistently across supported builders.
        let actual = if FileManager.default.fileExists(atPath: destination.path) {
            SHA256Digest.hex(try Data(contentsOf: destination))
        } else {
            "absent"
        }
        guard actual == expectedFingerprint else { return false }
        try rename(from: source, to: destination)
        return true
        #endif
    }

    #if canImport(Darwin)
    private static func renameX(from source: URL, to destination: URL, flags: UInt32) -> Int32 {
        source.path.withCString { fromC in
            destination.path.withCString { toC in
                Darwin.renamex_np(fromC, toC, flags)
            }
        }
    }

    /// Refuses an exchanged candidate without ever swapping a newer raw
    /// replacement back out of `config.json`. The live name is first moved
    /// to a private sibling. If it is our candidate, the displaced revision
    /// is restored with `RENAME_EXCL`; if it is an external replacement,
    /// that exact newer file is restored instead. A writer that lands in the
    /// short name-vacant interval wins because every restore is exclusive.
    ///
    /// Internal for the Darwin race regression: tests can begin from the
    /// exact post-exchange state without a timing-dependent syscall hook.
    @discardableResult
    static func rollbackCandidateIfCurrent(
        displaced source: URL,
        destination: URL,
        candidateFingerprint: String
    ) throws -> Bool {
        let evacuated = destination.deletingLastPathComponent().appendingPathComponent(
            destination.lastPathComponent + ".rollback-live-" + UUID().uuidString + ".json",
            isDirectory: false
        )
        let evacuate = renameX(from: destination, to: evacuated, flags: UInt32(RENAME_EXCL))
        guard evacuate == 0 else {
            let evacuateErrno = errno
            if evacuateErrno == ENOENT {
                // A raw writer removed the candidate. Absence is itself a
                // valid external revision; never resurrect displaced bytes
                // over that later deletion.
                try? FileManager.default.removeItem(at: source)
                return false
            }
            throw ConfigStoreError.replacementRollbackFailed(
                errno: evacuateErrno, candidateMayBeInstalledAt: destination.path
            )
        }

        let evacuatedIsCandidate: Bool
        do {
            evacuatedIsCandidate = SHA256Digest.hex(try Data(contentsOf: evacuated))
                == candidateFingerprint
        } catch {
            // We cannot classify these bytes, so put the exact file that was
            // live back without overwriting a writer that arrived meanwhile.
            let restore = renameX(from: evacuated, to: destination, flags: UInt32(RENAME_EXCL))
            if restore == 0 {
                let recovery = try preserveRollbackArtifact(from: source, beside: destination)
                throw ConfigStoreError.rollbackArtifactPreserved(path: recovery.path)
            }
            if errno == EEXIST {
                try? FileManager.default.removeItem(at: evacuated)
                try? FileManager.default.removeItem(at: source)
                return false
            }
            throw error
        }

        let revisionToRestore = evacuatedIsCandidate ? source : evacuated
        let restore = renameX(
            from: revisionToRestore,
            to: destination,
            flags: UInt32(RENAME_EXCL)
        )
        if restore == 0 {
            if evacuatedIsCandidate {
                try? FileManager.default.removeItem(at: evacuated)
            } else {
                // The replacement that arrived before rollback is live
                // again; the older displaced revision is no longer needed.
                try? FileManager.default.removeItem(at: source)
            }
            return evacuatedIsCandidate
        }

        let restoreErrno = errno
        if restoreErrno == EEXIST {
            // A still-newer raw writer won the vacant-name race. Never
            // overwrite it with either the candidate or an older revision.
            try? FileManager.default.removeItem(at: evacuated)
            try? FileManager.default.removeItem(at: source)
            return false
        }

        // No safe live-name mutation remains. Preserve the non-candidate
        // bytes under a unique recovery name and report the exact path.
        if evacuatedIsCandidate {
            try? FileManager.default.removeItem(at: evacuated)
            let recovery = try preserveRollbackArtifact(from: source, beside: destination)
            throw ConfigStoreError.rollbackArtifactPreserved(path: recovery.path)
        }
        let recovery = evacuated
        if FileManager.default.fileExists(atPath: source.path) {
            _ = try? preserveRollbackArtifact(from: source, beside: destination)
        }
        throw ConfigStoreError.rollbackArtifactPreserved(path: recovery.path)
    }

    /// Moves an artifact out of the fixed `.tmp` path without replacing
    /// anything. The caller has already discovered that it cannot safely
    /// discard these bytes; a unique sibling survives this failed save and
    /// cannot be overwritten by the next ordinary attempt.
    private static func preserveRollbackArtifact(
        from source: URL,
        beside destination: URL
    ) throws -> URL {
        let recovery = destination.deletingLastPathComponent().appendingPathComponent(
            destination.lastPathComponent + ".rollback-" + UUID().uuidString + ".json",
            isDirectory: false
        )
        let preserve = renameX(from: source, to: recovery, flags: UInt32(RENAME_EXCL))
        guard preserve == 0 else {
            let preserveErrno = errno
            throw ConfigStoreError.renameFailed(
                errno: preserveErrno, from: source.path, to: recovery.path
            )
        }
        return recovery
    }
    #endif
}

/// Low-level failures from `ConfigStore.save(_:)`'s atomic rename step.
public enum ConfigStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case renameFailed(errno: Int32, from: String, to: String)
    case replacementRollbackFailed(errno: Int32, candidateMayBeInstalledAt: String)
    case rollbackArtifactPreserved(path: String)
    case changedOnDisk
    case writeLockBusy(path: String)
    case writeLockUnusable(LockFailure)

    public var description: String {
        switch self {
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        case .replacementRollbackFailed(let errno, let path):
            return "could not roll back a refused config replacement (errno \(errno)); "
                + "the uncommitted candidate may be installed at \(path)"
        case .rollbackArtifactPreserved(let path):
            return "config.json changed repeatedly during save; an uncertain rollback artifact "
                + "was preserved at \(path); reload settings and reconcile that file before saving"
        case .changedOnDisk:
            return "config.json changed on disk; reload the latest settings before saving"
        case .writeLockBusy(let path):
            return "another process is changing config.json (lock busy: \(path)); reload and try again"
        case .writeLockUnusable(let failure):
            return "cannot safely lock config.json for writing: \(failure)"
        }
    }

    /// Both cases mean the caller's edit revision lost to an external
    /// writer and should expose the same reload affordance. The preservation
    /// case carries extra recovery information but is still a CAS refusal.
    public var isRevisionConflict: Bool {
        switch self {
        case .changedOnDisk, .rollbackArtifactPreserved:
            return true
        default:
            return false
        }
    }

    /// The save failed after a Darwin exchange entered recovery, so callers
    /// must inspect the live config before undoing any related side effect.
    public var commitMayBeUncertain: Bool {
        switch self {
        case .replacementRollbackFailed, .rollbackArtifactPreserved:
            return true
        default:
            return false
        }
    }
}

/// `config.json`'s bytes, their fingerprint, and the configuration decoded
/// from exactly those bytes — so a caller cannot bind a hash of one revision
/// while acting on another.
public struct ConfigSnapshot: Sendable {
    public let bytes: Data
    public let fingerprint: String
    public let config: AppConfig

    public init(bytes: Data, fingerprint: String, config: AppConfig) {
        self.bytes = bytes
        self.fingerprint = fingerprint
        self.config = config
    }
}
