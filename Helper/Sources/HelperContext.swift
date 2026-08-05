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
    let secrets: any SecretStore
    let restic: ResticRunner
    let reachability: Reachability
    let engine: BackupEngine
    let config: AppConfig

    /// The strict entry point used by every subcommand except `tick`:
    /// loads config from disk (a hard I/O/decode/version error → exit 1),
    /// then resolves a restic path (unresolvable → exit 1 with
    /// `resticNotFoundMessage`).
    static func make() async -> HelperContext {
        let paths = AppPaths.default()
        let configStore = ConfigStore(paths: paths)
        let config: AppConfig
        do {
            config = try configStore.load()
        } catch {
            HelperExit.fail("could not load configuration: \(error)")
        }
        guard let context = await makeTolerant(paths: paths, config: config, configStore: configStore) else {
            HelperExit.fail(resticNotFoundMessage(paths: paths))
        }
        return context
    }

    /// The lenient constructor `tick` uses: `tick`'s own contract is "exit 0
    /// always, except a hard config-load error" (`docs/scheduling.md`
    /// §Tick algorithm) — an unresolvable restic path must not be treated as
    /// a hard error there, so this returns `nil` instead of exiting.
    static func makeTolerant(paths: AppPaths, config: AppConfig, configStore: ConfigStore) async -> HelperContext? {
        guard let resticPath = await resolveResticPath(config: config) else {
            return nil
        }
        let processRunner = DefaultProcessRunner()
        let secrets = makeSecretStore(paths: paths, runner: processRunner)
        let restic = ResticRunner(resticPath: resticPath, paths: paths, secrets: secrets, runner: processRunner)
        let runStore = RunStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        let reachability = Reachability(restic: restic)
        let engine = BackupEngine(
            config: config,
            paths: paths,
            restic: restic,
            secrets: secrets,
            runStore: runStore,
            stateStore: stateStore,
            reachability: reachability
        )
        return HelperContext(
            paths: paths,
            configStore: configStore,
            stateStore: stateStore,
            runStore: runStore,
            secrets: secrets,
            restic: restic,
            reachability: reachability,
            engine: engine,
            config: config
        )
    }

    /// The one place the helper decides which secret backend to use:
    /// keychain on macOS, `secrets.json` elsewhere, overridable with
    /// `RESTIC_STATION_SECRET_BACKEND` (`docs/keychain-and-fda.md` §5).
    ///
    /// A bad override is fatal even for `tick`, whose contract is otherwise
    /// "exit 0 unless config itself is broken": a helper that cannot tell
    /// which store holds the passwords must not guess, and guessing wrong
    /// looks exactly like "all my passwords disappeared".
    static func makeSecretStore(paths: AppPaths, runner: ProcessRunning) -> any SecretStore {
        do {
            return try SecretStoreFactory.make(paths: paths, runner: runner)
        } catch {
            HelperExit.fail("secret storage is misconfigured: \(error)")
        }
    }
}

/// The minimal context the `secret` subcommands need: a secret store and
/// (for the ones that name destinations) the configuration.
///
/// Deliberately *not* `HelperContext`: entering a password must work before
/// a restic binary has ever been configured, and `HelperContext.make()`
/// exits 1 when `resticPath` is missing.
struct SecretContext {
    let paths: AppPaths
    let store: any SecretStore
    let config: AppConfig

    static func make() -> SecretContext {
        let paths = AppPaths.default()
        let config: AppConfig
        do {
            config = try ConfigStore(paths: paths).load()
        } catch {
            HelperExit.fail("could not load configuration: \(error)")
        }
        return SecretContext(
            paths: paths,
            store: HelperContext.makeSecretStore(paths: paths, runner: DefaultProcessRunner()),
            config: config
        )
    }

    /// Every configured destination, in config order, with its owning set's
    /// name for display.
    var destinations: [(setName: String, destination: Destination)] {
        config.sets.flatMap { set in
            set.destinations.map { (setName: set.name, destination: $0) }
        }
    }

    /// Resolves `--dest`, or exits 1 per the T10 contract.
    func destination(_ destId: UUID) -> Destination {
        guard let match = destinations.first(where: { $0.destination.id == destId })?.destination else {
            HelperExit.fail("no configured destination with id \(destId)")
        }
        return match
    }
}
