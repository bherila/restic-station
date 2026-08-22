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

@Suite struct FileLockTests {
    private func makeLockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-filelock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.appendingPathComponent("test.lock", isDirectory: false)
    }

    @Test func secondInstanceCannotAcquireWhileFirstHolds() throws {
        let url = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Two separate FileLock instances on the same path == two separate
        // open file descriptions, so they genuinely contend even though
        // they live in the same process (flock is per-open-file-description,
        // not per-process).
        let first = FileLock(path: url)
        let second = FileLock(path: url)

        #expect(first.acquire() == .acquired)
        #expect(second.acquire() == .busy)

        first.release()
        #expect(second.acquire() == .acquired)

        second.release()
    }

    @Test func deinitReleasesTheLock() throws {
        let url = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var holder: FileLock? = FileLock(path: url)
        #expect(holder?.acquire() == .acquired)

        holder = nil // deinit should release

        let contender = FileLock(path: url)
        #expect(contender.acquire() == .acquired)
        contender.release()
    }

    @Test func lockFileItselfPersistingMeansNothing() throws {
        let url = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let lock = FileLock(path: url)
        #expect(lock.acquire() == .acquired)
        lock.release()

        // The lock file on disk still exists after release, but a fresh
        // FileLock can acquire it immediately — mere existence of the file
        // means nothing per docs/scheduling.md §Locking.
        #expect(FileManager.default.fileExists(atPath: url.path) == true)
        let fresh = FileLock(path: url)
        #expect(fresh.acquire() == .acquired)
        fresh.release()
    }

    @Test func reacquireBySameInstanceAfterReleaseSucceeds() throws {
        let url = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let lock = FileLock(path: url)
        #expect(lock.acquire() == .acquired)
        lock.release()
        #expect(lock.acquire() == .acquired)
        lock.release()
    }
}

// MARK: - #110: contention is not the same answer as breakage

/// The distinction the whole of issue #110 turns on. Every one of these used
/// to be the single `false` that callers read as "someone else is running",
/// which is how an unusable data directory became a silent, permanent,
/// exit-0 stoppage of every scheduled backup.
/// `chmod` means nothing to root, and the Linux CI container runs as root,
/// so a permissions-based fault cannot be injected there. Tests that need
/// one are genuinely skipped via `.enabled(if:)` — note that `#require`
/// would *fail* them instead, which is how this first reached CI.
let canInjectPermissionFaults = geteuid() != 0

@Suite struct FileLockFaultTests {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lockfault-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(
        "an unwritable directory is .failed(EACCES), never .busy",
        .enabled(if: canInjectPermissionFaults, "chmod means nothing to root")
    )
    func unwritableDirectoryIsAFailure() throws {
        let directory = makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        // r-x: the directory can be listed but nothing new created in it.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        let lock = FileLock(path: directory.appendingPathComponent("tick.lock"))
        guard case .failed(let failure) = lock.acquire() else {
            Issue.record("an uncreatable lock file must not report as contention")
            return
        }
        #expect(failure.operation == "open")
        #expect(failure.errnoValue == EACCES)
        #expect(String(describing: failure).contains("tick.lock"))
    }

    @Test("a symlink at the lock path is refused rather than followed")
    func symlinkAtLockPathIsRefused() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("elsewhere")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let lockPath = directory.appendingPathComponent("tick.lock")
        try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: target)

        guard case .failed(let failure) = FileLock(path: lockPath).acquire() else {
            Issue.record("O_NOFOLLOW must refuse a symlinked lock path")
            return
        }
        #expect(failure.operation == "open")
        // ELOOP on both platforms; the point is that it is a fault, not
        // contention, and that `elsewhere` was never opened.
        #expect(failure.errnoValue == ELOOP)
    }

    @Test("a non-creating probe refuses a dangling symlink")
    func nonCreatingProbeRefusesDanglingSymlink() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingTarget = directory.appendingPathComponent("missing")
        let lockPath = directory.appendingPathComponent("set-dangling.lock")
        try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: missingTarget)

        let failure = try #require(
            FileLock(path: lockPath).probe(createIfMissing: false),
            "a dangling symlink exists even though its target does not"
        )
        #expect(failure.operation == "open")
        #expect(failure.errnoValue == ELOOP)
    }

    @Test("a lock path that is a directory is refused by the file-type check")
    func directoryAtLockPathIsRefused() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("tick.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockPath, withIntermediateDirectories: true)

        guard case .failed(let failure) = FileLock(path: lockPath).acquire() else {
            Issue.record("a directory at the lock path must not report as contention")
            return
        }
        // Some platforms refuse the `open` outright (EISDIR); where it
        // succeeds, the `fstat` check catches it. Either is a failure, and
        // neither may be `.busy`.
        #expect(failure.operation == "open" || failure.operation == "file type")
    }

    @Test("a newly created lock file is owner-only")
    func newLockFileIsOwnerOnly() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("tick.lock")

        let lock = FileLock(path: lockPath)
        #expect(lock.acquire() == .acquired)
        defer { lock.release() }

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: lockPath.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value & 0o077 == 0, "a lock another user can open is a lock another user can hold")
    }

    @Test("a pre-existing group/world-readable lock file is tightened in place")
    func looseLockFileIsTightened() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("tick.lock")
        // What every release before this one created.
        FileManager.default.createFile(
            atPath: lockPath.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )

        let lock = FileLock(path: lockPath)
        #expect(lock.acquire() == .acquired)
        defer { lock.release() }

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: lockPath.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value & 0o077 == 0)
    }

    @Test("a group-writable lock directory is refused before opening the lock")
    func groupWritableLockDirectoryIsRefused() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770], ofItemAtPath: paths.locksDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: paths.locksDir.path
            )
        }

        guard case .failed(let failure) = FileLock(
            path: paths.tickLockFile, trustedRoot: root
        ).acquire() else {
            Issue.record("another uid must not be able to replace a flocked lock inode")
            return
        }
        #expect(failure.operation == "lock directory permissions")
        #expect(failure.path == paths.locksDir.path)
        #expect(!FileManager.default.fileExists(atPath: paths.tickLockFile.path))
    }

    @Test("probe reports the same faults without taking the lock")
    func probeDoesNotContend() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockPath = directory.appendingPathComponent("tick.lock")

        // The point of `probe()`: a monitoring command must be able to ask
        // "does locking work here?" without making a tick starting in that
        // instant see contention and skip its cycle.
        let holder = FileLock(path: lockPath)
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        #expect(FileLock(path: lockPath).probe() == nil, "a held lock is working locking, not a fault")
    }

    /// Root-proof by construction: `chmod` is advisory to root, but a
    /// regular file where a parent directory has to be is `ENOTDIR` for
    /// everyone. That matters because the Linux CI container runs as root,
    /// where a permissions-based injection would have to be skipped.
    @Test("LockingHealth reports an uncreatable data directory")
    func lockingHealthReportsUncreatableRoot() throws {
        let parent = makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        // `data` is a file, so `data/locks` can never be created.
        let blocker = parent.appendingPathComponent("data")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())

        let paths = AppPaths(root: blocker)
        let failure = try #require(
            LockingHealth.probe(paths: paths),
            "an uncreatable data directory must be reported, not stepped over"
        )
        #expect(failure.operation == "create data directories")
    }

    /// #117 review: a single hostile `set-<id>.lock` blocks that one set
    /// forever while `locks/` itself is fine, so probing only the tick lock
    /// left the live alarm green.
    @Test("LockingHealth catches a hostile per-set lock, not just the tick lock")
    func lockingHealthProbesExistingSetLocks() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        #expect(LockingHealth.probe(paths: paths) == nil, "precondition: healthy to begin with")

        // A directory where one set's lock file belongs. `locks/` and
        // `tick.lock` are untouched and perfectly usable.
        let setId = UUID()
        try FileManager.default.createDirectory(
            at: paths.setLockFile(setId: setId), withIntermediateDirectories: true
        )

        let failure = try #require(
            LockingHealth.probe(paths: paths),
            "a per-set lock that cannot be opened must not read as a healthy machine"
        )
        #expect(String(describing: failure).contains(setId.uuidString))
        #expect(failure.scope == .set(setId))
    }

    @Test("LockingHealth exercises flock on its dedicated stable inode")
    func lockingHealthExercisesFlock() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        #expect(!FileManager.default.fileExists(atPath: paths.healthLockFile.path))
        #expect(LockingHealth.probe(paths: paths) == nil)
        #expect(FileManager.default.fileExists(atPath: paths.healthLockFile.path))

        // Contention on the health inode is healthy: another probe holding
        // it proves that `flock` works and must not create a false outage.
        let holder = FileLock(path: paths.healthLockFile, trustedRoot: root)
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }
        #expect(LockingHealth.probe(paths: paths) == nil)
    }

    @Test(
        "LockingHealth proves a new set lock can be created even when tick.lock already exists",
        .enabled(if: canInjectPermissionFaults, "root ignores directory write-mode denial")
    )
    func lockingHealthChecksLockCreationCapability() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        // Create the stable health inode before removing directory write
        // permission. The live flock exercise can then succeed, leaving the
        // independent creation-capability check as the fault under test.
        #expect(LockingHealth.probe(paths: paths) == nil)

        // Opening this existing file still succeeds after locks/ becomes
        // read-only. The missing set lock is the operation that would fail.
        FileManager.default.createFile(atPath: paths.tickLockFile.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: paths.locksDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: paths.locksDir.path
            )
        }

        let failure = try #require(
            LockingHealth.probe(paths: paths),
            "an existing tick.lock must not mask inability to create the next set lock"
        )
        #expect(failure.operation == "create lock")
        #expect(failure.path == paths.locksDir.path)
    }

    @Test("LockingHealth probes every known companion lock")
    func lockingHealthProbesCompanionLocks() throws {
        let lockPaths: [(String, (AppPaths) -> URL)] = [
            ("secrets", { $0.secretsLockFile }),
            ("schedule state", { $0.scheduleStateLockFile }),
            ("preview tokens", { $0.previewTokensLockFile }),
            ("run index", { $0.runsIndexLockFile }),
        ]

        for (name, lockPath) in lockPaths {
            let root = makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(root: root)
            try paths.ensureDirectories()
            let hostile = lockPath(paths)
            try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)

            let failure = try #require(
                LockingHealth.probe(paths: paths),
                "a hostile \(name) lock must not leave locking health green"
            )
            #expect(failure.path == hostile.path)
        }
    }

    @Test("a successful directory-creation probe does not mutate the directory")
    func creationProbeDoesNotMutateDirectory() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinel = directory.appendingPathComponent("sentinel")
        FileManager.default.createFile(atPath: sentinel.path, contents: Data())
        let before = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date

        #expect(FileLock.probeCreation(in: directory) == nil)
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let after = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date
        #expect(entries == ["sentinel"])
        #expect(after == before)
    }

    @Test(
        "LockingHealth reports a lock directory it cannot enumerate",
        .enabled(if: canInjectPermissionFaults, "root can enumerate mode-0300 directories")
    )
    func lockingHealthReportsEnumerationFailure() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        // Keep tick.lock openable while denying directory reads. This lets
        // the first probe pass and isolates the enumeration failure.
        FileManager.default.createFile(atPath: paths.tickLockFile.path, contents: Data())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o300], ofItemAtPath: paths.locksDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: paths.locksDir.path
            )
        }

        let failure = try #require(
            LockingHealth.probe(paths: paths),
            "failure to inspect per-set locks must not report healthy"
        )
        // Descriptor-relative validation may fail while opening the
        // unreadable directory, before Foundation attempts enumeration.
        // Either result is a fail-closed inspection outcome.
        #expect(
            failure.operation == "open lock directory"
                || failure.operation == "enumerate lock directory"
        )
        #expect(failure.path == paths.locksDir.path)
    }

    /// The probe must not manufacture the very files it reports on: a
    /// read-only status query that created a lock file per configured set
    /// would be a write, and on a fresh install would report every set.
    @Test("probing existing set locks creates nothing")
    func probeDoesNotCreateSetLocks() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let absent = paths.setLockFile(setId: UUID())
        #expect(FileLock(path: absent).probe(createIfMissing: false) == nil)
        #expect(
            !FileManager.default.fileExists(atPath: absent.path),
            "a non-creating probe must leave the filesystem as it found it"
        )
    }

    @Test("LockingHealth is quiet on a healthy data directory")
    func lockingHealthIsQuietWhenHealthy() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LockingHealth.probe(paths: AppPaths(root: root)) == nil)
    }
}
