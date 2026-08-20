import Foundation
import Testing
@testable import ResticStationCore

// Exact-argv coverage for `HelperCommand`, per `docs/tasks/T11-launchd.md`
// ("`argv(for:)` unit-tested for every helper action (exact strings)").
//
// These assertions are the ONLY place the app's spawn strings are checked
// against the helper's parser: the two live in different targets and meet
// only across `execve`, so a typo is a runtime bug the compiler cannot see.
// Every expectation below is therefore quoted from the merged helper's
// declarations (T10, `Helper/Sources/Commands/`):
//
//   Tick.swift          commandName: "tick"
//   RunSet.swift        commandName: "run-set"
//                       @Option(name: .long) var set: UUID          → --set
//                       @Option(name: .long) var kind: Kind = .backup → --kind
//                       enum Kind: String { case backup, check, prune }
//   InitSecondary.swift commandName: "init-secondary"
//                       @Option(name: .long) var set: UUID          → --set
//                       @Option(name: .long) var dest: UUID         → --dest
//   ProbeRepo.swift     commandName: "probe-repo"   (--set, --dest)
//   Unlock.swift        commandName: "unlock"       (--set, --dest)
//   Restore.swift       commandName: "restore"
//                       @Option(name: .long) var set: UUID          → --set
//                       @Option(name: .long) var dest: UUID         → --dest
//                       @Option(name: .long) var snapshot: String   → --snapshot
//                       @Option(name: .long) var target: String     → --target
//                       @Option(name: .long) var sub: String?       → --sub
//                       @Option(name: .long) var include: [String]  → --include (repeatable)
//                       @Option(name: .long) var overwrite: ResticCommand.OverwriteMode?
//                                                                   → --overwrite
//   FdaCheck.swift      commandName: "fda-check"
//                       @Option(name: .long) var context: String = "launchd" → --context
//   Version.swift       commandName: "version"
//
// `@Option(name: .long)` means the long spelling only (`--set`, never
// `-s`), and the value is a separate argv element.

private let setId = UUID(uuidString: "6B29FC40-CA47-1067-B31D-00DD010662DA")!
private let destId = UUID(uuidString: "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B")!

@Suite struct HelperCommandArgvTests {
    @Test func tick() {
        #expect(HelperCommand.tick.argv == ["tick"])
    }

    @Test func version() {
        #expect(HelperCommand.version.argv == ["version"])
    }

    /// "Back Up Now" — `--kind backup` is passed explicitly even though the
    /// helper defaults to it (see `HelperCommand.runSet`'s comment).
    @Test func backUpNow() {
        var expected = ["run-set", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--kind", "backup"])
        #expect(HelperCommand.backUpNow(setId: setId).argv == expected)
    }

    @Test func prune() {
        var expected = ["run-set", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--kind", "prune"])
        #expect(HelperCommand.prune(setId: setId).argv == expected)
    }

    @Test func check() {
        var expected = ["run-set", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--kind", "check"])
        #expect(HelperCommand.check(setId: setId).argv == expected)
    }

    @Test func maintenancePrune() {
        #expect(
            HelperCommand.maintenancePrune(
                setId: setId,
                destId: destId,
                expectedRepository: "/Volumes/Backups/projects.restic",
                dryRun: true
            ).argv
                == ["maintenance", "prune", "--set", "6B29FC40-CA47-1067-B31D-00DD010662DA", "--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B", "--expected-repo", "/Volumes/Backups/projects.restic", "--dry-run"]
        )
        #expect(
            HelperCommand.maintenancePrune(setId: setId, destId: nil, expectedRepository: nil, dryRun: false).argv
                == ["maintenance", "prune", "--set", "6B29FC40-CA47-1067-B31D-00DD010662DA"]
        )
    }

    @Test func initSecondary() {
        var expected = ["init-secondary", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B"])
        #expect(HelperCommand.initSecondary(setId: setId, destId: destId).argv == expected)
    }

    @Test func probeRepo() {
        var expected = ["probe-repo", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B"])
        #expect(HelperCommand.probeRepo(setId: setId, destId: destId).argv == expected)
    }

    /// The Maintenance screen's "Remove stale locks" footer utility (T17).
    /// Same `--set`/`--dest` shape as `probe-repo`/`init-secondary`, and —
    /// unlike them — deliberately paired with a helper subcommand that
    /// writes no run record (see `Helper/Sources/Commands/Unlock.swift`).
    @Test func unlock() {
        var expected = ["unlock", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B"])
        #expect(HelperCommand.unlock(setId: setId, destId: destId).argv == expected)
    }

    /// `unlock` must never be spelled as a `run-set --kind`: there is no such
    /// kind, and inventing one would be an off-contract argv the helper's
    /// parser rejects with a usage error at runtime.
    @Test func unlockIsItsOwnSubcommand() {
        let argv = HelperCommand.unlock(setId: setId, destId: destId).argv
        #expect(HelperCommand.unlock(setId: setId, destId: destId).subcommandName == "unlock")
        #expect(!argv.contains("run-set"))
        #expect(!argv.contains("--kind"))
    }

    /// The app spawns `fda-check` with its own context label so the
    /// resulting `state/fda-check.json` is distinguishable from the
    /// launchd-context probe (`docs/keychain-and-fda.md` §2 shows both as
    /// separate badges). The helper's own default is `launchd`.
    @Test(arguments: ["app-spawned", "launchd", "app"])
    func fdaCheck(context: String) {
        #expect(HelperCommand.fdaCheck(context: context).argv == ["fda-check", "--context", context])
    }

    /// Every case's first element must be a real subcommand of
    /// `HelperMain` — a guard against a subcommand rename landing on one
    /// side only.
    @Test func everySubcommandNameIsRegistered() {
        let registered: Set<String> = [
            "tick", "run-set", "maintenance", "init-secondary", "restore", "probe-repo", "unlock", "fda-check", "version",
        ]
        let restoreArgs = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "abc123",
            targetPath: "/tmp/target"
        )
        let all: [HelperCommand] = [
            .tick,
            .backUpNow(setId: setId),
            .prune(setId: setId),
            .check(setId: setId),
            .maintenancePrune(setId: setId, destId: destId, expectedRepository: nil, dryRun: true),
            .initSecondary(setId: setId, destId: destId),
            .probeRepo(setId: setId, destId: destId),
            .unlock(setId: setId, destId: destId),
            .restore(restoreArgs),
            .fdaCheck(context: "app-spawned"),
            .version,
        ]
        for command in all {
            #expect(registered.contains(command.subcommandName), "unknown subcommand \(command.subcommandName)")
            #expect(!command.argv.isEmpty)
        }
    }
}

// MARK: - restore

@Suite struct HelperCommandRestoreArgvTests {
    /// Minimal restore: no `--sub`, no `--include`, no `--overwrite`
    /// (omitting `--overwrite` leaves restic's own default, `always`).
    @Test func minimal() {
        let args = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "9f1b2c3d",
            targetPath: "/Users/me/Restored"
        )
        var expected = ["restore", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B"])
        expected.append(contentsOf: ["--snapshot", "9f1b2c3d"])
        expected.append(contentsOf: ["--target", "/Users/me/Restored"])
        #expect(HelperCommand.restore(args).argv == expected)
    }

    /// Full restore: option order is the helper's declaration order, and
    /// each `--include` is repeated (ArgumentParser array options take one
    /// value per flag occurrence).
    @Test func full() {
        let args = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "latest",
            targetPath: "/Volumes/Restore Target",
            subpath: "/Users/me/Documents",
            includes: ["*.txt", "notes/**"],
            overwriteMode: .ifNewer
        )
        var expected = ["restore", "--set"]
        expected.append("6B29FC40-CA47-1067-B31D-00DD010662DA")
        expected.append(contentsOf: ["--dest", "0B7A50D4-9C3E-4F5B-9A0E-8E1F2C3D4A5B"])
        expected.append(contentsOf: ["--snapshot", "latest"])
        expected.append(contentsOf: ["--target", "/Volumes/Restore Target"])
        expected.append(contentsOf: ["--sub", "/Users/me/Documents"])
        expected.append(contentsOf: ["--include", "*.txt"])
        expected.append(contentsOf: ["--include", "notes/**"])
        expected.append(contentsOf: ["--overwrite", "if-newer"])
        #expect(HelperCommand.restore(args).argv == expected)
    }

    /// The wire spelling of every overwrite mode is its Core `rawValue`
    /// (`ResticCommand.OverwriteMode`), which the helper parses back with
    /// the default `RawRepresentable` `init(argument:)` — so
    /// `--overwrite if-changed`, never `--overwrite ifChanged`.
    @Test(arguments: ResticCommand.OverwriteMode.allCases)
    func overwriteModeSpelling(mode: ResticCommand.OverwriteMode) {
        let args = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "s",
            targetPath: "/t",
            overwriteMode: mode
        )
        let argv = HelperCommand.restore(args).argv
        let tail: [String] = Array(argv.suffix(2))
        var expectedTail = ["--overwrite"]
        expectedTail.append(mode.rawValue)
        #expect(tail == expectedTail)
        #expect(ResticCommand.OverwriteMode(rawValue: mode.rawValue) == mode)
    }

    @Test func overwriteModeRawValues() {
        #expect(ResticCommand.OverwriteMode.always.rawValue == "always")
        #expect(ResticCommand.OverwriteMode.ifChanged.rawValue == "if-changed")
        #expect(ResticCommand.OverwriteMode.ifNewer.rawValue == "if-newer")
        #expect(ResticCommand.OverwriteMode.never.rawValue == "never")
    }

    /// A path with spaces is one argv element — never shell-quoted or
    /// escaped, because there is no shell: `Process` passes the array
    /// straight to `execve`.
    @Test func pathsAreNotShellEscaped() {
        let args = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "s",
            targetPath: "/Volumes/My Drive/A B",
            subpath: "/Users/me/My Docs"
        )
        let argv = HelperCommand.restore(args).argv
        #expect(argv.contains("/Volumes/My Drive/A B"))
        #expect(argv.contains("/Users/me/My Docs"))
        #expect(!argv.contains(where: { $0.contains("\\") || $0.contains("\"") }))
    }

    @Test func emptyIncludesEmitNoFlag() {
        let args = HelperRestoreArgs(
            setId: setId,
            destId: destId,
            snapshotID: "s",
            targetPath: "/t",
            includes: []
        )
        #expect(!HelperCommand.restore(args).argv.contains("--include"))
        #expect(!HelperCommand.restore(args).argv.contains("--sub"))
        #expect(!HelperCommand.restore(args).argv.contains("--overwrite"))
    }
}

// MARK: - Exit codes

@Suite struct HelperExitCodeTests {
    /// The contract from `docs/tasks/T10-helper-cli.md` / `HelperMain`'s
    /// abstract: 0 ok, 1 error, 2 busy, 3 offline.
    @Test func rawValues() {
        #expect(HelperExitCode.ok.rawValue == 0)
        #expect(HelperExitCode.error.rawValue == 1)
        #expect(HelperExitCode.busy.rawValue == 2)
        #expect(HelperExitCode.offline.rawValue == 3)
    }

    @Test(arguments: [
        (Int32(0), HelperResultKind.ok),
        (Int32(1), HelperResultKind.failed),
        (Int32(2), HelperResultKind.busy),
        (Int32(3), HelperResultKind.offline),
    ])
    func interpretsContractCodes(code: Int32, expected: HelperResultKind) {
        #expect(HelperExitCode.interpret(code) == expected)
    }

    /// Anything off-contract is a failure, never a silent success:
    /// ArgumentParser's usage error (64), a signal-crash's 128+n, and the
    /// `-1`/255 shapes a launch failure can produce.
    @Test(arguments: [Int32(4), Int32(64), Int32(127), Int32(137), Int32(255), Int32(-1)])
    func interpretsUnknownCodesAsFailure(code: Int32) {
        #expect(HelperExitCode.interpret(code) == .failed)
    }
}
