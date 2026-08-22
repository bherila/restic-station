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
    /// Checks `tick.lock`, which covers the directory-scoped faults — an
    /// uncreatable, unwritable or hostile `locks/` — **and every per-set lock
    /// file that already exists**. A single hostile `set-<id>.lock` (a
    /// directory, a symlink, another user's file) blocks that one set
    /// forever while `locks/` itself is perfectly fine, so probing only the
    /// tick lock left that alarm green; found by review on #117.
    ///
    /// Existing files only. Per-set locks are created on demand, and a
    /// read-only status query must not bring one into being for every
    /// configured set as a side effect.
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
        if let failure = FileLock(path: paths.tickLockFile).probe() {
            return failure
        }
        return probeExistingSetLocks(paths: paths)
    }

    /// The first unusable `locks/set-*.lock` already on disk, if any.
    private static func probeExistingSetLocks(paths: AppPaths) -> LockFailure? {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: paths.locksDir.path)
        } catch {
            return LockFailure(
                path: paths.locksDir.path,
                operation: "enumerate lock directory",
                errnoValue: 0,
                underlying: "\(error)"
            )
        }
        for name in entries.sorted() where name.hasPrefix("set-") && name.hasSuffix(".lock") {
            let url = paths.locksDir.appendingPathComponent(name, isDirectory: false)
            if let failure = FileLock(path: url).probe(createIfMissing: false) {
                return failure
            }
        }
        return nil
    }
}
