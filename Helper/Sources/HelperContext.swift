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
/// respected via `AppPaths.default()`), loads `config.json` + `machine.json`,
/// **resolves the per-machine view once, here**, and wires up every Core
/// collaborator `BackupEngine` needs.
///
/// **Two views, and every subcommand must say which one it means.** There is
/// deliberately no bare `config` property here: "what do I back up?" and
/// "which repositories can I address?" differ on a machine that disables a
/// set, and answering the second with the first is how a restore-only host
/// loses the ability to restore. See `ResolvedConfig.Scope`.
///
/// Nothing downstream of this type knows that `machineId` exists.
struct HelperContext {
    let paths: AppPaths
    let configStore: ConfigStore
    let stateStore: StateStore
    let runStore: RunStore
    let secrets: any SecretStore
    let restic: ResticRunner
    let reachability: Reachability
    let engine: BackupEngine
    /// What this machine backs up: `tick` and `run-set` (backup, check,
    /// prune). Carries the omissions to explain.
    let scheduled: ResolvedConfig
    /// Every repository this machine can address: `restore`, `probe-repo`,
    /// `unlock`, `init-secondary`. Drops nothing.
    let addressable: ResolvedConfig

    /// The two per-machine views of `config.json`, resolved once. The single
    /// place resolution happens on the helper side.
    struct Views {
        let scheduled: ResolvedConfig
        let addressable: ResolvedConfig
    }

    /// Loads `config.json` + `machine.json` and resolves both views.
    ///
    /// Order matters: `configStore.load()` may run a schema migration,
    /// which writes `resticPath` into `machine.json` and clears it from the
    /// config it returns. Reading the machine identity *after* the load is
    /// what makes the migrated path visible on the very first run rather
    /// than one invocation later.
    static func loadViews(paths: AppPaths, configStore: ConfigStore) throws -> Views {
        let config = try configStore.load()
        let machine = try MachineStore(paths: paths).load()
        return Views(
            scheduled: config.resolved(for: machine),
            addressable: config.addressable(for: machine)
        )
    }

    /// The strict entry point used by every subcommand except `tick`:
    /// loads config from disk (a hard I/O/decode/version error → exit 1),
    /// then resolves a restic path (unresolvable → exit 1 with
    /// `resticNotFoundMessage`).
    ///
    /// Throws ``CLIFailure`` rather than exiting, so the failure can be
    /// rendered as a JSON envelope for a caller that asked for one
    /// (`docs/cli-json.md`). The exit codes and the human wording are
    /// unchanged — `resticNotFoundMessage` still builds the prose, and the
    /// classification is derived from the same discovery result it reads.
    static func make() async throws -> HelperContext {
        let paths = AppPaths.default()
        let configStore = ConfigStore(paths: paths)
        let views: Views
        do {
            views = try loadViews(paths: paths, configStore: configStore)
        } catch {
            throw CLIFailure.configInvalid(underlying: error)
        }
        switch await makeTolerant(paths: paths, views: views, configStore: configStore) {
        case .ready(let context):
            return context
        case .noRestic(let result):
            throw CLIFailure.resticUnavailable(
                result: result,
                message: resticNotFoundMessage(paths: paths, result: result)
            )
        }
    }

    /// The lenient constructor `tick` uses: `tick`'s own contract is "exit 0
    /// always, except a hard config-load error" (`docs/scheduling.md`
    /// §Tick algorithm) — an unresolvable restic path must not be treated as
    /// a hard error there, so this reports the failure instead of exiting.
    ///
    /// Returns the discovery result rather than a bare `nil` so the caller
    /// can explain *which* of the three failures it was (issue #50) without
    /// re-running a search that may take up to
    /// `maxCandidates × probeTimeout` seconds.
    enum TolerantOutcome {
        case ready(HelperContext)
        case noRestic(ResticDiscoveryResult)
    }

    static func makeTolerant(
        paths: AppPaths,
        views: Views,
        configStore: ConfigStore
    ) async -> TolerantOutcome {
        let resticPath: String
        switch await resolveResticPath(resolved: views.scheduled) {
        case .resolved(let path):
            resticPath = path
        case .notFound(let result):
            return .noRestic(result)
        }
        let processRunner = DefaultProcessRunner()
        let secrets = makeSecretStore(paths: paths, runner: processRunner)
        let restic = ResticRunner(resticPath: resticPath, paths: paths, secrets: secrets, runner: processRunner)
        let runStore = RunStore(paths: paths)
        let stateStore = StateStore(paths: paths)
        let reachability = Reachability(restic: restic)
        // The **addressable** view: the engine's only use of its config is
        // `locate(destId:)`, which maps a destination back to its owning set
        // so a restore takes that set's lock. A restore into a set this
        // machine does not back up is legitimate and must still be
        // serialized correctly, so the engine needs the superset. What the
        // engine *backs up* is decided by the `BackupSet` its callers hand
        // to `runSet`, and those come from `scheduled`.
        let engine = BackupEngine(
            config: views.addressable.config,
            paths: paths,
            restic: restic,
            secrets: secrets,
            runStore: runStore,
            stateStore: stateStore,
            reachability: reachability
        )
        return .ready(HelperContext(
            paths: paths,
            configStore: configStore,
            stateStore: stateStore,
            runStore: runStore,
            secrets: secrets,
            restic: restic,
            reachability: reachability,
            engine: engine,
            scheduled: views.scheduled,
            addressable: views.addressable
        ))
    }

    /// The one place the helper decides which secret backend to use:
    /// keychain on macOS, `secrets.json` elsewhere, overridable with
    /// `RESTIC_STATION_SECRET_BACKEND` (`docs/keychain-and-fda.md` §5).
    ///
    /// A bad override is fatal even for `tick`, whose contract is otherwise
    /// "exit 0 unless config itself is broken": a helper that cannot tell
    /// which store holds the passwords must not guess, and guessing wrong
    /// looks exactly like "all my passwords disappeared".
    /// `helperExecutablePath` is *this* binary: the helper is the one process
    /// for which "the current executable" really is the right target for the
    /// file backend's `RESTIC_PASSWORD_COMMAND` — the app must pass its
    /// embedded helper's path instead, which is why the factory has no
    /// default.
    static func makeSecretStore(paths: AppPaths, runner: ProcessRunning) -> any SecretStore {
        do {
            return try SecretStoreFactory.make(
                paths: paths,
                runner: runner,
                helperExecutablePath: FileSecretStore.currentExecutablePath()
            )
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
