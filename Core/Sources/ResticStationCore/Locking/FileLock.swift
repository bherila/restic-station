import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Why a lock could not be taken, when the reason was *not* contention.
///
/// Carries enough to name the fault in a health record or an operator-facing
/// message: which file, which syscall, and the `errno` it set. `errnoValue`
/// is `0` for a policy refusal (wrong file type, wrong owner), where no
/// syscall failed and the refusal is ours.
public struct LockFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let path: String
    /// The failing syscall or check: `"open"`, `"flock"`, `"fstat"`,
    /// `"fchmod"`, `"ownership"`, `"permissions"`, `"file type"`.
    public let operation: String
    public let errnoValue: Int32
    /// Set when the fault came from a Swift error rather than a syscall —
    /// directory creation, which must succeed before a lock file can even be
    /// opened, and which fails as an `NSError` with no useful `errno`.
    public let underlying: String?

    public init(path: String, operation: String, errnoValue: Int32, underlying: String? = nil) {
        self.path = path
        self.operation = operation
        self.errnoValue = errnoValue
        self.underlying = underlying
    }

    public var description: String {
        if let underlying {
            return "\(path): \(operation) failed: \(underlying)"
        }
        guard errnoValue != 0 else {
            return "\(path): refused by \(operation) check"
        }
        return "\(path): \(operation) failed: \(String(cString: strerror(errnoValue))) (errno \(errnoValue))"
    }
}

/// The three genuinely different answers to "did I get the lock?".
///
/// The distinction this type exists to force is between ``busy`` and
/// ``failed``. They used to be one `false`, which meant an unwritable or
/// damaged state directory was indistinguishable from a peer legitimately
/// holding the lock — so the scheduler treated "this machine cannot back up
/// at all" as "someone else is already backing up", and skipped silently and
/// forever while every process still exited 0. See issue #110.
///
/// Only `EWOULDBLOCK`/`EAGAIN` from `flock(2)` is contention. Everything
/// else is a fault that must reach a human.
public enum LockAcquireResult: Equatable, Sendable {
    case acquired
    /// Another open file description holds the lock. Normal, expected, and
    /// the only case a caller may treat as "try again later".
    case busy
    case failed(LockFailure)
}

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
    /// lock. Safe to call repeatedly (e.g. to poll).
    ///
    /// The open is deliberately hostile to anything that is not the plain
    /// owner-only regular file we expect:
    ///
    /// - `O_NOFOLLOW` so a symlink planted at the lock path cannot redirect
    ///   the descriptor somewhere else. A symlink fails with `ELOOP`, which
    ///   is a ``LockAcquireResult/failed`` — not silently followed, and not
    ///   mistaken for contention.
    /// - `O_CLOEXEC` is defense in depth: lock descriptors are process-control
    ///   capabilities and must not leak into subprocesses. `Foundation.Process`
    ///   currently closes unknown descriptors independently, so orphan-process
    ///   safety must not rely on accidental descriptor inheritance.
    /// - `0600` on creation, then an `fstat` on the descriptor (not the
    ///   path — no second lookup to race) requiring a regular file owned by
    ///   this uid. A lock file another user can open is a lock another user
    ///   can hold, which wedges the scheduler for as long as they care to.
    public func acquire() -> LockAcquireResult {
        if fd < 0 {
            let flags = O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC
            let opened = path.path.withCString { open($0, flags, 0o600) }
            guard opened >= 0 else {
                return .failed(LockFailure(path: path.path, operation: "open", errnoValue: errno))
            }

            if let failure = Self.verify(fd: opened, path: path.path) {
                close(opened)
                return .failed(failure)
            }
            fd = opened
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            // The one contended answer. `EWOULDBLOCK` and `EAGAIN` are the
            // same value on both platforms we build for, but both spellings
            // are matched so this does not depend on that staying true.
            if code == EWOULDBLOCK || code == EAGAIN {
                return .busy
            }
            return .failed(LockFailure(path: path.path, operation: "flock", errnoValue: code))
        }
        return .acquired
    }

    /// Post-open checks on the descriptor we actually hold.
    ///
    /// Returns `nil` when the file is acceptable. A pre-existing lock file
    /// from an older release was created `0644`; that is ours and harmless,
    /// so it is tightened in place via `fchmod` rather than refused — the
    /// descriptor is already open, so there is no path to re-resolve and no
    /// window for a swap.
    private static func verify(fd: Int32, path: String) -> LockFailure? {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return LockFailure(path: path, operation: "fstat", errnoValue: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return LockFailure(path: path, operation: "file type", errnoValue: 0)
        }
        guard info.st_uid == geteuid() else {
            return LockFailure(path: path, operation: "ownership", errnoValue: 0)
        }
        if info.st_mode & (S_IRWXG | S_IRWXO) != 0 {
            guard fchmod(fd, 0o600) == 0 else {
                return LockFailure(path: path, operation: "fchmod", errnoValue: errno)
            }

            var tightened = stat()
            guard fstat(fd, &tightened) == 0 else {
                return LockFailure(path: path, operation: "fstat after fchmod", errnoValue: errno)
            }
            guard tightened.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
                return LockFailure(path: path, operation: "permissions", errnoValue: 0)
            }
        }
        return nil
    }

    /// Whether this lock file could be opened and is one of ours — without
    /// attempting to take it. Returns `nil` when it is usable.
    ///
    /// Deliberately no `flock()`. A reader that wants to know "is the lock
    /// machinery working?" must not answer it by *taking* the lock: holding
    /// `tick.lock` even briefly makes a tick starting in that instant see
    /// contention and skip its cycle, so a monitoring command run in a loop
    /// could suppress the very schedule it is checking. Opening and
    /// validating exercises everything that actually breaks — a missing or
    /// unwritable directory, a wrong owner, a symlink at the path — and
    /// contends with nothing.
    /// - Parameter createIfMissing: when `false`, a lock file that does not
    ///   exist yet is *not* created and reports no fault. Per-set lock files
    ///   are made on demand, so a read-only status query must not bring one
    ///   into being for every configured set as a side effect — but a
    ///   hostile file that already exists is still worth catching.
    public func probe(createIfMissing: Bool = true) -> LockFailure? {
        var flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC
        if createIfMissing {
            flags |= O_CREAT
        } else {
            // `fileExists` follows symlinks, so a dangling symlink looks
            // absent and would bypass the `O_NOFOLLOW` refusal below.
            var info = stat()
            let result = path.path.withCString { lstat($0, &info) }
            if result != 0 {
                let code = errno
                if code == ENOENT { return nil }
                return LockFailure(path: path.path, operation: "lstat", errnoValue: code)
            }
        }
        let opened = path.path.withCString { open($0, flags, 0o600) }
        guard opened >= 0 else {
            let code = errno
            // Raced with a deletion between the existence check and the
            // open. Nothing is there, so there is nothing wrong.
            if code == ENOENT, !createIfMissing { return nil }
            return LockFailure(path: path.path, operation: "open", errnoValue: code)
        }
        defer { close(opened) }
        return Self.verify(fd: opened, path: path.path)
    }

    /// Verifies that the effective process identity may create a new lock
    /// file without touching any production lock path or taking an `flock`.
    ///
    /// Probing only an already-existing `tick.lock` is insufficient: opening
    /// that file can succeed after the directory loses write permission,
    /// while the next set whose lock does not yet exist fails at `O_CREAT`.
    /// `faccessat(..., AT_EACCESS)` applies the same effective uid/gid that
    /// performs `open(O_CREAT)` while remaining non-mutating. This matters
    /// for `state/` and `runs/`, whose filesystem watchers recompute health:
    /// creating a probe there would trigger its own next health check.
    public static func probeCreation(in directory: URL) -> LockFailure? {
        let permitted = directory.path.withCString {
            faccessat(AT_FDCWD, $0, W_OK | X_OK, AT_EACCESS)
        }
        guard permitted == 0 else {
            return LockFailure(path: directory.path, operation: "create lock", errnoValue: errno)
        }
        return nil
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
