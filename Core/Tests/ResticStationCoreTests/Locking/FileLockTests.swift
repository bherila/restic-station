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
    private func makeLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-filelock-test-\(UUID().uuidString).lock")
    }

    @Test func secondInstanceCannotAcquireWhileFirstHolds() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

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
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var holder: FileLock? = FileLock(path: url)
        #expect(holder?.acquire() == .acquired)

        holder = nil // deinit should release

        let contender = FileLock(path: url)
        #expect(contender.acquire() == .acquired)
        contender.release()
    }

    @Test func lockFileItselfPersistingMeansNothing() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

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
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

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
let canInjectPermissionFaults = getuid() != 0

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

    @Test("LockingHealth is quiet on a healthy data directory")
    func lockingHealthIsQuietWhenHealthy() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LockingHealth.probe(paths: AppPaths(root: root)) == nil)
    }
}
