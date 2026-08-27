import Foundation
import Testing
@testable import ResticStationCore

/// Golden-argv tests. Each test quotes the argv line from
/// `docs/restic-cli.md` §Commands verbatim in a comment directly above the
/// expectation, so a reviewer can diff the two side by side.
@Suite("ResticCommand golden argv (docs/restic-cli.md §Commands)")
struct ResticCommandTests {
    private static let repo = "/Volumes/Backup/primary"
    private static let secondary = "s3:https://acct.r2.cloudflarestorage.com/bucket/prefix"

    // MARK: - init

    @Test("init (primary)")
    func initRepo() {
        // restic -r <repo> init --json
        let cmd = ResticCommand.initRepo(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "init", "--json"])
        #expect(cmd.repoURL == Self.repo)
        #expect(cmd.fromRepoURL == nil)
    }

    @Test("init (secondary, shared chunker)")
    func initSecondary() {
        // restic -r <secondaryRepo> init --json --from-repo <primaryRepo> --copy-chunker-params
        let cmd = ResticCommand.initSecondary(repo: Self.secondary, fromRepo: Self.repo)
        #expect(cmd.argv == [
            "-r", Self.secondary, "init", "--json", "--from-repo", Self.repo, "--copy-chunker-params",
        ])
        #expect(cmd.repoURL == Self.secondary)
        #expect(cmd.fromRepoURL == Self.repo)
    }

    // MARK: - backup / copy

    @Test("backup with no excludes")
    func backupPlain() {
        // restic -r <primaryRepo> backup --json [--exclude <pat>]... <source>...
        let cmd = ResticCommand.backup(repo: Self.repo, sources: ["/Users/user/Documents"])
        #expect(cmd.argv == ["-r", Self.repo, "backup", "--json", "/Users/user/Documents"])
    }

    @Test("backup with excludes preserves flag order: excludes before sources")
    func backupWithExcludes() {
        // restic -r <primaryRepo> backup --json [--exclude <pat>]... <source>...
        let cmd = ResticCommand.backup(
            repo: Self.repo,
            sources: ["/Users/user/Documents", "/Users/user/Code"],
            excludes: ["*.tmp", "node_modules"]
        )
        #expect(cmd.argv == [
            "-r", Self.repo, "backup", "--json",
            "--exclude", "*.tmp",
            "--exclude", "node_modules",
            "/Users/user/Documents", "/Users/user/Code",
        ])
    }

    @Test("copy: -r is the destination, --from-repo the source, and there is no --json")
    func copy() {
        // restic -r <secondaryRepo> copy --from-repo <primaryRepo>
        let cmd = ResticCommand.copy(toRepo: Self.secondary, fromRepo: Self.repo)
        #expect(cmd.argv == ["-r", Self.secondary, "copy", "--from-repo", Self.repo])
        #expect(!cmd.argv.contains("--json"))
        #expect(cmd.repoURL == Self.secondary)
        #expect(cmd.fromRepoURL == Self.repo)
    }

    @Test("copy appends an exact purge output generation")
    func copyExactSnapshotGeneration() {
        let cmd = ResticCommand.copy(
            toRepo: Self.secondary,
            fromRepo: Self.repo,
            snapshotIDs: ["14a53542", "3ca2e0a5"]
        )
        #expect(cmd.argv == [
            "-r", Self.secondary, "copy", "--from-repo", Self.repo,
            "14a53542", "3ca2e0a5",
        ])
    }

    // MARK: - Read-only queries

    @Test("snapshots")
    func snapshots() {
        // restic -r <repo> snapshots --json
        let cmd = ResticCommand.snapshots(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "snapshots", "--json"])
    }

    @Test("rewrite dry-run: forget/dry-run before repeated excludes and explicit ids")
    func rewriteDryRun() {
        // restic -r <repo> rewrite [--forget] [--dry-run] [--exclude <pat>]... <id>...
        let cmd = ResticCommand.rewrite(
            repo: Self.repo,
            snapshotIDs: ["09b3295c", "b2435423"],
            excludes: ["build/**"],
            dryRun: true
        )
        #expect(cmd.argv == [
            "-r", Self.repo, "rewrite", "--dry-run", "--exclude", "build/**",
            "09b3295c", "b2435423",
        ])
        #expect(cmd.repoURL == Self.repo)
    }

    @Test("rewrite apply: explicit forget flag is before dry-run and excludes")
    func rewriteForget() {
        let cmd = ResticCommand.rewrite(
            repo: Self.repo,
            snapshotIDs: ["09b3295c"],
            excludes: ["build/**", "*.tmp"],
            forget: true
        )
        #expect(cmd.argv == [
            "-r", Self.repo, "rewrite", "--forget",
            "--exclude", "build/**", "--exclude", "*.tmp", "09b3295c",
        ])
    }

    @Test("standalone prune")
    func prune() {
        // restic -r <repo> prune [--dry-run]
        #expect(ResticCommand.prune(repo: Self.repo, dryRun: true).argv == [
            "-r", Self.repo, "prune", "--dry-run",
        ])
    }

    @Test("ls with a directory argument")
    func lsWithPath() {
        // restic -r <repo> ls --json <snapshotID> <dir>
        let cmd = ResticCommand.ls(repo: Self.repo, snapshotID: "e9ffc5cb", path: "/src")
        #expect(cmd.argv == ["-r", Self.repo, "ls", "--json", "e9ffc5cb", "/src"])
    }

    @Test("ls without a directory argument (recursive whole-snapshot listing)")
    func lsWithoutPath() {
        // restic -r <repo> ls --json <snapshotID>
        let cmd = ResticCommand.ls(repo: Self.repo, snapshotID: "e9ffc5cb")
        #expect(cmd.argv == ["-r", Self.repo, "ls", "--json", "e9ffc5cb"])
    }

    @Test("find across all snapshots")
    func findAllSnapshots() {
        // restic -r <repo> find --json <pattern>
        let cmd = ResticCommand.find(repo: Self.repo, pattern: "file2*")
        #expect(cmd.argv == ["-r", Self.repo, "find", "--json", "file2*"])
    }

    @Test("find restricted to one snapshot")
    func findOneSnapshot() {
        // restic -r <repo> find --json --snapshot <id> <pattern>
        let cmd = ResticCommand.find(repo: Self.repo, pattern: "file2*", snapshotID: "e9ffc5cb")
        #expect(cmd.argv == ["-r", Self.repo, "find", "--json", "--snapshot", "e9ffc5cb", "file2*"])
    }

    @Test("stats raw-data mode")
    func statsRawData() {
        // restic -r <repo> stats --json --mode raw-data
        let cmd = ResticCommand.stats(repo: Self.repo, mode: .rawData)
        #expect(cmd.argv == ["-r", Self.repo, "stats", "--json", "--mode", "raw-data"])
    }

    @Test("stats default mode (restore-size) passes no --mode")
    func statsDefaultMode() {
        // restic -r <repo> stats --json
        let cmd = ResticCommand.stats(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "stats", "--json"])
    }

    @Test("stats restore-size mode when requested explicitly")
    func statsRestoreSize() {
        let cmd = ResticCommand.stats(repo: Self.repo, mode: .restoreSize)
        #expect(cmd.argv == ["-r", Self.repo, "stats", "--json", "--mode", "restore-size"])
    }

    @Test("cat config: no --json (already JSON; restic-cli.md §version / cat config)")
    func catConfig() {
        // restic -r <repo> cat config
        let cmd = ResticCommand.catConfig(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "cat", "config"])
        #expect(!cmd.argv.contains("--json"))
    }

    @Test("version takes no repository")
    func version() {
        // restic version --json
        let cmd = ResticCommand.version
        #expect(cmd.argv == ["version", "--json"])
        #expect(cmd.repoURL == nil)
    }

    // MARK: - forget

    @Test("forget maps every non-nil RetentionPolicy field, in restic-cli.md's flag order")
    func forgetFullPolicy() {
        // restic -r <repo> forget --json [--keep-last N] [--keep-hourly N] [--keep-daily N]
        //   [--keep-weekly N] [--keep-monthly N] [--keep-yearly N] [--prune] [--dry-run]
        let policy = RetentionPolicy(
            keepLast: 3,
            keepHourly: 24,
            keepDaily: 7,
            keepWeekly: 5,
            keepMonthly: 12,
            keepYearly: 3
        )
        let cmd = ResticCommand.forget(repo: Self.repo, policy: policy, prune: true, dryRun: true)
        #expect(cmd.argv == [
            "-r", Self.repo, "forget", "--json",
            "--keep-last", "3",
            "--keep-hourly", "24",
            "--keep-daily", "7",
            "--keep-weekly", "5",
            "--keep-monthly", "12",
            "--keep-yearly", "3",
            "--prune",
            "--dry-run",
        ])
    }

    @Test("forget skips nil retention fields and omits --prune/--dry-run by default")
    func forgetSparsePolicy() {
        let cmd = ResticCommand.forget(
            repo: Self.repo,
            policy: RetentionPolicy(keepLast: 2, keepMonthly: 6)
        )
        #expect(cmd.argv == [
            "-r", Self.repo, "forget", "--json",
            "--keep-last", "2",
            "--keep-monthly", "6",
        ])
    }

    @Test("forget --dry-run only (UI preview)")
    func forgetDryRunOnly() {
        let cmd = ResticCommand.forget(repo: Self.repo, policy: RetentionPolicy(keepLast: 2), dryRun: true)
        #expect(cmd.argv == ["-r", Self.repo, "forget", "--json", "--keep-last", "2", "--dry-run"])
    }

    // Note: `forget` with an empty policy is a `precondition` failure (it
    // traps rather than throwing), which Swift Testing cannot catch in-process
    // — the guarantee is asserted by construction plus the engine-side check
    // (T09). `RetentionPolicy.isEmpty` itself is covered in Config/ModelsTests.

    // MARK: - check

    @Test("check without --read-data-subset, and no --json")
    func checkPlain() {
        // restic -r <repo> check
        let cmd = ResticCommand.check(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "check"])
        #expect(!cmd.argv.contains("--json"))
    }

    @Test("check --read-data-subset uses the =n/t form as one argv element")
    func checkSubset() {
        // restic -r <repo> check --read-data-subset=<n>/<t>
        let cmd = ResticCommand.check(repo: Self.repo, readDataSubset: "3/20")
        #expect(cmd.argv == ["-r", Self.repo, "check", "--read-data-subset=3/20"])
    }

    // MARK: - restore

    @Test("restore of a whole snapshot")
    func restoreWholeSnapshot() {
        // restic -r <repo> restore --json "<snapshotID>" --target <dir>
        let cmd = ResticCommand.restore(repo: Self.repo, snapshotID: "e9ffc5cb", target: "/tmp/out")
        #expect(cmd.argv == ["-r", Self.repo, "restore", "--json", "e9ffc5cb", "--target", "/tmp/out"])
    }

    @Test("restore with subpath, includes, overwrite and dry-run")
    func restoreFullyLoaded() {
        // restic -r <repo> restore --json "<snapshotID>:<in-snapshot-subpath>" --target <dir>
        //   [--include <pat>]... [--overwrite always|if-changed|if-newer|never] [--dry-run]
        let cmd = ResticCommand.restore(
            repo: Self.repo,
            snapshotID: "e9ffc5cb",
            subpath: "/src/subdir",
            target: "/tmp/out",
            includes: ["*.txt", "*.dat"],
            overwrite: .ifNewer,
            dryRun: true
        )
        #expect(cmd.argv == [
            "-r", Self.repo, "restore", "--json",
            "e9ffc5cb:/src/subdir",
            "--target", "/tmp/out",
            "--include", "*.txt",
            "--include", "*.dat",
            "--overwrite", "if-newer",
            "--dry-run",
        ])
    }

    @Test("every documented --overwrite value maps to its restic spelling", arguments: [
        (ResticCommand.OverwriteMode.always, "always"),
        (.ifChanged, "if-changed"),
        (.ifNewer, "if-newer"),
        (.never, "never"),
    ])
    func overwriteModes(mode: ResticCommand.OverwriteMode, expected: String) {
        #expect(mode.rawValue == expected)
        let cmd = ResticCommand.restore(
            repo: Self.repo,
            snapshotID: "abc",
            target: "/tmp/out",
            overwrite: mode
        )
        #expect(cmd.argv.suffix(2) == ["--overwrite", expected])
    }

    // MARK: - mount / unlock

    @Test("mount")
    func mount() {
        // restic -r <repo> mount <emptyDir>
        let cmd = ResticCommand.mount(repo: Self.repo, mountpoint: "/tmp/mnt")
        #expect(cmd.argv == ["-r", Self.repo, "mount", "/tmp/mnt"])
        #expect(!cmd.argv.contains("--json"))
    }

    @Test("unlock")
    func unlock() {
        // restic -r <repo> unlock
        let cmd = ResticCommand.unlock(repo: Self.repo)
        #expect(cmd.argv == ["-r", Self.repo, "unlock"])
        #expect(!cmd.argv.contains("--json"))
    }

    // MARK: - Cross-cutting invariants

    @Test("--no-lock is never passed (restic-cli.md §General)")
    func neverNoLock() {
        let policy = RetentionPolicy(keepLast: 1)
        let commands: [ResticCommand] = [
            .initRepo(repo: Self.repo),
            .initSecondary(repo: Self.secondary, fromRepo: Self.repo),
            .backup(repo: Self.repo, sources: ["/a"], excludes: ["b"]),
            .copy(toRepo: Self.secondary, fromRepo: Self.repo),
            .snapshots(repo: Self.repo),
            .ls(repo: Self.repo, snapshotID: "id", path: "/"),
            .find(repo: Self.repo, pattern: "p", snapshotID: "id"),
            .stats(repo: Self.repo, mode: .rawData),
            .forget(repo: Self.repo, policy: policy, prune: true, dryRun: false),
            .check(repo: Self.repo, readDataSubset: "1/20"),
            .restore(repo: Self.repo, snapshotID: "id", subpath: "/s", target: "/t"),
            .mount(repo: Self.repo, mountpoint: "/mnt"),
            .catConfig(repo: Self.repo),
            .unlock(repo: Self.repo),
            .version,
        ]
        for cmd in commands {
            #expect(!cmd.argv.contains("--no-lock"))
        }
    }

    @Test("every repository-targeting command selects the repo with an explicit -r as argv[0..1]")
    func explicitRepositorySelector() {
        let policy = RetentionPolicy(keepLast: 1)
        let commands: [ResticCommand] = [
            .initRepo(repo: Self.repo),
            .initSecondary(repo: Self.repo, fromRepo: Self.secondary),
            .backup(repo: Self.repo, sources: ["/a"]),
            .copy(toRepo: Self.repo, fromRepo: Self.secondary),
            .snapshots(repo: Self.repo),
            .ls(repo: Self.repo, snapshotID: "id"),
            .find(repo: Self.repo, pattern: "p"),
            .stats(repo: Self.repo),
            .forget(repo: Self.repo, policy: policy),
            .check(repo: Self.repo),
            .restore(repo: Self.repo, snapshotID: "id", target: "/t"),
            .mount(repo: Self.repo, mountpoint: "/mnt"),
            .catConfig(repo: Self.repo),
            .unlock(repo: Self.repo),
        ]
        for cmd in commands {
            #expect(Array(cmd.argv.prefix(2)) == ["-r", Self.repo])
            #expect(cmd.repoURL == Self.repo)
        }
    }
}
