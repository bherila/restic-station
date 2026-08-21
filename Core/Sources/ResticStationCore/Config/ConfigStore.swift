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
        guard let bytes = try? Data(contentsOf: paths.configFile) else {
            return ConfigSnapshot(bytes: Data(), fingerprint: "absent", config: AppConfig())
        }
        let decoded = try Self.makeDecoder().decode(AppConfig.self, from: bytes)
        if decoded.version > AppConfig.currentVersion {
            throw ConfigError.newerVersion(found: decoded.version, supported: AppConfig.currentVersion)
        }
        try decoded.validate()
        guard decoded.version == AppConfig.currentVersion else {
            _ = try load()   // migrates and rewrites
            return try snapshotAfterMigration()
        }
        return ConfigSnapshot(bytes: bytes, fingerprint: SHA256Digest.hex(bytes), config: decoded)
    }

    private func snapshotAfterMigration() throws -> ConfigSnapshot {
        guard let bytes = try? Data(contentsOf: paths.configFile) else {
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
        guard let data = try? Data(contentsOf: paths.configFile) else { return "absent" }
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
        let migration = migrateToCurrentVersion(config, originalBytes: data)
        // Mirrors the original single-function behavior exactly: config.json
        // is never overwritten unless the v1 backup is confirmed on disk —
        // see the ordering note on `migrateToCurrentVersion`.
        guard migration.backupWritten else {
            return migration.config
        }
        do {
            try save(migration.config)
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
        try data.write(to: tempConfigFile)
        try AtomicFile.rename(from: tempConfigFile, to: paths.configFile)
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
}

/// Low-level failures from `ConfigStore.save(_:)`'s atomic rename step.
public enum ConfigStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case renameFailed(errno: Int32, from: String, to: String)

    public var description: String {
        switch self {
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
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
