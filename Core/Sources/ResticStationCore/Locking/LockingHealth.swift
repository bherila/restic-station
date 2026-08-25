import Foundation

public enum LockingHealthScope: Equatable, Sendable {
    case machine
    case set(UUID)
    /// A lock used only for administrative mutation is broken. Existing
    /// backup, check, restore, and maintenance reads remain usable.
    case administrative
    /// A health-only lock or scratch artifact is damaged. The live probe is
    /// inconclusive; this alone does not prove production locks are unusable.
    case diagnostic
}

/// A live locking fault together with the amount of work it blocks.
/// Per-set and administrative lock damage are partial outages; shared
/// operation locks and directory faults prevent safe operation machine-wide.
/// Health-only artifact damage is diagnostic failure, not evidence of a
/// production outage.
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
    public static func probe(
        paths: AppPaths,
        configuredSetIds: Set<UUID>,
        secretBackend: SecretBackend = .file
    ) -> LockingHealthFailure? {
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
        for sharedLock in [
            paths.tickLockFile,
            paths.destructiveAuditLockFile,
            paths.runPublicationLockFile,
        ] {
            if let failure = FileLock(
                path: sharedLock, trustedRoot: paths.root
            ).probe(createIfMissing: false) {
                return machine(failure)
            }
        }
        // These directories may be distinct mounts. On each one, exercise
        // the persistent flock inode, effective access, and a fresh inode
        // allocation. The nested scratch directories keep create/remove
        // activity below the app's non-recursive parent watchers.
        var diagnosticFailure: LockingHealthFailure?
        healthFilesystems: for (healthLock, directory, scratchDirectory) in [
            (paths.healthLockFile, paths.locksDir, paths.lockHealthProbeDir),
            (paths.stateHealthLockFile, paths.stateDir, paths.stateHealthProbeDir),
            (paths.runsHealthLockFile, paths.runsDir, paths.runsHealthProbeDir),
        ] {
            if let failure = FileLock(
                path: healthLock, trustedRoot: paths.root
            ).probeLocking() {
                // A fault in the health-only inode is inconclusive. A fault
                // in its verified production parent remains machine-wide.
                if failure.path == healthLock.path {
                    let classified = classifyHealthArtifactFailure(failure)
                    if classified.scope == .machine { return classified }
                    diagnosticFailure = diagnosticFailure ?? classified
                } else {
                    return machine(failure)
                }
            }
            if let failure = FileLock.probeCreation(in: directory, trustedRoot: paths.root) {
                return machine(failure)
            }
            // Diagnostic scratch is health-only. Normal operation setup must
            // not depend on any of these paths being intact.
            if let failure = FileLock.ensureDirectory(
                scratchDirectory,
                parent: directory,
                trustedRoot: paths.root,
                mode: 0o700
            ) {
                // The scratch node itself is health-only. Failure while
                // validating its production parent or creating the missing
                // scratch directory still proves real lock creation cannot
                // currently work.
                if failure.path == scratchDirectory.path {
                    let classified = classifyHealthArtifactFailure(failure)
                    if classified.scope == .machine { return classified }
                    diagnosticFailure = diagnosticFailure ?? classified
                    continue healthFilesystems
                }
                return machine(failure)
            }
            if let failure = FileLock.probeActualCreation(in: scratchDirectory) {
                let classified = classifyHealthArtifactFailure(failure)
                if classified.scope == .machine { return classified }
                diagnosticFailure = diagnosticFailure ?? classified
            }
        }
        // The secrets lock serializes mutation only. Reads use the atomic
        // secrets file directly, so damage here is an administrative outage,
        // not evidence that configured backup operations cannot run.
        let administrativeFailure: LockingHealthFailure?
        if secretBackend == .file {
            administrativeFailure = FileLock(
                path: paths.secretsLockFile, trustedRoot: paths.root
            ).probe(createIfMissing: false).map {
                LockingHealthFailure(scope: .administrative, failure: $0)
            }
        } else {
            administrativeFailure = nil
        }

        // These companion locks protect shared local state outside
        // `locks/`. Probe known files without creating them, then separately
        // prove their parent directories can create a future lock. Shared
        // machine-wide faults must be selected before a narrower per-set
        // fault so status never understates the outage.
        for lockFile in [
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
        if let productionFailure = probeConfiguredSetLocks(
            paths: paths,
            configuredSetIds: configuredSetIds
        ) {
            return productionFailure
        }
        return administrativeFailure ?? diagnosticFailure
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

    private static func diagnostic(_ failure: LockFailure) -> LockingHealthFailure {
        LockingHealthFailure(scope: .diagnostic, failure: failure)
    }

    /// Health-path damage is inconclusive, but failures of the capabilities
    /// those artifacts exist to exercise are production outages. Internal so
    /// tests can pin this distinction without requiring a full disk or a
    /// filesystem that rejects flock.
    static func classifyHealthArtifactFailure(_ failure: LockFailure) -> LockingHealthFailure {
        switch failure.operation {
        case "flock", "create lock probe", "create protected directory":
            return machine(failure)
        default:
            return diagnostic(failure)
        }
    }
}
