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
    /// The failing syscall or policy check, such as `"open"`, `"flock"`,
    /// `"fchmod"`, `"ownership"`, or `"lock directory permissions"`.
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
/// Operation and companion locks in `locks/`, `state/`, and `runs/` use this
/// type: `LOCK_EX | LOCK_NB` on an owner-controlled regular file. The lock is
/// released automatically by the kernel on
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
    private let trustedRoot: URL?
    private var fd: Int32 = -1

    /// - Parameter trustedRoot: The owner-controlled data-directory boundary
    ///   containing the lock's direct parent (`locks/`, `state/`, or
    ///   `runs/`). Production callers provide it so both directories are
    ///   opened and verified before `openat(2)` resolves the lock filename.
    public init(path: URL, trustedRoot: URL? = nil) {
        self.path = path
        self.trustedRoot = trustedRoot
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
            let opened: Int32
            switch Self.openLock(path: path, trustedRoot: trustedRoot, flags: flags) {
            case .success(let descriptor):
                opened = descriptor
            case .failure(let failure):
                return .failed(failure)
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
    /// from an older release may be `0644`, while a restrictive umask can
    /// strip the owner bits from a newly created inode. Either non-exact mode
    /// is repaired to `0600` through the descriptor rather than accepted —
    /// there is no path to re-resolve and no window for a swap.
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
        if info.st_mode & 0o777 != 0o600 {
            guard fchmod(fd, 0o600) == 0 else {
                return LockFailure(path: path, operation: "fchmod", errnoValue: errno)
            }

            var tightened = stat()
            guard fstat(fd, &tightened) == 0 else {
                return LockFailure(path: path, operation: "fstat after fchmod", errnoValue: errno)
            }
            guard tightened.st_mode & 0o777 == 0o600 else {
                return LockFailure(path: path, operation: "permissions", errnoValue: 0)
            }
        }
        return nil
    }

    /// Opens the lock through a verified parent-directory descriptor. This
    /// prevents a group/world-writable parent from unlinking the flocked
    /// inode and substituting a second inode at the same pathname.
    private static func openLock(
        path: URL,
        trustedRoot: URL?,
        flags: Int32
    ) -> Result<Int32, LockFailure> {
        let parent = path.deletingLastPathComponent()
        let parentFD: Int32
        switch openDirectory(parent, trustedRoot: trustedRoot) {
        case .success(let descriptor):
            parentFD = descriptor
        case .failure(let failure):
            return .failure(failure)
        }
        defer { close(parentFD) }

        let (opened, openError) = path.lastPathComponent.withCString { name -> (Int32, Int32) in
            // On Darwin/APFS, simultaneous first-time `openat(O_CREAT)`
            // calls for the same basename can transiently return ENOENT even
            // though the already-open parent descriptor is valid and there
            // are no intermediate path components. Retry only that otherwise
            // impossible creating case; a deleted parent keeps returning
            // ENOENT and still fails closed a few milliseconds later.
            for attempt in 0..<5 {
                let descriptor = openat(parentFD, name, flags, 0o600)
                if descriptor >= 0 { return (descriptor, 0) }
                let code = errno
                if code != ENOENT || flags & O_CREAT == 0 || attempt == 4 {
                    return (descriptor, code)
                }
                usleep(1_000)
            }
            return (-1, ENOENT) // The loop always returns; keeps Swift exhaustive.
        }
        guard opened >= 0 else {
            return .failure(LockFailure(path: path.path, operation: "open", errnoValue: openError))
        }
        return .success(opened)
    }

    /// Opens `directory` without following symlinks and verifies its owner
    /// and replacement safety. The immediate lock parent rejects every
    /// group/world write bit. The trusted root additionally accepts normal
    /// sticky-directory protection and write-without-search modes; its
    /// owner-owned child is still not replaceable by another uid. When a
    /// trusted root is supplied, the root is itself resolved with `openat`
    /// through its verified immediate parent, and the child is then resolved
    /// through the already-verified root descriptor.
    private static func openDirectory(
        _ directory: URL,
        trustedRoot: URL?
    ) -> Result<Int32, LockFailure> {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let directoryPath = directory.standardizedFileURL.path

        guard let trustedRoot else {
            let (opened, openError) = directoryPath.withCString { name -> (Int32, Int32) in
                let descriptor = open(name, flags)
                return (descriptor, descriptor < 0 ? errno : 0)
            }
            guard opened >= 0 else {
                return .failure(LockFailure(
                    path: directoryPath, operation: "open lock directory", errnoValue: openError
                ))
            }
            if let failure = verifyDirectory(fd: opened, path: directoryPath, isTrustedRoot: false) {
                close(opened)
                return .failure(failure)
            }
            return .success(opened)
        }

        let rootPath = trustedRoot.standardizedFileURL.path
        let rootFD: Int32
        switch openTrustedRoot(trustedRoot, flags: flags) {
        case .success(let descriptor):
            rootFD = descriptor
        case .failure(let failure):
            return .failure(failure)
        }
        if directoryPath == rootPath {
            return .success(rootFD)
        }
        defer { close(rootFD) }

        guard directory.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
            return .failure(LockFailure(
                path: directoryPath, operation: "trusted directory boundary", errnoValue: 0
            ))
        }
        let (opened, openError) = directory.lastPathComponent.withCString { name -> (Int32, Int32) in
            let descriptor = openat(rootFD, name, flags)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard opened >= 0 else {
            return .failure(LockFailure(
                path: directoryPath, operation: "open lock directory", errnoValue: openError
            ))
        }
        if let failure = verifyDirectory(fd: opened, path: directoryPath, isTrustedRoot: false) {
            close(opened)
            return .failure(failure)
        }
        return .success(opened)
    }

    /// Opens the trusted root through its immediate parent descriptor. The
    /// parent is the deliberate outer boundary: its own ancestors and ACLs
    /// remain deployment concerns, but another local uid must not be able to
    /// rename this root entry and make a later helper lock a different tree.
    private static func openTrustedRoot(
        _ trustedRoot: URL,
        flags: Int32
    ) -> Result<Int32, LockFailure> {
        let root = trustedRoot.standardizedFileURL
        let rootPath = root.path
        let parent = root.deletingLastPathComponent().standardizedFileURL

        // The filesystem root has no replaceable parent entry.
        if parent.path == rootPath {
            let (opened, openError) = rootPath.withCString { name -> (Int32, Int32) in
                let descriptor = open(name, flags)
                return (descriptor, descriptor < 0 ? errno : 0)
            }
            guard opened >= 0 else {
                return .failure(LockFailure(
                    path: rootPath, operation: "open lock root", errnoValue: openError
                ))
            }
            if let failure = verifyDirectory(fd: opened, path: rootPath, isTrustedRoot: true) {
                close(opened)
                return .failure(failure)
            }
            return .success(opened)
        }

        let parentFD: Int32
        switch openTrustedRootParent(for: root, flags: flags) {
        case .success(let descriptor):
            parentFD = descriptor
        case .failure(let failure):
            return .failure(failure)
        }
        defer { close(parentFD) }

        let (opened, openError) = root.lastPathComponent.withCString { name -> (Int32, Int32) in
            let descriptor = openat(parentFD, name, flags)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard opened >= 0 else {
            return .failure(LockFailure(
                path: rootPath, operation: "open lock root", errnoValue: openError
            ))
        }
        if let failure = verifyDirectory(fd: opened, path: rootPath, isTrustedRoot: true) {
            close(opened)
            return .failure(failure)
        }
        return .success(opened)
    }

    /// Refuses a replaceable data-root entry before setup creates or opens
    /// it. This is internal so `AppPaths.ensureDirectories()` can apply the
    /// same boundary before recreating a missing root after a rename.
    static func validateTrustedRootParent(for trustedRoot: URL) -> LockFailure? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        switch openTrustedRootParent(for: trustedRoot.standardizedFileURL, flags: flags) {
        case .success(let descriptor):
            close(descriptor)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    private static func openTrustedRootParent(
        for trustedRoot: URL,
        flags: Int32
    ) -> Result<Int32, LockFailure> {
        let rootPath = trustedRoot.path
        let parent = trustedRoot.deletingLastPathComponent().standardizedFileURL
        let parentPath = parent.path
        guard parentPath != rootPath else {
            return .failure(LockFailure(
                path: parentPath, operation: "lock root parent boundary", errnoValue: 0
            ))
        }

        let (parentFD, openError) = parentPath.withCString { name -> (Int32, Int32) in
            let descriptor = open(name, flags)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard parentFD >= 0 else {
            return .failure(LockFailure(
                path: parentPath, operation: "open lock root parent", errnoValue: openError
            ))
        }
        if let failure = verifyTrustedRootParent(fd: parentFD, path: parentPath) {
            close(parentFD)
            return .failure(failure)
        }
        return .success(parentFD)
    }

    private static func verifyTrustedRootParent(fd: Int32, path: String) -> LockFailure? {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return LockFailure(path: path, operation: "fstat lock root parent", errnoValue: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return LockFailure(path: path, operation: "lock root parent type", errnoValue: 0)
        }

        let effectiveUID = geteuid()
        guard info.st_uid == effectiveUID || info.st_uid == 0 else {
            return LockFailure(path: path, operation: "lock root parent ownership", errnoValue: 0)
        }

        let groupCanReplace = info.st_mode & (S_IWGRP | S_IXGRP) == (S_IWGRP | S_IXGRP)
        let otherCanReplace = info.st_mode & (S_IWOTH | S_IXOTH) == (S_IWOTH | S_IXOTH)
        let sticky = info.st_mode & S_ISVTX != 0
        guard !(groupCanReplace || otherCanReplace) || sticky else {
            return LockFailure(path: path, operation: "lock root parent permissions", errnoValue: 0)
        }
        return nil
    }

    private static func verifyDirectory(
        fd: Int32,
        path: String,
        isTrustedRoot: Bool
    ) -> LockFailure? {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            return LockFailure(path: path, operation: "fstat lock directory", errnoValue: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return LockFailure(path: path, operation: "lock directory type", errnoValue: 0)
        }
        guard info.st_uid == geteuid() else {
            return LockFailure(path: path, operation: "lock directory ownership", errnoValue: 0)
        }
        let writableByOthers = info.st_mode & (S_IWGRP | S_IWOTH) != 0
        let searchableWriter = (info.st_mode & (S_IWGRP | S_IXGRP)) == (S_IWGRP | S_IXGRP)
            || (info.st_mode & (S_IWOTH | S_IXOTH)) == (S_IWOTH | S_IXOTH)
        let sticky = info.st_mode & S_ISVTX != 0
        // The immediate lock parent is stricter: another uid must not be
        // able to create even an absent lock entry or replace a live one.
        // At the owner-controlled root boundary, ordinary sticky-directory
        // semantics protect our owner-owned child directory; write without
        // search permission cannot modify entries either.
        let unsafePermissions = isTrustedRoot
            ? (searchableWriter && !sticky)
            : writableByOthers
        guard !unsafePermissions else {
            return LockFailure(path: path, operation: "lock directory permissions", errnoValue: 0)
        }
        return nil
    }

    /// Creates if needed, then tightens an owner directory through verified
    /// parent descriptors. The child is opened with `O_NOFOLLOW`, so a
    /// hostile parent cannot redirect creation or permission repair.
    static func ensureDirectory(
        _ directory: URL,
        parent: URL,
        trustedRoot: URL,
        mode: mode_t,
        tightenExisting: Bool = true
    ) -> LockFailure? {
        let directoryPath = directory.standardizedFileURL.path
        guard directory.deletingLastPathComponent().standardizedFileURL.path
                == parent.standardizedFileURL.path else {
            return LockFailure(
                path: directoryPath,
                operation: "trusted directory boundary",
                errnoValue: 0
            )
        }

        let parentFD: Int32
        switch openDirectory(parent, trustedRoot: trustedRoot) {
        case .success(let descriptor):
            parentFD = descriptor
        case .failure(let failure):
            return failure
        }
        defer { close(parentFD) }

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var createdDirectory = false
        let (directoryFD, openError, failureOperation) = directory.lastPathComponent.withCString {
            name -> (Int32, Int32, String?) in
            var descriptor = openat(parentFD, name, flags)
            var code = descriptor < 0 ? errno : 0
            if descriptor < 0, code == ENOENT {
                let created = mkdirat(parentFD, name, mode)
                let createError = created != 0 ? errno : 0
                guard created == 0 || createError == EEXIST else {
                    return (descriptor, createError, "create protected directory")
                }
                if created == 0 {
                    createdDirectory = true
                    // mkdirat applies umask, so a restrictive service umask
                    // can produce mode 0000 and make the new directory
                    // impossible to reopen. Pin the entry through the already
                    // verified parent before the first open.
                    guard fchmodat(parentFD, name, mode, 0) == 0 else {
                        return (-1, errno, "fchmod created protected directory")
                    }
                }
                descriptor = openat(parentFD, name, flags)
                code = descriptor < 0 ? errno : 0
            }
            return (descriptor, code, nil)
        }
        guard directoryFD >= 0 else {
            return LockFailure(
                path: directoryPath,
                operation: failureOperation ?? "open protected directory",
                errnoValue: openError
            )
        }
        defer { close(directoryFD) }

        var info = stat()
        guard fstat(directoryFD, &info) == 0 else {
            return LockFailure(path: directoryPath, operation: "fstat protected directory", errnoValue: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return LockFailure(path: directoryPath, operation: "protected directory type", errnoValue: 0)
        }
        guard info.st_uid == geteuid() else {
            return LockFailure(path: directoryPath, operation: "protected directory ownership", errnoValue: 0)
        }

        if info.st_mode & 0o777 != mode, createdDirectory || tightenExisting {
            guard fchmod(directoryFD, mode) == 0 else {
                return LockFailure(path: directoryPath, operation: "fchmod protected directory", errnoValue: errno)
            }
            guard fstat(directoryFD, &info) == 0 else {
                return LockFailure(
                    path: directoryPath,
                    operation: "fstat after protected directory fchmod",
                    errnoValue: errno
                )
            }
            guard info.st_mode & 0o777 == mode else {
                return LockFailure(path: directoryPath, operation: "protected directory permissions", errnoValue: 0)
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
        }
        let opened: Int32
        switch Self.openLock(path: path, trustedRoot: trustedRoot, flags: flags) {
        case .success(let descriptor):
            opened = descriptor
        case .failure(let failure):
            // The descriptor-relative `openat` found nothing. A non-creating
            // probe treats absence as healthy, while `O_NOFOLLOW` still
            // refuses both live and dangling symlinks with `ELOOP`.
            if failure.errnoValue == ENOENT, !createIfMissing { return nil }
            return failure
        }
        defer { close(opened) }
        return Self.verify(fd: opened, path: path.path)
    }

    /// Exercises the actual `flock(2)` capability on a dedicated health
    /// inode. Contention itself proves the filesystem supports locking, so a
    /// concurrent health probe is healthy; only a real acquisition failure
    /// is returned.
    public func probeLocking() -> LockFailure? {
        switch acquire() {
        case .acquired:
            release()
            return nil
        case .busy:
            return nil
        case .failed(let failure):
            return failure
        }
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
    public static func probeCreation(in directory: URL, trustedRoot: URL? = nil) -> LockFailure? {
        let directoryFD: Int32
        switch openDirectory(directory, trustedRoot: trustedRoot) {
        case .success(let descriptor):
            directoryFD = descriptor
        case .failure(let failure):
            return failure
        }
        defer { close(directoryFD) }

        let permitted = ".".withCString {
            faccessat(directoryFD, $0, W_OK | X_OK, AT_EACCESS)
        }
        guard permitted == 0 else {
            return LockFailure(path: directory.path, operation: "create lock", errnoValue: errno)
        }
        return nil
    }

    /// Creates and removes a uniquely named owner-only file in a dedicated
    /// probe directory. Unlike an access-mode check, this exercises inode
    /// allocation and therefore catches quota exhaustion and a full
    /// filesystem before a production lock needs to be created.
    public static func probeActualCreation(in directory: URL) -> LockFailure? {
        let directoryFD: Int32
        switch openDirectory(directory, trustedRoot: nil) {
        case .success(let descriptor):
            directoryFD = descriptor
        case .failure(let failure):
            return failure
        }
        defer { close(directoryFD) }

        let name = "probe-\(UUID().uuidString)"
        let (created, createError) = name.withCString { namePointer -> (Int32, Int32) in
            let descriptor = openat(
                directoryFD,
                namePointer,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        guard created >= 0 else {
            return LockFailure(path: directory.path, operation: "create lock probe", errnoValue: createError)
        }
        close(created)

        let (removed, removeError) = name.withCString { namePointer -> (Int32, Int32) in
            let result = unlinkat(directoryFD, namePointer, 0)
            return (result, result != 0 ? errno : 0)
        }
        guard removed == 0 else {
            return LockFailure(path: directory.path, operation: "remove lock probe", errnoValue: removeError)
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
