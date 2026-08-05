import Foundation
import Testing
@testable import ResticStationCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `docs/tasks/T28` (issue #30): the `restic-station` symlink installer.
/// Every test gets its own scratch directory under
/// `NSTemporaryDirectory()`, removed afterward — no `FileManager` fakes are
/// needed because the whole point under test is real symlink/POSIX
/// behavior (dangling symlinks, foreign files), which a fake would have to
/// reimplement and could silently drift from.
private func scratchDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-installer-test-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func withScratchDirectory(_ body: (URL) throws -> Void) rethrows {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private let bundleTarget = "/Applications/Restic Station.app/Contents/MacOS/restic-station-helper"
private let movedBundleTarget = "/Applications/Restic Station 2.app/Contents/MacOS/restic-station-helper"

@Suite struct CLIInstallerTests {

    // MARK: - install: fresh

    @Test func installCreatesASymlinkWhenNothingExists() throws {
        try withScratchDirectory { directory in
            let outcome = try CLIInstaller.install(target: bundleTarget, directory: directory)
            guard case .created(let linkPath) = outcome else {
                Issue.record("expected .created, got \(outcome)")
                return
            }
            #expect(linkPath == directory.appendingPathComponent("restic-station").path)
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == bundleTarget)
        }
    }

    /// Installing into a directory that does not exist yet creates it —
    /// this is what makes `--user` (`~/.local/bin`, which very often does
    /// not exist on a fresh machine) work without a separate `mkdir` step.
    @Test func installCreatesTheDirectoryIfMissing() throws {
        try withScratchDirectory { directory in
            let nested = directory.appendingPathComponent("nested/bin", isDirectory: true)
            _ = try CLIInstaller.install(target: bundleTarget, directory: nested)
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    // MARK: - install: idempotent

    @Test func installTwiceIsIdempotent() throws {
        try withScratchDirectory { directory in
            let first = try CLIInstaller.install(target: bundleTarget, directory: directory)
            guard case .created = first else {
                Issue.record("expected .created on first install, got \(first)")
                return
            }
            let second = try CLIInstaller.install(target: bundleTarget, directory: directory)
            guard case .alreadyInstalled(let linkPath) = second else {
                Issue.record("expected .alreadyInstalled on second install, got \(second)")
                return
            }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == bundleTarget)
        }
    }

    // MARK: - install: repair

    /// The "stale symlink of ours pointing at a moved bundle" case from the
    /// issue: a previous install pointed at one bundle location; the app
    /// moved (or was rebuilt at a new path); a second `install` must
    /// repoint the existing symlink rather than refuse or leave it stale.
    ///
    /// The old destination is deliberately scoped inside this test's own
    /// scratch directory rather than the literal `bundleTarget` constant:
    /// `isOwned`'s repair path (finding 1, PR #42 codex review) requires
    /// the *old* destination to not exist on disk, and a hardcoded
    /// `/Applications/Restic Station.app/...` string is not guaranteed to
    /// be absent — on a machine that actually has the real app installed
    /// there (e.g. after following this PR's own manual-verification
    /// steps), that path is real, and this test would wrongly see the old
    /// symlink as foreign instead of stale-and-ours. A path under the
    /// per-test scratch directory is guaranteed fresh and nonexistent.
    @Test func installRepairsAStaleSymlinkOfOurs() throws {
        try withScratchDirectory { directory in
            let oldTarget = directory.appendingPathComponent("old-bundle/restic-station-helper").path
            _ = try CLIInstaller.install(target: oldTarget, directory: directory)
            let outcome = try CLIInstaller.install(target: movedBundleTarget, directory: directory)
            guard case .repaired(let linkPath, let previousTarget) = outcome else {
                Issue.record("expected .repaired, got \(outcome)")
                return
            }
            #expect(previousTarget == oldTarget)
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == movedBundleTarget)
        }
    }

    /// Same repair path, but the old target no longer exists on disk at all
    /// (a genuinely dangling symlink) — must still be recognized as "ours"
    /// and repaired, not treated as an absent or foreign entry.
    @Test func installRepairsADanglingSymlinkOfOurs() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: "/does/not/exist/restic-station-helper"
            )
            let outcome = try CLIInstaller.install(target: bundleTarget, directory: directory)
            guard case .repaired = outcome else {
                Issue.record("expected .repaired, got \(outcome)")
                return
            }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == bundleTarget)
        }
    }

    // MARK: - install: refuse to clobber

    /// The refuse-to-clobber behavior the task calls out by name: a
    /// pre-existing, unrelated regular file at the link path must survive
    /// `install` untouched, and `install` must report an error rather than
    /// silently replacing it. Asserts on the file's actual byte contents
    /// afterward, not merely on the thrown error — a test that only checks
    /// "an error was thrown" could pass even if the file were deleted and
    /// the error came from somewhere else.
    @Test func installRefusesToClobberAForeignFile() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            let foreignContents = Data("#!/bin/sh\necho not restic-station\n".utf8)
            try foreignContents.write(to: URL(fileURLWithPath: linkPath))

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }

            // The file must be completely untouched: same contents, and
            // still a regular file (not a symlink).
            let survived = try Data(contentsOf: URL(fileURLWithPath: linkPath))
            #expect(survived == foreignContents)
            #expect(throws: Error.self) {
                try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            }
        }
    }

    /// A symlink at the link path pointing at something with a different
    /// name (not `restic-station-helper`) is foreign too — it did not come
    /// from this installer, however it got there.
    @Test func installRefusesToClobberAForeignSymlink() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/usr/bin/env")

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == "/usr/bin/env")
        }
    }

    /// PR #42 codex review finding: the ownership check used to compare
    /// only the *basename* of the symlink's destination, so a
    /// `restic-station` entry pointing at any other live executable named
    /// `restic-station-helper` — a second checkout, a duplicate app bundle,
    /// an unrelated install — was wrongly judged to be ours, and `install`
    /// would repoint it. `installRefusesToClobberAForeignSymlink` above
    /// never covered this: its foreign target (`/usr/bin/env`) has a
    /// *different* basename, so it never exercised the basename-only
    /// check that let this through. This test uses a foreign target that
    /// is real (exists on disk), a different path than `bundleTarget`, and
    /// named exactly `restic-station-helper` — the one input the old check
    /// could not tell apart from our own stale symlink.
    @Test func installRefusesToClobberAForeignSymlinkWithTheSameBasename() throws {
        try withScratchDirectory { directory in
            let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let foreignBinaryPath = elsewhere.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            try Data("#!/bin/sh\necho not restic-station\n".utf8).write(to: URL(fileURLWithPath: foreignBinaryPath))

            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: foreignBinaryPath)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            // Untouched: still points at the foreign binary, which still exists.
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == foreignBinaryPath)
            #expect(FileManager.default.fileExists(atPath: foreignBinaryPath))
        }
    }

    /// `status` must reach the same "foreign, not ours" conclusion as
    /// `install`/`uninstall` for the same-basename-but-different-live-path
    /// case — the three surfaces share `isOwned` and must not disagree.
    @Test func statusReportsForeignEntryForALiveSymlinkWithTheSameBasenameAtADifferentPath() throws {
        try withScratchDirectory { directory in
            let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let foreignBinaryPath = elsewhere.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            try Data("not ours".utf8).write(to: URL(fileURLWithPath: foreignBinaryPath))

            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: foreignBinaryPath)

            let status = CLIInstaller.status(directory: directory, currentTarget: bundleTarget, pathEnvironment: nil)
            #expect(!status.installed)
            #expect(status.foreignEntryPresent)
        }
    }

    // MARK: - ownership: relative destinations, loops, directories (merge blocker)
    //
    // `destinationOfSymbolicLink` returns a symlink's stored destination
    // string verbatim. When that string is *relative*
    // (`vendor/restic-station-helper`), resolving it with
    // `FileManager.fileExists(atPath:)` — as `isOwned` used to, unguarded —
    // resolves against the *process* current working directory, not the
    // symlink's own parent directory. A live, working *foreign* relative
    // symlink (the normal shape of a GNU-stow, nix/home-manager, or
    // hand-`ln -s`-managed entry) therefore looked dangling, `isOwned`
    // returned `true`, and `install`/`uninstall` would repoint or delete it.
    // These tests are the red-checked regression coverage for that finding
    // and its two adjacent, same-root-cause cases.

    /// The blocker itself. A live foreign symlink with a *relative*
    /// destination must never be treated as ours, in either direction.
    ///
    /// The relative destination is verified live *twice*, deliberately:
    /// once resolved against the link's own parent directory (the correct,
    /// shell/kernel interpretation — proves the foreign binary is real and
    /// reachable), matching the reviewer's proof that this is a live,
    /// working symlink and not merely a theoretical construction.
    @Test func installAndUninstallRefuseALiveRelativeForeignSymlink() throws {
        try withScratchDirectory { directory in
            // A UUID-namespaced relative component so this test's verdict
            // can never accidentally depend on whatever the test runner's
            // real process CWD happens to contain.
            let vendorName = "vendor-\(UUID().uuidString)"
            let relativeDestination = "\(vendorName)/\(CLIInstaller.ownedTargetBasename)"
            let vendorDirectory = directory.appendingPathComponent(vendorName, isDirectory: true)
            try FileManager.default.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
            let foreignBinaryPath = vendorDirectory.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            let foreignContents = Data("#!/bin/sh\necho not restic-station\n".utf8)
            try foreignContents.write(to: URL(fileURLWithPath: foreignBinaryPath))

            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: relativeDestination)

            // Prove liveness the correct way — resolved against the link's
            // own parent directory, not the process CWD.
            let resolvedForeignPath = directory.appendingPathComponent(relativeDestination).path
            #expect(FileManager.default.fileExists(atPath: resolvedForeignPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: resolvedForeignPath)) == foreignContents)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            // Untouched by the refused install: still a symlink, still
            // pointing at the same relative destination, foreign binary
            // survives byte-for-byte.
            let destinationAfterInstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterInstall == relativeDestination)
            #expect(try Data(contentsOf: URL(fileURLWithPath: foreignBinaryPath)) == foreignContents)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            // Untouched by the refused uninstall too: the symlink (and the
            // foreign binary it points at) both still exist.
            #expect(FileManager.default.fileExists(atPath: linkPath))
            let destinationAfterUninstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterUninstall == relativeDestination)
            #expect(try Data(contentsOf: URL(fileURLWithPath: foreignBinaryPath)) == foreignContents)
        }
    }

    /// Same relative-destination rule, but genuinely dangling (nothing at
    /// the other end even resolved from the link's own directory) — must
    /// still refuse rather than fall into the "our stale symlink, repair
    /// it" path. Only an *absolute* dangling destination is eligible for
    /// that repair (see `installRepairsADanglingSymlinkOfOurs`), because
    /// only an absolute destination could ever have been written by our own
    /// `install`.
    @Test func installAndUninstallRefuseADanglingRelativeSymlink() throws {
        try withScratchDirectory { directory in
            let relativeDestination = "does-not-exist-\(UUID().uuidString)/\(CLIInstaller.ownedTargetBasename)"
            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: relativeDestination)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            let destinationAfterInstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterInstall == relativeDestination)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            // `destinationOfSymbolicLink` throwing would itself prove the
            // symlink is gone; reaching this line at all is part of the
            // proof it survived. (Deliberately not also asserting
            // `FileManager.fileExists(atPath: linkPath)` here — `fileExists`
            // follows symlinks to their target by design, so it correctly
            // reports `false` for *any* dangling symlink regardless of
            // ownership; that is unrelated to what this test is checking.)
            let destinationAfterUninstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterUninstall == relativeDestination)
        }
    }

    /// The "related, same root cause" case named in the merge-blocker
    /// review: a two-link symlink loop
    /// (`restic-station -> x/restic-station-helper -> restic-station`).
    /// `stat` fails on a loop with `ELOOP`, which — like `ENOENT` — made
    /// `FileManager.fileExists` return `false`, so pre-fix this was judged
    /// "ours, dangling" and got repaired/removed. A loop is inert (nothing
    /// is reachable through it, so nothing of value would have been
    /// destroyed by the pre-fix behavior), but the decision made here is to
    /// refuse it anyway rather than adopt it: `isOwned`'s absolute-only
    /// guard already rejects this construction's relative first hop, and
    /// `pathIsDefinitelyAbsent` independently refuses to treat `ELOOP` as
    /// evidence of absence — so a loop is foreign, full stop, on two
    /// independent grounds.
    @Test func installAndUninstallRefuseARelativeSymlinkLoop() throws {
        try withScratchDirectory { directory in
            let hopDirectory = directory.appendingPathComponent("x", isDirectory: true)
            try FileManager.default.createDirectory(at: hopDirectory, withIntermediateDirectories: true)
            let hopPath = hopDirectory.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            let linkPath = directory.appendingPathComponent("restic-station").path

            // x/restic-station-helper -> ../restic-station
            try FileManager.default.createSymbolicLink(atPath: hopPath, withDestinationPath: "../restic-station")
            // restic-station -> x/restic-station-helper
            try FileManager.default.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: "x/\(CLIInstaller.ownedTargetBasename)"
            )

            // Confirm the loop is real: resolving it through `stat` fails
            // with ELOOP, not "no such file". (`FileManager.fileExists`
            // can't tell us which — that's the whole bug — so this reaches
            // for the POSIX call directly, matching what the fix's
            // `pathIsDefinitelyAbsent` now does internally.)
            var info = stat()
            let statResult = linkPath.withCString { stat($0, &info) }
            #expect(statResult == -1)
            #expect(errno == ELOOP)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            let destinationAfterInstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterInstall == "x/\(CLIInstaller.ownedTargetBasename)")

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            let destinationAfterUninstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterUninstall == "x/\(CLIInstaller.ownedTargetBasename)")
            // Both hops of the loop still stand — neither install nor
            // uninstall touched anything.
            let hopDestination = try FileManager.default.destinationOfSymbolicLink(atPath: hopPath)
            #expect(hopDestination == "../restic-station")
        }
    }

    /// A hypothetical *all-absolute* loop — a construction our relative-
    /// destination guard alone would not catch, since neither hop is
    /// relative. Exercises `pathIsDefinitelyAbsent`'s `ELOOP` handling as
    /// an independent second layer, not merely as a side effect of the
    /// relative-destination guard above.
    @Test func installAndUninstallRefuseAnAbsoluteSymlinkLoop() throws {
        try withScratchDirectory { directory in
            let hopDirectory = directory.appendingPathComponent("x", isDirectory: true)
            try FileManager.default.createDirectory(at: hopDirectory, withIntermediateDirectories: true)
            let hopPath = hopDirectory.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            let linkPath = directory.appendingPathComponent("restic-station").path

            try FileManager.default.createSymbolicLink(atPath: hopPath, withDestinationPath: linkPath)
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: hopPath)

            var info = stat()
            let statResult = linkPath.withCString { stat($0, &info) }
            #expect(statResult == -1)
            #expect(errno == ELOOP)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            let destinationAfterInstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterInstall == hopPath)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            let destinationAfterUninstall = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destinationAfterUninstall == hopPath)
        }
    }

    /// Currently-correct-but-untested: a plain *directory* sitting at the
    /// link path (as opposed to a file or a foreign symlink, both already
    /// covered above) is foreign too, and must survive untouched — contents
    /// included.
    @Test func installAndUninstallRefuseADirectoryAtTheLinkPath() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createDirectory(atPath: linkPath, withIntermediateDirectories: true)
            let markerPath = (linkPath as NSString).appendingPathComponent("marker")
            let markerContents = Data("still here".utf8)
            try markerContents.write(to: URL(fileURLWithPath: markerPath))

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.install(target: bundleTarget, directory: directory)
            }
            var isDirectoryAfterInstall: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: linkPath, isDirectory: &isDirectoryAfterInstall))
            #expect(isDirectoryAfterInstall.boolValue)
            #expect(try Data(contentsOf: URL(fileURLWithPath: markerPath)) == markerContents)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            var isDirectoryAfterUninstall: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: linkPath, isDirectory: &isDirectoryAfterUninstall))
            #expect(isDirectoryAfterUninstall.boolValue)
            #expect(try Data(contentsOf: URL(fileURLWithPath: markerPath)) == markerContents)
        }
    }

    // MARK: - uninstall

    @Test func uninstallRemovesAnOwnedSymlink() throws {
        try withScratchDirectory { directory in
            _ = try CLIInstaller.install(target: bundleTarget, directory: directory)
            let outcome = try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            guard case .removed(let linkPath) = outcome else {
                Issue.record("expected .removed, got \(outcome)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: linkPath))
        }
    }

    @Test func uninstallIsIdempotent() throws {
        try withScratchDirectory { directory in
            let first = try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            guard case .notInstalled = first else {
                Issue.record("expected .notInstalled, got \(first)")
                return
            }
            _ = try CLIInstaller.install(target: bundleTarget, directory: directory)
            _ = try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            let third = try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            guard case .notInstalled = third else {
                Issue.record("expected .notInstalled after removal, got \(third)")
                return
            }
        }
    }

    /// Mirrors `installRefusesToClobberAForeignFile`: `uninstall` must
    /// leave a foreign file at the link path completely alone.
    @Test func uninstallRefusesToRemoveAForeignFile() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            let foreignContents = Data("not ours".utf8)
            try foreignContents.write(to: URL(fileURLWithPath: linkPath))

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            #expect(FileManager.default.fileExists(atPath: linkPath))
            let survived = try Data(contentsOf: URL(fileURLWithPath: linkPath))
            #expect(survived == foreignContents)
        }
    }

    /// Mirrors `installRefusesToClobberAForeignSymlinkWithTheSameBasename`:
    /// `uninstall` must not delete a live foreign binary's symlink just
    /// because its destination is named `restic-station-helper`.
    @Test func uninstallRefusesToRemoveAForeignSymlinkWithTheSameBasename() throws {
        try withScratchDirectory { directory in
            let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let foreignBinaryPath = elsewhere.appendingPathComponent(CLIInstaller.ownedTargetBasename).path
            try Data("not ours".utf8).write(to: URL(fileURLWithPath: foreignBinaryPath))

            let linkPath = directory.appendingPathComponent("restic-station").path
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: foreignBinaryPath)

            #expect(throws: CLIInstaller.ForeignEntryError.self) {
                try CLIInstaller.uninstall(target: bundleTarget, directory: directory)
            }
            // Untouched: the symlink (and the foreign binary it points at) survive.
            #expect(FileManager.default.fileExists(atPath: linkPath))
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
            #expect(destination == foreignBinaryPath)
            #expect(FileManager.default.fileExists(atPath: foreignBinaryPath))
        }
    }

    // MARK: - status

    @Test func statusReportsNotInstalledWhenAbsent() {
        withScratchDirectory { directory in
            let status = CLIInstaller.status(
                directory: directory,
                currentTarget: bundleTarget,
                pathEnvironment: "/usr/bin"
            )
            #expect(!status.installed)
            #expect(status.resolvedTarget == nil)
            #expect(!status.upToDate)
            #expect(!status.foreignEntryPresent)
        }
    }

    @Test func statusReportsInstalledAndUpToDate() throws {
        try withScratchDirectory { directory in
            _ = try CLIInstaller.install(target: bundleTarget, directory: directory)
            let status = CLIInstaller.status(
                directory: directory,
                currentTarget: bundleTarget,
                pathEnvironment: directory.path
            )
            #expect(status.installed)
            #expect(status.resolvedTarget == bundleTarget)
            #expect(status.upToDate)
            #expect(status.onPath)
            #expect(!status.foreignEntryPresent)
        }
    }

    /// Same "old destination must not exist" reasoning as
    /// `installRepairsAStaleSymlinkOfOurs` above — see its doc comment.
    @Test func statusReportsInstalledButStaleAfterABundleMove() throws {
        try withScratchDirectory { directory in
            let oldTarget = directory.appendingPathComponent("old-bundle/restic-station-helper").path
            _ = try CLIInstaller.install(target: oldTarget, directory: directory)
            // A later `install` call would repoint it; `status` alone must
            // say "stale" without doing that repair itself.
            let status = CLIInstaller.status(
                directory: directory,
                currentTarget: movedBundleTarget,
                pathEnvironment: nil
            )
            #expect(status.installed)
            #expect(!status.upToDate)
            #expect(status.resolvedTarget == oldTarget)
        }
    }

    @Test func statusReportsForeignEntryPresentSeparatelyFromInstalled() throws {
        try withScratchDirectory { directory in
            let linkPath = directory.appendingPathComponent("restic-station").path
            try Data("not ours".utf8).write(to: URL(fileURLWithPath: linkPath))
            let status = CLIInstaller.status(directory: directory, currentTarget: bundleTarget, pathEnvironment: nil)
            #expect(!status.installed)
            #expect(status.foreignEntryPresent)
        }
    }

    // MARK: - PATH

    @Test func isDirectoryOnPathMatchesAnExactEntry() {
        let directory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        #expect(CLIInstaller.isDirectoryOnPath(directory, pathEnvironment: "/usr/bin:/usr/local/bin:/bin"))
    }

    @Test func isDirectoryOnPathIgnoresATrailingSlashInPATH() {
        let directory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        #expect(CLIInstaller.isDirectoryOnPath(directory, pathEnvironment: "/usr/local/bin/"))
    }

    @Test func isDirectoryOnPathFalseWhenAbsent() {
        let directory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        #expect(!CLIInstaller.isDirectoryOnPath(directory, pathEnvironment: "/usr/bin:/bin"))
    }

    @Test func isDirectoryOnPathFalseForNilEnvironment() {
        let directory = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        #expect(!CLIInstaller.isDirectoryOnPath(directory, pathEnvironment: nil))
    }

    // MARK: - Prefix

    @Test func systemPrefixIsUsrLocalBin() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(CLIInstaller.Prefix.system.directory(homeDirectory: home).path == "/usr/local/bin")
    }

    @Test func userPrefixIsDotLocalBinUnderHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        #expect(CLIInstaller.Prefix.user.directory(homeDirectory: home).path == "/Users/example/.local/bin")
    }

    // MARK: - GUI defaults (PR #42 codex review, finding 2)

    /// The GUI install button used to always target `.system`
    /// (`/usr/local/bin`), which is root-owned or absent on a clean or
    /// non-Homebrew Mac — a Finder-launched app can't write there, so the
    /// advertised one-click install just failed. `recommendedGUIPrefix()`
    /// is what `AppModel+CLI.swift`'s Settings row now seeds its default
    /// from instead of hardcoding `.system`; this pins that policy down so
    /// a future edit can't silently regress back to the always-fails
    /// default.
    @Test func recommendedGUIPrefixIsUser() {
        #expect(CLIInstaller.recommendedGUIPrefix() == .user)
    }

    // MARK: - Failure advice (PR #42 codex review, finding 2)

    @Test func installFailureAdvicePassesThroughAForeignEntryErrorVerbatim() {
        let error = CLIInstaller.ForeignEntryError(path: "/usr/local/bin/restic-station")
        let advice = CLIInstaller.installFailureAdvice(
            error: error,
            directory: URL(fileURLWithPath: "/usr/local/bin"),
            prefix: .system
        )
        #expect(advice == error.description)
    }

    /// The case the finding calls out: a permission failure writing to the
    /// root-owned system prefix must explain the fix (switch to the user
    /// prefix), not just restate the underlying `NSError`.
    @Test func installFailureAdviceForAPermissionErrorOnTheSystemPrefixSuggestsTheUserPrefix() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn't be saved because you don't have permission."]
        )
        let advice = CLIInstaller.installFailureAdvice(
            error: error,
            directory: URL(fileURLWithPath: "/usr/local/bin"),
            prefix: .system
        )
        #expect(advice.localizedCaseInsensitiveContains("permission"))
        #expect(advice.contains(".local/bin"))
    }

    @Test func installFailureAdviceForANonPermissionErrorIsPassedThroughWithContext() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "The folder doesn't exist."]
        )
        let directory = URL(fileURLWithPath: "/usr/local/bin")
        let advice = CLIInstaller.installFailureAdvice(error: error, directory: directory, prefix: .system)
        #expect(advice.contains("/usr/local/bin"))
        #expect(advice.contains("The folder doesn't exist."))
    }
}
