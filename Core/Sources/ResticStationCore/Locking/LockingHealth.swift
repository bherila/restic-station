import Foundation

public enum LockingHealthScope: Equatable, Sendable {
    case machine
    case set(UUID)
}

/// A live locking fault together with the amount of work it blocks.
/// Per-set lock damage is a partial outage; shared locks and directory
/// faults prevent safe operation machine-wide.
public struct LockingHealthFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let scope: LockingHealthScope
    public let failure: LockFailure

    public init(scope: LockingHealthScope, failure: LockFailure) {
        self.scope = scope
        self.failure = failure
    }

    public var path: String { failure.path }
    public var operation: String { failure.operation }
    public var errnoValue: Int32 { failure.errnoValue }
    public var description: String { failure.description }
}

/// A live check that this machine's locking machinery still works.
///
/// The durable half of issue #110 — a `tick` that exits non-zero, a run
/// recorded `.failed` — depends on being able to write, and the failure it
/// reports is very often *the inability to write*. So the two mechanisms
/// cannot be the same mechanism. This one derives the answer at read time
/// from the filesystem itself, and therefore still works on exactly the
/// hosts where nothing could be recorded.
public enum LockingHealth {
    /// `nil` when the data directory and its lock files are usable.
    ///
    /// Checks the existing tick, per-set and shared-state lock files, plus
    /// live creation capability in each parent directory. A hostile lock for
    /// a configured set (a directory, a symlink, another user's file) blocks
    /// that one set forever while `locks/` itself is perfectly fine, and an
    /// existing `tick.lock` alone does not prove another lock can be created.
    ///
    /// Per-set locks are created on demand, so a read-only status query must
    /// not bring one into being for every configured set as a side effect.
    public static func probe(paths: AppPaths, configuredSetIds: Set<UUID>) -> LockingHealthFailure? {
        do {
            try paths.ensureDirectories()
        } catch let failure as LockFailure {
            return machine(failure)
        } catch {
            return LockingHealthFailure(
                scope: .machine,
                failure: LockFailure(
                    path: paths.root.path,
                    operation: "create data directories",
                    errnoValue: 0,
                    underlying: "\(error)"
                )
            )
        }
        if let failure = FileLock(
            path: paths.tickLockFile, trustedRoot: paths.root
        ).probe(createIfMissing: false) {
            return machine(failure)
        }
        if let failure = FileLock(
            path: paths.healthLockFile, trustedRoot: paths.root
        ).probeLocking() {
            return machine(failure)
        }
        if let failure = FileLock.probeCreation(in: paths.locksDir, trustedRoot: paths.root) {
            return machine(failure)
        }
        // Diagnostic scratch is health-only. Normal tick/set-lock setup must
        // not depend on this path being intact.
        if let failure = FileLock.ensureDirectory(
            paths.lockHealthProbeDir,
            parent: paths.locksDir,
            trustedRoot: paths.root,
            mode: 0o700
        ) {
            return machine(failure)
        }
        if let failure = FileLock.probeActualCreation(in: paths.lockHealthProbeDir) {
            return machine(failure)
        }
        // These companion locks protect shared local state outside
        // `locks/`. Probe known files without creating them, then separately
        // prove their parent directories can create a future lock. Shared
        // machine-wide faults must be selected before a narrower per-set
        // fault so status never understates the outage.
        for lockFile in [
            paths.secretsLockFile,
            paths.scheduleStateLockFile,
            paths.previewTokensLockFile,
            paths.runsIndexLockFile,
        ] {
            if let failure = FileLock(
                path: lockFile, trustedRoot: paths.root
            ).probe(createIfMissing: false) {
                return machine(failure)
            }
        }
        // `locks/`, `state/`, and `runs/` may be distinct mounts. Exercise
        // real flock semantics on a non-production inode in every one.
        for healthLock in [paths.stateHealthLockFile, paths.runsHealthLockFile] {
            if let failure = FileLock(
                path: healthLock, trustedRoot: paths.root
            ).probeLocking() {
                return machine(failure)
            }
        }
        for directory in [paths.stateDir, paths.runsDir] {
            if let failure = FileLock.probeCreation(in: directory, trustedRoot: paths.root) {
                return machine(failure)
            }
        }
        return probeConfiguredSetLocks(paths: paths, configuredSetIds: configuredSetIds)
    }

    /// The first unusable configured set lock already on disk, if any. The
    /// status renderer labels it as the first detected set rather than
    /// claiming it is the only affected set.
    /// Orphaned and malformed persistent lock names are harmless: `flock`
    /// state lives on descriptors, not filenames, and no configured work
    /// will ever open them.
    private static func probeConfiguredSetLocks(
        paths: AppPaths,
        configuredSetIds: Set<UUID>
    ) -> LockingHealthFailure? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: paths.locksDir.path)
        } catch {
            return machine(LockFailure(
                path: paths.locksDir.path,
                operation: "enumerate lock directory",
                errnoValue: 0,
                underlying: "\(error)"
            ))
        }
        for setId in configuredSetIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            let url = paths.setLockFile(setId: setId)
            if let failure = FileLock(
                path: url, trustedRoot: paths.root
            ).probe(createIfMissing: false) {
                return LockingHealthFailure(scope: .set(setId), failure: failure)
            }
        }
        return nil
    }

    private static func machine(_ failure: LockFailure) -> LockingHealthFailure {
        LockingHealthFailure(scope: .machine, failure: failure)
    }
}
