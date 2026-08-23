import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Single source of truth for every runtime path Restic Station reads or
/// writes. Never hard-code a path elsewhere — go through `AppPaths`.
///
/// `root` is platform-dependent:
/// - macOS: `~/Library/Application Support/ResticStation`
/// - Linux: `$XDG_STATE_HOME/restic-station`, falling back to
///   `~/.local/state/restic-station`
///
/// It is overridable via `init(root:)` and via the `RESTIC_STATION_DATA_DIR`
/// environment variable (used by tests and `scripts/integration-test.sh`),
/// which takes precedence on both platforms.
///
/// **Everything below `root` is byte-identical across platforms** — only
/// `root` and `resticCacheDir` branch on the OS. `config export`/`import`
/// and rsync-ing a data directory between hosts depend on this.
///
/// See `docs/architecture.md` §AppPaths for the full table this mirrors.
public struct AppPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves the root from `RESTIC_STATION_DATA_DIR` if set (non-empty),
    /// else the platform default: `~/Library/Application Support/ResticStation`
    /// on macOS, `$XDG_STATE_HOME/restic-station` (or
    /// `~/.local/state/restic-station`) on Linux.
    public static func `default`() -> AppPaths {
        if let override = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        #if os(Linux)
        return AppPaths(root: xdgBaseDirectory(
            variable: "XDG_STATE_HOME",
            fallbackHomeRelativeComponents: [".local", "state"]
        ).appendingPathComponent("restic-station", isDirectory: true))
        #else
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ResticStation", isDirectory: true)
        return AppPaths(root: appSupport)
        #endif
    }

    #if os(Linux)
    /// Resolves an XDG base directory per the XDG Base Directory Specification:
    /// the environment variable is honoured only when set, non-empty, **and**
    /// an absolute path; anything else falls back to the home-relative default
    /// as if the variable were unset.
    static func xdgBaseDirectory(variable: String, fallbackHomeRelativeComponents: [String]) -> URL {
        if let value = ProcessInfo.processInfo.environment[variable],
           !value.isEmpty,
           value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        var url = FileManager.default.homeDirectoryForCurrentUser
        for component in fallbackHomeRelativeComponents {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url
    }
    #endif

    // MARK: - config.json

    public var configFile: URL {
        root.appendingPathComponent("config.json", isDirectory: false)
    }

    /// `config.v<N>.backup.json` — the untouched copy of a `config.json` at
    /// schema version `N` that `ConfigStore` writes once, immediately before
    /// the first write at a newer version (`docs/data-model.md` §Versioning &
    /// migration). Never overwritten.
    ///
    /// **Keyed by the version being migrated *from*, not by a fixed name.**
    /// A single `config.v1.backup.json` was correct while v2 was the only
    /// destination, but it silently breaks the invariant as soon as a third
    /// version exists: a host that migrated v1→v2 long ago already has that
    /// file, so an `O_EXCL` write for a v2→v3 migration finds it present,
    /// reports the backup as confirmed, and lets `config.json` be overwritten
    /// with no copy of the v2 file anywhere. One file per source version
    /// keeps "never overwritten unless a backup of it exists" true for every
    /// step of the chain.
    public func configBackupFile(fromVersion version: Int) -> URL {
        root.appendingPathComponent("config.v\(version).backup.json", isDirectory: false)
    }

    /// `config.v1.backup.json` — the schema-v1 copy specifically.
    ///
    /// Retained because it names a file that exists on every host that has
    /// been through the v1→v2 migration; new code should prefer
    /// ``configBackupFile(fromVersion:)``.
    public var configV1BackupFile: URL {
        configBackupFile(fromVersion: 1)
    }

    /// `config.import-backup-<suffix>.json` — the verbatim copy `config
    /// import` (T27) writes of whatever `config.json` held immediately
    /// before an import overwrites it. Distinct from `configV1BackupFile`,
    /// which is a one-time, migration-only copy: this one is written before
    /// *every* import that finds an existing `config.json`, regardless of
    /// schema version, so an import can always be undone by hand.
    public func configImportBackupFile(suffix: String) -> URL {
        root.appendingPathComponent("config.import-backup-\(suffix).json", isDirectory: false)
    }

    // MARK: - machine.json

    /// `machine.json` — this host's `MachineConfig`. **Host-local: never
    /// copy or sync it between machines** (`docs/data-model.md`
    /// §machine.json). `config.json` is the shared file; this one is what
    /// makes a shared `config.json` mean the right thing here.
    public var machineFile: URL {
        root.appendingPathComponent("machine.json", isDirectory: false)
    }

    /// When this machine could first have seen its current configuration,
    /// approximated by the later mtime of the shared config and host-local
    /// machine files. Missing or unreadable mtimes are ignored; `nil` means
    /// callers must not derive an age-based warning from filesystem state
    /// they could not establish.
    public func configurationVisibleSince(fileManager: FileManager = .default) -> Date? {
        [configFile, machineFile].compactMap { file in
            guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else {
                return nil
            }
            return attributes[.modificationDate] as? Date
        }.max()
    }

    // MARK: - runs/

    public var runsDir: URL {
        root.appendingPathComponent("runs", isDirectory: true)
    }

    /// `runs/index.jsonl` — append-only, one summary JSON line per finished run.
    public var runsIndexFile: URL {
        runsDir.appendingPathComponent("index.jsonl", isDirectory: false)
    }

    /// Serializes appends to ``runsIndexFile`` across helper processes.
    public var runsIndexLockFile: URL {
        runsDir.appendingPathComponent("index.jsonl.lock", isDirectory: false)
    }

    public func runDir(runId: String) -> URL {
        runsDir.appendingPathComponent(runId, isDirectory: true)
    }

    /// `runs/<runId>/metadata.json` — one `RunMetadata` per run.
    public func runMetadataFile(runId: String) -> URL {
        runDir(runId: runId).appendingPathComponent("metadata.json", isDirectory: false)
    }

    /// `runs/<runId>/log.txt` — full streamed log of the run.
    public func runLogFile(runId: String) -> URL {
        runDir(runId: runId).appendingPathComponent("log.txt", isDirectory: false)
    }

    // MARK: - state/

    public var stateDir: URL {
        root.appendingPathComponent("state", isDirectory: true)
    }

    /// `state/schedule-state.json` — last-start times + check-slice cursors per set.
    public var scheduleStateFile: URL {
        stateDir.appendingPathComponent("schedule-state.json", isDirectory: false)
    }

    /// `state/current-run-<setId>.json` — live progress of an in-flight run
    /// (deleted on completion).
    public func currentRunFile(setId: UUID) -> URL {
        stateDir.appendingPathComponent("current-run-\(setId.uuidString).json", isDirectory: false)
    }

    /// `state/repo-status-<destId>.json` — reachability + last-synced info per destination.
    public func repoStatusFile(destId: UUID) -> URL {
        stateDir.appendingPathComponent("repo-status-\(destId.uuidString).json", isDirectory: false)
    }

    /// `state/fda-check.json` — result of the helper's Full Disk Access probe.
    public var fdaCheckFile: URL {
        stateDir.appendingPathComponent("fda-check.json", isDirectory: false)
    }

    /// `state/preview-tokens.json` — the local, owner-only index behind
    /// short-lived destructive-operation preview tokens.  This is state,
    /// not shared configuration: a token is bound to one machine and must
    /// never be copied with `config.json`.
    public var previewTokensFile: URL {
        stateDir.appendingPathComponent("preview-tokens.json", isDirectory: false)
    }

    /// Serializes destructive-preview token index updates across backup sets.
    public var previewTokensLockFile: URL {
        stateDir.appendingPathComponent("preview-tokens.lock", isDirectory: false)
    }

    /// Serializes the read-modify-write of `schedule-state.json`, which is
    /// one file shared by every set. The per-set locks cannot cover it: two
    /// helper processes operating on *different* sets both rewrite the whole
    /// document, so without this one can clobber the other's entry.
    public var scheduleStateLockFile: URL {
        stateDir.appendingPathComponent("schedule-state.lock", isDirectory: false)
    }

    // MARK: - locks/

    public var locksDir: URL {
        root.appendingPathComponent("locks", isDirectory: true)
    }

    /// Owner-only scratch directory used to prove that the lock filesystem
    /// can create and remove a new inode. `StateWatcher` watches `locks/`
    /// non-recursively, so activity inside this directory cannot trigger the
    /// health check that caused it.
    public var lockHealthProbeDir: URL {
        locksDir.appendingPathComponent(".health", isDirectory: true)
    }

    /// `locks/tick.lock` — flock file (see `docs/scheduling.md`).
    public var tickLockFile: URL {
        locksDir.appendingPathComponent("tick.lock", isDirectory: false)
    }

    /// Dedicated stable inode used only to verify that the backing
    /// filesystem implements `flock(2)`. It never serializes production
    /// work, so a status probe cannot make a tick skip.
    public var healthLockFile: URL {
        locksDir.appendingPathComponent("health.lock", isDirectory: false)
    }

    /// Serializes Linux file-secret read-modify-write operations.
    public var secretsLockFile: URL {
        locksDir.appendingPathComponent("secrets.lock", isDirectory: false)
    }

    /// `locks/set-<setId>.lock` — flock file (see `docs/scheduling.md`).
    public func setLockFile(setId: UUID) -> URL {
        locksDir.appendingPathComponent("set-\(setId.uuidString).lock", isDirectory: false)
    }

    // MARK: - mounts/ (docs/restic-cli.md §mount)

    /// `mounts/<destId>/` — `restic mount` mountpoint for browsing a repo.
    ///
    /// The path is defined on every platform (it is `root`-relative like all
    /// the others), but mounting is macOS-only in practice: `restic mount`
    /// needs macFUSE there and FUSE on Linux, which a headless host generally
    /// does not have.
    public func mountsDir(destId: UUID) -> URL {
        root.appendingPathComponent("mounts", isDirectory: true)
            .appendingPathComponent(destId.uuidString, isDirectory: true)
    }

    // MARK: - restic cache

    /// restic's cache, redirected via `RESTIC_CACHE_DIR`. Per
    /// `docs/architecture.md` and `docs/restic-cli.md` this is deliberately
    /// **independent of `root`**, since it is a regenerable cache, not app
    /// state:
    /// - macOS: `~/Library/Caches/net.herila.ResticStation/restic`
    /// - Linux: `$XDG_CACHE_HOME/restic-station/restic`, falling back to
    ///   `~/.cache/restic-station/restic`
    public var resticCacheDir: URL {
        #if os(Linux)
        Self.xdgBaseDirectory(variable: "XDG_CACHE_HOME", fallbackHomeRelativeComponents: [".cache"])
            .appendingPathComponent("restic-station", isDirectory: true)
            .appendingPathComponent("restic", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("net.herila.ResticStation", isDirectory: true)
            .appendingPathComponent("restic", isDirectory: true)
        #endif
    }

    // MARK: - Directory creation

    /// Creates `root`, `runs/`, `state/`, and `locks/` if missing. A fresh
    /// `root` is owner-only because it may later contain secrets. Missing
    /// ancestors are created separately with the process-default mode so the
    /// `0700` attribute is not imposed on shared XDG directories such as
    /// `~/.local` and `~/.local/state`. Idempotent.
    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        let parent = root.deletingLastPathComponent()
        if parent.path != root.path {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [runsDir, stateDir, locksDir, lockHealthProbeDir] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // `state/` holds `preview-tokens.json` — live capabilities for
        // destructive operations — so it is owner-only regardless of umask,
        // and re-asserted rather than set once at creation.
        //
        // `root` is deliberately NOT re-tightened here. An operator's chosen
        // data directory mode is theirs (`scripts/secret-cli-test.sh` pins a
        // pre-existing 755 dir staying 755), and the protection that matters
        // is per-file: the token index is 0600 and refuses to load if it is
        // not. This narrows the exposure without overriding that choice.
        for directory in [stateDir, lockHealthProbeDir] {
            var info = stat()
            let statResult = directory.path.withCString { lstat($0, &info) }
            guard statResult == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
            }
            if info.st_mode & 0o777 != 0o700 {
                guard chmod(directory.path, 0o700) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }
}
