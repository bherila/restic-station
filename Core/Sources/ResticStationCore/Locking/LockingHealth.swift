import Foundation

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
    /// Checks `tick.lock` only. Per-set lock files are created on demand, so
    /// probing them would mean creating a file for every configured set as a
    /// side effect of a read-only status query; the faults worth catching
    /// here — an uncreatable, unwritable or hostile `locks/` — are directory
    /// scoped and show up on the tick lock just as well.
    public static func probe(paths: AppPaths) -> LockFailure? {
        do {
            try paths.ensureDirectories()
        } catch {
            return LockFailure(
                path: paths.root.path,
                operation: "create data directories",
                errnoValue: 0,
                underlying: "\(error)"
            )
        }
        return FileLock(path: paths.tickLockFile).probe()
    }
}
