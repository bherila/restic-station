import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Advisory `flock(2)` wrapper per `docs/scheduling.md` §Locking.
///
/// Two levels of lock in this app (`locks/tick.lock`,
/// `locks/set-<setId>.lock`) both use this type: `LOCK_EX | LOCK_NB` on a
/// file under `locks/`. The lock is released automatically by the kernel on
/// process death (no stale-lock cleanup needed) — the lock *file* persists
/// forever and its mere existence means nothing; only a live, held
/// `flock()` means anything.
///
/// Important: `flock()` locks are associated with the **open file
/// description**, not the path or the process. Two separate `FileLock`
/// instances constructed with the same `path` — even within the same
/// process — each `open(2)` their own file descriptor and therefore
/// genuinely contend with each other, which is what makes an in-process
/// two-instance contention test valid.
public final class FileLock: @unchecked Sendable {
    public let path: URL
    private var fd: Int32 = -1

    public init(path: URL) {
        self.path = path
    }

    /// Opens (creating if necessary) and attempts a non-blocking exclusive
    /// lock. Returns `false` if another open file description already
    /// holds the lock, or if the file could not be opened. Safe to call
    /// repeatedly (e.g. to poll).
    @discardableResult
    public func tryAcquire() -> Bool {
        if fd < 0 {
            let opened = path.path.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
            guard opened >= 0 else { return false }
            fd = opened
        }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// Releases the lock (if held) and closes the file descriptor. Safe to
    /// call multiple times.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit {
        release()
    }
}
