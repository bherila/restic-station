import ArgumentParser
import Foundation
import ResticStationCore

/// `UUID` has no built-in `ExpressibleByArgument` conformance in
/// swift-argument-parser; every `--set`/`--dest` flag across these
/// subcommands needs it.
extension UUID: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(uuidString: argument)
    }
}

/// The everyday exit surface for helper subcommands: print a human-readable
/// line and exit with the contract's code (`docs/tasks/T10-helper-cli.md`:
/// 0 ok, 1 error, 2 busy, 3 offline). Bypasses ArgumentParser's own error
/// formatting (which prefixes "Error:" and always exits 1) so every
/// subcommand controls its own message and exit code precisely.
enum HelperExit {
    /// Writes `message` to stderr, then exits with `code` (default 1 —
    /// "error" in the T10 contract).
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    /// Exits with `code` without printing anything — used once the caller
    /// has already written its own human-readable line to stdout.
    static func code(_ code: Int32) -> Never {
        exit(code)
    }
}

/// Shared bootstrapping for every helper subcommand that touches the engine
/// (`docs/tasks/T10-helper-cli.md`): builds `AppPaths` (env override
/// respected via `AppPaths.default()`), loads `config.json`, and wires up
/// every Core collaborator `BackupEngine` needs.
struct HelperContext {
    let paths: AppPaths
    let configStore: ConfigStore
    let stateStore: StateStore
    let runStore: RunStore
    let keychain: KeychainClient
    let restic: ResticRunner
    let reachability: Reachability
    let engine: BackupEngine
    let config: AppConfig

    /// The strict entry point used by every subcommand except `tick`:
    /// loads config from disk (a hard I/O/decode/version error → exit 1),
    /// then requires a configured restic path (missing → exit 1, "restic
    /// not configured — open Restic Station" per the T10 task file).
    static func make() -> HelperContext {
        let paths = AppPaths.default()
        let configStore = ConfigStore(paths: paths)
        let config: AppConfig
        do {
            config = try configStore.load()
        } catch {
            HelperExit.fail("could not load configuration: \(error)")
        }
        guard let context = makeTolerant(paths: paths, config: config, configStore: configStore) else {
            HelperExit.fail("restic not configured — open Restic Station")
        }
        return context
    }

    /// The lenient constructor `tick` uses: `tick`'s own contract is "exit 0
    /// always, except a hard config-load error" (`docs/scheduling.md`
    /// §Tick algorithm) — a missing restic path must not be treated as a
    /// hard error there, so this returns `nil` instead of exiting.
    static func makeTolerant(paths: AppPaths, config: AppConfig, configStore: ConfigStore) -> HelperContext? {
        guard let resticPath = config.resticPath, !resticPath.isEmpty else {
            return nil
        }
        let processRunner = DefaultProcessRunner()
        let keychain = KeychainClient(runner: processRunner)
        let restic = ResticRunner(resticPath: resticPath, paths: paths, keychain: keychain, runner: processRunner)
        let runStore = RunStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        let reachability = Reachability(restic: restic)
        let engine = BackupEngine(
            config: config,
            paths: paths,
            restic: restic,
            keychain: keychain,
            runStore: runStore,
            stateStore: stateStore,
            reachability: reachability
        )
        return HelperContext(
            paths: paths,
            configStore: configStore,
            stateStore: stateStore,
            runStore: runStore,
            keychain: keychain,
            restic: restic,
            reachability: reachability,
            engine: engine,
            config: config
        )
    }
}
