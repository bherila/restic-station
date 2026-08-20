import Foundation

/// One restic invocation, described as data.
///
/// `argv` is everything that follows the restic binary path — including the
/// `-r <repo>` selector and (where applicable) `--from-repo <repo>` — so a
/// full command line is exactly `[resticPath] + cmd.argv`. `ResticRunner`
/// prepends the binary path; nothing else rewrites `argv`.
///
/// Every builder below reproduces the argv shown in `docs/restic-cli.md`
/// §Commands **in the order shown there** (the golden tests in
/// `ResticCommandTests` quote that document line by line). Two invariants
/// matter for review:
///
/// 1. **No secrets in argv.** Repository URLs, paths and retention numbers
///    only; the repo password reaches restic via `RESTIC_PASSWORD_COMMAND`
///    and cloud credentials via the keychain env blob (see `ResticRunner`).
///    argv is therefore safe to write verbatim into run logs.
/// 2. **`--json` policy.** `docs/restic-cli.md` §General says to add `--json`
///    to every command that supports it. `copy`, `check`, `unlock` and
///    `mount` have no JSON mode in restic 0.18, and `cat config` already
///    prints JSON and is documented (§version / cat config) with the literal
///    argv `restic -r <repo> cat config` — so those five carry no `--json`.
///    (`docs/tasks/T04-restic-runner.md` lists only the first four
///    exceptions; the argv in `restic-cli.md` is normative and wins.)
public struct ResticCommand: Equatable, Sendable {
    /// Arguments after the binary path, e.g. `["-r", "/repo", "init", "--json"]`.
    public let argv: [String]
    /// The `-r` repository, when the command targets one (`version` does not).
    public let repoURL: String?
    /// The `--from-repo` repository, when the command reads from a second
    /// repository (`copy`, `init --from-repo`).
    public let fromRepoURL: String?

    /// Prefer the static builders below; this initializer exists for tests
    /// and for callers that must construct an argv restic-cli.md does not
    /// cover yet.
    public init(argv: [String], repoURL: String? = nil, fromRepoURL: String? = nil) {
        self.argv = argv
        self.repoURL = repoURL
        self.fromRepoURL = fromRepoURL
    }

    // MARK: - Option types

    /// `restic stats --mode <value>`. `nil` mode = restic's default
    /// (`restore-size`), matching `restic -r <repo> stats --json`.
    public enum StatsMode: String, Equatable, Sendable, CaseIterable {
        /// Actual repository disk usage.
        case rawData = "raw-data"
        /// Logical size of the protected data.
        case restoreSize = "restore-size"
    }

    /// `restic restore --overwrite <value>`. `nil` = restic's default
    /// (`always`).
    public enum OverwriteMode: String, Equatable, Sendable, CaseIterable {
        case always
        case ifChanged = "if-changed"
        case ifNewer = "if-newer"
        case never
    }

    // MARK: - init

    /// `restic -r <repo> init --json`
    public static func initRepo(repo: String) -> ResticCommand {
        ResticCommand(argv: ["-r", repo, "init", "--json"], repoURL: repo)
    }

    /// `restic -r <secondaryRepo> init --json --from-repo <primaryRepo> --copy-chunker-params`
    ///
    /// `--copy-chunker-params` is non-negotiable: without it deduplication
    /// between primary and mirror is destroyed (restic-cli.md §init secondary).
    public static func initSecondary(repo: String, fromRepo: String) -> ResticCommand {
        ResticCommand(
            argv: ["-r", repo, "init", "--json", "--from-repo", fromRepo, "--copy-chunker-params"],
            repoURL: repo,
            fromRepoURL: fromRepo
        )
    }

    // MARK: - backup / copy

    /// `restic -r <primaryRepo> backup --json [--exclude <pat>]... <source>...`
    ///
    /// Sources must be absolute paths (enforced by `AppConfig.validate()`).
    public static func backup(repo: String, sources: [String], excludes: [String] = []) -> ResticCommand {
        precondition(!sources.isEmpty, "ResticCommand.backup requires at least one source path")
        var argv = ["-r", repo, "backup", "--json"]
        for exclude in excludes {
            argv.append("--exclude")
            argv.append(exclude)
        }
        argv.append(contentsOf: sources)
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <secondaryRepo> copy --from-repo <primaryRepo>`
    ///
    /// Direction: `-r` is the DESTINATION, `--from-repo` is the SOURCE
    /// (restic-cli.md §copy). No `--json` — `copy` has no JSON mode in 0.18.
    public static func copy(toRepo: String, fromRepo: String) -> ResticCommand {
        ResticCommand(
            argv: ["-r", toRepo, "copy", "--from-repo", fromRepo],
            repoURL: toRepo,
            fromRepoURL: fromRepo
        )
    }

    // MARK: - Read-only queries

    /// `restic -r <repo> snapshots --json`
    public static func snapshots(repo: String) -> ResticCommand {
        ResticCommand(argv: ["-r", repo, "snapshots", "--json"], repoURL: repo)
    }

    /// `restic -r <repo> rewrite [--forget] [--dry-run] [--exclude <pat>]... <snapshotID>...`
    ///
    /// Snapshot ids are deliberately required.  Without them restic rewrites
    /// every snapshot in the repository, which is never safe for a repository
    /// shared by more than one backup set.
    public static func rewrite(
        repo: String,
        snapshotIDs: [String],
        excludes: [String],
        forget: Bool = false,
        dryRun: Bool = false
    ) -> ResticCommand {
        precondition(!snapshotIDs.isEmpty, "ResticCommand.rewrite requires at least one snapshot ID")
        precondition(!excludes.isEmpty, "ResticCommand.rewrite requires at least one exclude pattern")
        var argv = ["-r", repo, "rewrite"]
        if forget { argv.append("--forget") }
        if dryRun { argv.append("--dry-run") }
        for exclude in excludes {
            argv.append("--exclude")
            argv.append(exclude)
        }
        argv.append(contentsOf: snapshotIDs)
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> prune [--dry-run]`
    public static func prune(repo: String, dryRun: Bool = false) -> ResticCommand {
        var argv = ["-r", repo, "prune"]
        if dryRun { argv.append("--dry-run") }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> ls --json <snapshotID> [<dir>]`
    ///
    /// `path` is an **in-snapshot** path (restic-cli.md §ls). Omitting it
    /// lists the whole snapshot recursively — callers browsing a tree always
    /// pass a path, starting at `/`.
    public static func ls(repo: String, snapshotID: String, path: String? = nil) -> ResticCommand {
        var argv = ["-r", repo, "ls", "--json", snapshotID]
        if let path {
            argv.append(path)
        }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> find --json [--snapshot <id>] <pattern>`
    ///
    /// Without `--snapshot`, restic searches every snapshot.
    public static func find(repo: String, pattern: String, snapshotID: String? = nil) -> ResticCommand {
        var argv = ["-r", repo, "find", "--json"]
        if let snapshotID {
            argv.append("--snapshot")
            argv.append(snapshotID)
        }
        argv.append(pattern)
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> stats --json [--mode <mode>]`
    public static func stats(repo: String, mode: StatsMode? = nil) -> ResticCommand {
        var argv = ["-r", repo, "stats", "--json"]
        if let mode {
            argv.append("--mode")
            argv.append(mode.rawValue)
        }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> cat config` — the cheap remote-reachability probe.
    /// Already prints JSON; documented without `--json` (see the type doc).
    public static func catConfig(repo: String) -> ResticCommand {
        ResticCommand(argv: ["-r", repo, "cat", "config"], repoURL: repo)
    }

    /// `restic version --json` — validates a discovered binary; takes no repo.
    public static var version: ResticCommand {
        ResticCommand(argv: ["version", "--json"])
    }

    // MARK: - forget / check / restore

    /// `restic -r <repo> forget --json [--keep-*]... [--prune] [--dry-run]`
    ///
    /// The only destructive command. **Precondition-fails on an empty
    /// policy** (restic-cli.md §forget: "refuse to run with an empty
    /// policy") — a programming error, and the second half of the double
    /// guard the engine implements (T09).
    public static func forget(
        repo: String,
        policy: RetentionPolicy,
        prune: Bool = false,
        dryRun: Bool = false
    ) -> ResticCommand {
        precondition(
            !policy.isEmpty,
            "ResticCommand.forget refuses an empty RetentionPolicy — see docs/restic-cli.md §forget"
        )
        var argv = ["-r", repo, "forget", "--json"]
        // Flag order mirrors restic-cli.md §forget.
        let keepFlags: [(String, Int?)] = [
            ("--keep-last", policy.keepLast),
            ("--keep-hourly", policy.keepHourly),
            ("--keep-daily", policy.keepDaily),
            ("--keep-weekly", policy.keepWeekly),
            ("--keep-monthly", policy.keepMonthly),
            ("--keep-yearly", policy.keepYearly),
        ]
        for (flag, value) in keepFlags {
            guard let value else { continue }
            argv.append(flag)
            argv.append(String(value))
        }
        if prune {
            argv.append("--prune")
        }
        if dryRun {
            argv.append("--dry-run")
        }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> check [--read-data-subset=<n>/<t>]`
    ///
    /// `readDataSubset` is the literal `"n/t"` string (rotation cursor lives
    /// in `state/schedule-state.json`). No JSON mode.
    public static func check(repo: String, readDataSubset: String? = nil) -> ResticCommand {
        var argv = ["-r", repo, "check"]
        if let readDataSubset {
            argv.append("--read-data-subset=\(readDataSubset)")
        }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    /// `restic -r <repo> restore --json <snapshotID[:subpath]> --target <dir>
    /// [--include <pat>]... [--overwrite <mode>] [--dry-run]`
    ///
    /// `subpath` is an **in-snapshot** path (restic-cli.md §restore); the
    /// `"<id>:<subpath>"` form is one argv element (the quotes in the doc are
    /// shell quoting).
    public static func restore(
        repo: String,
        snapshotID: String,
        subpath: String? = nil,
        target: String,
        includes: [String] = [],
        overwrite: OverwriteMode? = nil,
        dryRun: Bool = false
    ) -> ResticCommand {
        let snapshotArgument = subpath.map { "\(snapshotID):\($0)" } ?? snapshotID
        var argv = ["-r", repo, "restore", "--json", snapshotArgument, "--target", target]
        for include in includes {
            argv.append("--include")
            argv.append(include)
        }
        if let overwrite {
            argv.append("--overwrite")
            argv.append(overwrite.rawValue)
        }
        if dryRun {
            argv.append("--dry-run")
        }
        return ResticCommand(argv: argv, repoURL: repo)
    }

    // MARK: - mount / unlock

    /// `restic -r <repo> mount <emptyDir>` — blocks while mounted; no JSON.
    public static func mount(repo: String, mountpoint: String) -> ResticCommand {
        ResticCommand(argv: ["-r", repo, "mount", mountpoint], repoURL: repo)
    }

    /// `restic -r <repo> unlock` — removes only locks of dead processes, so
    /// it is safe to run automatically after an exit 11. No JSON.
    public static func unlock(repo: String) -> ResticCommand {
        ResticCommand(argv: ["-r", repo, "unlock"], repoURL: repo)
    }
}
