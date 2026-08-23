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

    @Test("a replaceable data-root entry cannot split the lock namespace")
    func replaceableDataRootIsRefusedBeforeRecreation() throws {
        let parent = makeDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: parent.path
            )
            try? FileManager.default.removeItem(at: parent)
        }
        let root = parent.appendingPathComponent("data", isDirectory: true)
        let displacedRoot = parent.appendingPathComponent("data-held-by-first", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let holder = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }

        // Model a different local uid gaining ordinary directory replacement
        // access: the first helper keeps the old-tree flock, while the data
        // root's pathname is moved out from beneath it.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: parent.path
        )
        try FileManager.default.moveItem(at: root, to: displacedRoot)

        do {
            try paths.ensureDirectories()
            Issue.record("setup must not recreate a second lock tree under a replaceable root entry")
        } catch let failure as LockFailure {
            #expect(failure.operation == "lock root parent permissions")
            #expect(failure.path == parent.path)
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "parent validation must happen before the missing root is recreated"
        )

        guard case .failed(let failure) = FileLock(
            path: paths.tickLockFile, trustedRoot: root
        ).acquire() else {
            Issue.record("a second helper must fail rather than acquire a distinct lock inode")
            return
        }
        #expect(failure.operation == "lock root parent permissions")
        #expect(failure.path == parent.path)
    }

    @Test("a sticky trusted parent preserves owner-protected root entries")
    func stickyDataRootParentIsAccepted() throws {
        let parent = makeDirectory()
        defer {
            _ = parent.path.withCString { chmod($0, 0o700) }
            try? FileManager.default.removeItem(at: parent)
        }
        try #require(parent.path.withCString { chmod($0, 0o1777) } == 0)

        let root = parent.appendingPathComponent("data", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let lock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(lock.acquire() == .acquired)
        lock.release()
    }

    @Test(
        "search-only trusted directories can still host known lock paths",
        .enabled(if: canInjectPermissionFaults, "root bypasses directory permission checks")
    )
    func searchOnlyDirectoriesAreAccepted() throws {
        let parent = makeDirectory()
        let root = parent.appendingPathComponent("data", isDirectory: true)
        defer {
            for directory in [root.appendingPathComponent("locks", isDirectory: true), root, parent] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path
                )
            }
            try? FileManager.default.removeItem(at: parent)
        }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: paths.locksDir.path)

        let lock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(lock.acquire() == .acquired)
        lock.release()
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
            LockingHealth.probe(paths: paths, configuredSetIds: []),
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
        #expect(
            LockingHealth.probe(paths: paths, configuredSetIds: []) == nil,
            "precondition: healthy to begin with"
        )

        // A directory where one set's lock file belongs. `locks/` and
        // `tick.lock` are untouched and perfectly usable.
        let setId = UUID()
        try FileManager.default.createDirectory(
            at: paths.setLockFile(setId: setId), withIntermediateDirectories: true
        )

        let failure = try #require(
            LockingHealth.probe(paths: paths, configuredSetIds: [setId]),
            "a per-set lock that cannot be opened must not read as a healthy machine"
        )
        #expect(String(describing: failure).contains(setId.uuidString))
        #expect(failure.scope == .set(setId))
    }

    @Test("LockingHealth labels a multi-set outage by its first detected set")
    func lockingHealthDoesNotClaimOnlyOneSetIsBroken() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let setIds = [UUID(), UUID()]
        for setId in setIds {
            try FileManager.default.createDirectory(
                at: paths.setLockFile(setId: setId),
                withIntermediateDirectories: true
            )
        }

        let failure = try #require(
            LockingHealth.probe(paths: paths, configuredSetIds: Set(setIds))
        )
        let first = setIds.sorted { $0.uuidString < $1.uuidString }[0]
        #expect(failure.scope == .set(first))
    }

    @Test("LockingHealth ignores orphaned and malformed persistent set locks")
    func lockingHealthIgnoresUnconfiguredSetLocks() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let orphaned = UUID()
        for path in [
            paths.setLockFile(setId: orphaned),
            paths.locksDir.appendingPathComponent("set-not-a-uuid.lock", isDirectory: false),
        ] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)
    }

    @Test("LockingHealth prefers a simultaneous machine-wide fault over a set fault")
    func lockingHealthPrefersMachineWideFault() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let setId = UUID()
        try FileManager.default.createDirectory(
            at: paths.setLockFile(setId: setId), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.scheduleStateLockFile, withIntermediateDirectories: true
        )

        let failure = try #require(
            LockingHealth.probe(paths: paths, configuredSetIds: [setId])
        )
        #expect(failure.scope == .machine)
        #expect(failure.path == paths.scheduleStateLockFile.path)
    }

    @Test("LockingHealth exercises flock on each lock-owning filesystem")
    func lockingHealthExercisesFlockOnEveryFilesystem() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        let healthLocks = [
            paths.healthLockFile,
            paths.stateHealthLockFile,
            paths.runsHealthLockFile,
        ]
        let scratchDirectories = [
            paths.lockHealthProbeDir,
            paths.stateHealthProbeDir,
            paths.runsHealthProbeDir,
        ]
        #expect(healthLocks.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(scratchDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)
        #expect(healthLocks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(scratchDirectories.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Contention on the health inode is healthy: another probe holding
        // it proves that `flock` works and must not create a false outage.
        let holder = FileLock(path: paths.healthLockFile, trustedRoot: root)
        #expect(holder.acquire() == .acquired)
        defer { holder.release() }
        #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)
    }

    @Test("damage to a health-only lock makes the probe inconclusive, not production-unusable")
    func lockingHealthSeparatesDiagnosticInodeDamage() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        try FileManager.default.createDirectory(
            at: paths.healthLockFile,
            withIntermediateDirectories: true
        )

        let failure = try #require(LockingHealth.probe(paths: paths, configuredSetIds: []))
        #expect(failure.scope == .diagnostic)
        #expect(failure.path == paths.healthLockFile.path)

        // The actual operation lock remains usable; the diagnostic artifact
        // alone is not evidence for a machine-wide production outage.
        let tick = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(tick.acquire() == .acquired)
        tick.release()
    }

    @Test("health capability failures remain production outages")
    func lockingHealthClassifiesHealthArtifactFailuresByMeaning() {
        let healthPath = "/data/locks/health.lock"
        let scratchPath = "/data/locks/.health"

        #expect(LockingHealth.classifyHealthArtifactFailure(LockFailure(
            path: healthPath,
            operation: "flock",
            errnoValue: ENOTSUP
        )).scope == .machine)
        #expect(LockingHealth.classifyHealthArtifactFailure(LockFailure(
            path: scratchPath,
            operation: "create lock probe",
            errnoValue: ENOSPC
        )).scope == .machine)
        #expect(LockingHealth.classifyHealthArtifactFailure(LockFailure(
            path: scratchPath,
            operation: "create protected directory",
            errnoValue: EDQUOT
        )).scope == .machine)

        #expect(LockingHealth.classifyHealthArtifactFailure(LockFailure(
            path: healthPath,
            operation: "file type",
            errnoValue: 0
        )).scope == .diagnostic)
        #expect(LockingHealth.classifyHealthArtifactFailure(LockFailure(
            path: scratchPath,
            operation: "remove lock probe",
            errnoValue: EACCES
        )).scope == .diagnostic)
    }

    @Test("a production lock outage outranks simultaneous diagnostic damage")
    func lockingHealthPrefersProductionFailureOverDiagnosticDamage() throws {
        let root = makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()

        try FileManager.default.createDirectory(
            at: paths.healthLockFile,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: paths.scheduleStateLockFile,
            withIntermediateDirectories: true
        )

        let failure = try #require(LockingHealth.probe(paths: paths, configuredSetIds: []))
        #expect(failure.scope == .machine)
        #expect(failure.path == paths.scheduleStateLockFile.path)
    }

    @Test("LockingHealth freshly allocates on state and runs after their health inodes exist")
    func lockingHealthRepeatedlyProbesAllocationOnEveryFilesystem() throws {
        for scratchPath in [
            { (paths: AppPaths) in paths.stateHealthProbeDir },
            { (paths: AppPaths) in paths.runsHealthProbeDir },
        ] {
            let root = makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(root: root)
            try paths.ensureDirectories()
            #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)

            let scratchDirectory = scratchPath(paths)
            var before = stat()
            try #require(scratchDirectory.path.withCString { lstat($0, &before) } == 0)
            usleep(10_000)

            #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)
            var after = stat()
            try #require(scratchDirectory.path.withCString { lstat($0, &after) } == 0)
            #if canImport(Darwin)
            #expect(
                before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec
                    || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec
            )
            #else
            #expect(
                before.st_mtim.tv_sec != after.st_mtim.tv_sec
                    || before.st_mtim.tv_nsec != after.st_mtim.tv_nsec
            )
            #endif
        }
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
        #expect(LockingHealth.probe(paths: paths, configuredSetIds: []) == nil)

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
            LockingHealth.probe(paths: paths, configuredSetIds: []),
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
                LockingHealth.probe(paths: paths, configuredSetIds: []),
                "a hostile \(name) lock must not leave locking health green"
            )
            #expect(failure.path == hostile.path)
            #expect(failure.scope == (name == "secrets" ? .administrative : .machine))
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

    @Test("the actual creation probe allocates and removes a fresh inode")
    func actualCreationProbeLeavesNoResidue() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FileLock.probeActualCreation(in: directory) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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
            LockingHealth.probe(paths: paths, configuredSetIds: []),
            "failure to inspect per-set locks must not report healthy"
        )
        // Descriptor-relative setup or validation may fail while opening the
        // unreadable directory, before Foundation attempts enumeration.
        // Every result is a fail-closed inspection outcome.
        #expect(
            failure.operation == "open protected directory"
                || failure.operation == "open lock directory"
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
        #expect(LockingHealth.probe(paths: AppPaths(root: root), configuredSetIds: []) == nil)
    }
}
