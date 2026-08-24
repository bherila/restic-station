import Foundation

/// Everything about *how the app talks to `restic-station-helper`* that can
/// be decided without touching the filesystem, `Process`, or launchd —
/// extracted into Core so it is unit-testable (`docs/tasks/T11-launchd.md`:
/// "unit-testing argv construction by extracting a pure `argv(for:)`
/// function"). The App-side `HelperInvoker` is then a thin spawn-and-map
/// shell over these values.
///
/// The flag spellings below are the merged helper's actual
/// `@Option(name: .long)` declarations (`Helper/Sources/Commands/*.swift`);
/// a mismatch is a runtime bug no compiler can catch, since the two sides
/// only meet across an `execve` boundary. `HelperCommandTests` pins every
/// one of them.
public enum HelperCommand: Equatable, Sendable {
    /// `tick` — one scheduling pass. Normally the host scheduler's job
    /// (launchd on macOS, a systemd `--user` timer on Linux — see
    /// `SchedulerCommand.swift`); the app spawns it directly only in
    /// debug/diagnostic paths (the *supported* way for the app to force a
    /// tick is `launchctl kickstart`, see `LaunchctlCommand`, so the tick
    /// keeps running in the launchd context its TCC attribution depends on).
    case tick
    /// `run-set --set <uuid> --kind backup` — "Back Up Now".
    case backUpNow(setId: UUID)
    /// `run-set --set <uuid> --kind prune`.
    /// `run-set --set <uuid> --kind prune [--expected-config <fingerprint>]`.
    /// `expectedConfig` is the `config.json` fingerprint the caller reviewed;
    /// the helper refuses if the file changed underneath it.
    case prune(setId: UUID, expectedConfig: String? = nil)
    /// `run-set --set <uuid> --kind check`.
    case check(setId: UUID)
    /// `maintenance prune --set <uuid> [--dest <uuid>] [--expected-destination-stdin] [--dry-run]`.
    /// This reclaims unused packs without applying a retention policy.
    /// `expectedDestination` is an opaque helper-issued binding for the full
    /// effective destination the preceding preview described; direct CLI
    /// callers may omit it.
    case maintenancePrune(setId: UUID, destId: UUID?, expectedDestination: String?, dryRun: Bool, json: Bool = false)
    /// `init-secondary --set <uuid> --dest <uuid>`.
    case initSecondary(setId: UUID, destId: UUID)
    /// `probe-repo --set <uuid> --dest <uuid>` (exit 3 = offline).
    case probeRepo(setId: UUID, destId: UUID)
    /// `unlock --set <uuid> --dest <uuid>` — the Maintenance screen's
    /// "Remove stale locks" utility (`docs/ui-spec.md` §Maintenance).
    ///
    /// Unlike every other repository-touching command here, this one writes
    /// **no run record**: `RunKind` has no case for it, and borrowing
    /// `check`/`prune` would put a wrong "what happened last" line into
    /// `runs/index.jsonl`. The reasoning is spelled out in the helper
    /// subcommand's own abstract (`Helper/Sources/Commands/Unlock.swift`);
    /// callers therefore get their feedback from the printed result line,
    /// not from the Runs screen.
    case unlock(setId: UUID, destId: UUID)
    /// `restore --set … --dest … --snapshot … --target … [--sub …]
    /// [--include …]… [--overwrite …]`.
    case restore(HelperRestoreArgs)
    /// `fda-check --context <label>` — the Full Disk Access probe
    /// (`docs/keychain-and-fda.md` §2). `context` is recorded verbatim in
    /// `state/fda-check.json` so the UI can tell *which* process context
    /// produced a result.
    case fdaCheck(context: String)
    /// `version`.
    case version

    /// The helper's non-sensitive argument vector **excluding argv[0]**.
    ///
    /// Callers that spawn the helper must use ``invocation`` rather than
    /// treating this as the complete process description: confirmation
    /// capabilities deliberately travel in its redacted stdin payload, not
    /// in argv where Linux exposes them through `/proc/<pid>/cmdline`.
    public var argv: [String] {
        switch self {
        case .tick:
            return ["tick"]
        case .backUpNow(let setId):
            return Self.runSet(setId: setId, kind: "backup")
        case .prune(let setId, let expectedConfig):
            var argv = Self.runSet(setId: setId, kind: "prune")
            // Attached form so a fingerprint can never be reparsed as an option.
            if let expectedConfig { argv.append("--expected-config=\(expectedConfig)") }
            return argv
        case .check(let setId):
            return Self.runSet(setId: setId, kind: "check")
        case .maintenancePrune(let setId, let destId, let expectedDestination, let dryRun, let json):
            var argv = ["maintenance", "prune", "--set", Self.render(setId)]
            if let destId { argv.append(contentsOf: ["--dest", Self.render(destId)]) }
            // The opaque confirmation is deliberately stdin, never argv.
            // Only this selector is visible to another local user through
            // `/proc/<pid>/cmdline`; the value is carried by `invocation`.
            if expectedDestination != nil { argv.append("--expected-destination-stdin") }
            if dryRun { argv.append("--dry-run") }
            if json { argv.append("--json") }
            return argv
        case .initSecondary(let setId, let destId):
            return ["init-secondary", "--set", Self.render(setId), "--dest", Self.render(destId)]
        case .probeRepo(let setId, let destId):
            return ["probe-repo", "--set", Self.render(setId), "--dest", Self.render(destId)]
        case .unlock(let setId, let destId):
            return ["unlock", "--set", Self.render(setId), "--dest", Self.render(destId)]
        case .restore(let args):
            return Self.restoreArgv(args)
        case .fdaCheck(let context):
            return ["fda-check", "--context", context]
        case .version:
            return ["version"]
        }
    }

    /// The complete, redaction-preserving process contract for this command.
    ///
    /// `argv` alone is intentionally insufficient for a confirmed
    /// maintenance prune. Keeping the capability beside argv in a typed
    /// value prevents a future App call site from accidentally rebuilding
    /// the old token-bearing command line.
    public var invocation: HelperInvocationSpec {
        let sensitiveStdin: HelperSensitiveInput?
        switch self {
        case .maintenancePrune(_, _, let expectedDestination, _, _):
            sensitiveStdin = expectedDestination.map(HelperSensitiveInput.init)
        default:
            sensitiveStdin = nil
        }
        return HelperInvocationSpec(argv: argv, sensitiveStdin: sensitiveStdin)
    }

    /// The subcommand name (`argv[0]` of `argv`), i.e. what
    /// `HelperMain.configuration.subcommands` must contain.
    public var subcommandName: String {
        argv[0]
    }

    // MARK: - Builders

    /// `RunSet.Kind` defaults to `.backup` in the helper, and
    /// `docs/scheduling.md` §What the app does writes the short form
    /// (`run-set --set <uuid>`). We nevertheless always pass `--kind`
    /// explicitly: the default lives in a *different target* that the app
    /// links no code from, so relying on it would let a future change of
    /// that default silently re-point "Back Up Now". Same command, no
    /// cross-target coupling.
    private static func runSet(setId: UUID, kind: String) -> [String] {
        ["run-set", "--set", render(setId), "--kind", kind]
    }

    private static func restoreArgv(_ args: HelperRestoreArgs) -> [String] {
        var argv = ["restore"]
        argv.append(contentsOf: ["--set", render(args.setId)])
        argv.append(contentsOf: ["--dest", render(args.destId)])
        argv.append(contentsOf: ["--snapshot", args.snapshotID])
        argv.append(contentsOf: ["--target", args.targetPath])
        if let subpath = args.subpath {
            argv.append(contentsOf: ["--sub", subpath])
        }
        for include in args.includes {
            // `@Option var include: [String]` — repeatable, one `--include`
            // per value (ArgumentParser has no comma-separated form here).
            argv.append(contentsOf: ["--include", include])
        }
        if let overwriteMode = args.overwriteMode {
            argv.append(contentsOf: ["--overwrite", overwriteMode.rawValue])
        }
        return argv
    }

    /// `UUID` is parsed helper-side by `UUID(uuidString:)` (see the
    /// `ExpressibleByArgument` conformance in
    /// `Helper/Sources/HelperContext.swift`), which is case-insensitive;
    /// `uuidString` (canonical uppercase) is what we send.
    private static func render(_ id: UUID) -> String {
        id.uuidString
    }
}

/// A capability payload for an app-to-helper pipe.
///
/// Its value is intentionally private and both textual renderings are
/// redacted. `HelperInvoker` is the only consumer and obtains bytes through
/// ``data`` immediately before it creates the helper's closed stdin pipe.
public struct HelperSensitiveInput: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Bytes to write to the helper's stdin. This is a transport seam, not a
    /// diagnostic API; callers must not log or serialize it.
    public var data: Data { Data(value.utf8) }

    public var description: String { "<redacted sensitive stdin>" }
    public var debugDescription: String { description }
}

/// Everything required to spawn the helper without putting a capability in
/// argv or the environment.
public struct HelperInvocationSpec: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let argv: [String]
    public let sensitiveStdin: HelperSensitiveInput?

    public init(argv: [String], sensitiveStdin: HelperSensitiveInput?) {
        self.argv = argv
        self.sensitiveStdin = sensitiveStdin
    }

    public var description: String {
        let stdinDescription = sensitiveStdin == nil ? "nil" : "<redacted>"
        return "HelperInvocationSpec(argv: \(argv), sensitiveStdin: \(stdinDescription))"
    }

    public var debugDescription: String { description }
}

// MARK: - HelperRestoreArgs

/// The app-side parameters of a `restore` invocation. Deliberately *not*
/// `RestoreRequest` (Core's engine-side type): that one is scoped to a set
/// already resolved by the caller and carries no `setId`, whereas the CLI
/// needs both ids on the command line.
public struct HelperRestoreArgs: Equatable, Sendable {
    public let setId: UUID
    public let destId: UUID
    public let snapshotID: String
    /// Filesystem path to restore *into* (`--target`).
    public let targetPath: String
    /// **In-snapshot** path (`--sub`); `nil` restores the whole snapshot.
    public let subpath: String?
    /// Repeatable `--include` patterns.
    public let includes: [String]
    /// `nil` = restic's own default (`always`) — the flag is omitted.
    public let overwriteMode: ResticCommand.OverwriteMode?

    public init(
        setId: UUID,
        destId: UUID,
        snapshotID: String,
        targetPath: String,
        subpath: String? = nil,
        includes: [String] = [],
        overwriteMode: ResticCommand.OverwriteMode? = nil
    ) {
        self.setId = setId
        self.destId = destId
        self.snapshotID = snapshotID
        self.targetPath = targetPath
        self.subpath = subpath
        self.includes = includes
        self.overwriteMode = overwriteMode
    }
}

// MARK: - Exit codes

/// The helper's exit-code contract (`docs/tasks/T10-helper-cli.md`, echoed
/// in `HelperMain`'s abstract): 0 ok, 1 error, 2 busy, 3 offline.
public enum HelperExitCode: Int32, Sendable, CaseIterable {
    case ok = 0
    case error = 1
    case busy = 2
    /// `probe-repo` and `purge preview`: the destination is not reachable
    /// right now. Not an error — the expected state of an unplugged external
    /// drive.
    case offline = 3

    /// Maps a raw process exit status onto the contract. Any code outside
    /// the contract (ArgumentParser's own usage errors, a crash's `128+n`,
    /// …) is a failure — never silently treated as success.
    ///
    /// - Important: callers must first check that the process actually
    ///   *exited* rather than being killed by a signal. On Darwin a
    ///   signalled `Process` reports the signal number in
    ///   `terminationStatus`, so a `SIGINT`-killed helper would otherwise
    ///   be misread as exit 2 ("busy"). `HelperInvoker` does this check.
    public static func interpret(_ code: Int32) -> HelperResultKind {
        switch HelperExitCode(rawValue: code) {
        case .ok: return .ok
        case .busy: return .busy
        case .offline: return .offline
        case .error, nil: return .failed
        }
    }
}

/// The outcome classes a helper invocation can land in — the pure half of
/// the App's `HelperResult` (which additionally carries captured output).
public enum HelperResultKind: Equatable, Sendable, CaseIterable {
    case ok
    case busy
    case offline
    case failed
}

// MARK: - Scheduler vocabulary
//
// `LaunchctlCommand` used to live here. It now sits in `SchedulerCommand.swift`
// next to its Linux counterpart `SystemdCommand`, both conditionally compiled:
// everything in *this* file is portable (the helper's own argv is identical on
// every platform), whereas how the tick gets *fired* is not.
