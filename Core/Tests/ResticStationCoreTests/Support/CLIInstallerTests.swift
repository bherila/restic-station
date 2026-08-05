import Foundation
import Testing
@testable import ResticStationCore

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
