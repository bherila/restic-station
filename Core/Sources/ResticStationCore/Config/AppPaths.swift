import Foundation

/// Single source of truth for every runtime path Restic Station reads or
/// writes. Never hard-code a path elsewhere — go through `AppPaths`.
///
/// `root` defaults to `~/Library/Application Support/ResticStation` and is
/// overridable via `init(root:)` and via the `RESTIC_STATION_DATA_DIR`
/// environment variable (used by tests and `scripts/integration-test.sh`).
///
/// See `docs/architecture.md` §AppPaths for the full table this mirrors.
public struct AppPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Resolves the root from `RESTIC_STATION_DATA_DIR` if set (non-empty),
    /// else `~/Library/Application Support/ResticStation`.
    public static func `default`() -> AppPaths {
        if let override = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("ResticStation", isDirectory: true)
        return AppPaths(root: appSupport)
    }

    // MARK: - config.json

    public var configFile: URL {
        root.appendingPathComponent("config.json", isDirectory: false)
    }

    // MARK: - runs/

    public var runsDir: URL {
        root.appendingPathComponent("runs", isDirectory: true)
    }

    /// `runs/index.jsonl` — append-only, one summary JSON line per finished run.
    public var runsIndexFile: URL {
        runsDir.appendingPathComponent("index.jsonl", isDirectory: false)
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

    // MARK: - locks/

    public var locksDir: URL {
        root.appendingPathComponent("locks", isDirectory: true)
    }

    /// `locks/tick.lock` — flock file (see `docs/scheduling.md`).
    public var tickLockFile: URL {
        locksDir.appendingPathComponent("tick.lock", isDirectory: false)
    }

    /// `locks/set-<setId>.lock` — flock file (see `docs/scheduling.md`).
    public func setLockFile(setId: UUID) -> URL {
        locksDir.appendingPathComponent("set-\(setId.uuidString).lock", isDirectory: false)
    }

    // MARK: - mounts/ (docs/restic-cli.md §mount)

    /// `mounts/<destId>/` — `restic mount` mountpoint for browsing a repo.
    public func mountsDir(destId: UUID) -> URL {
        root.appendingPathComponent("mounts", isDirectory: true)
            .appendingPathComponent(destId.uuidString, isDirectory: true)
    }

    // MARK: - restic cache

    /// restic's cache, redirected via `RESTIC_CACHE_DIR`. Fixed at
    /// `~/Library/Caches/net.herila.ResticStation/restic` per
    /// `docs/architecture.md` and `docs/restic-cli.md` — independent of
    /// `root`, since it is a regenerable cache, not app state.
    public var resticCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("net.herila.ResticStation", isDirectory: true)
            .appendingPathComponent("restic", isDirectory: true)
    }

    // MARK: - Directory creation

    /// Creates `root`, `runs/`, `state/`, and `locks/` if missing. Idempotent.
    public func ensureDirectories() throws {
        let fileManager = FileManager.default
        for directory in [root, runsDir, stateDir, locksDir] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
