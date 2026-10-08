import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Crash-durable writes for `config.json`, `machine.json`, the migration
/// backups (#159) and `global-excludes.json`.
///
/// `rename(2)` is atomic for *readers* — nobody sees a half-written file —
/// and that is all it promises. After a power cut the target can come back
/// empty or truncated (the temp file's bytes were still in the page cache
/// when the rename became visible), or as its previous contents (the rename
/// itself was not yet on disk). The full sequence is: write the temp file →
/// `fsync` it → `rename(2)` → `fsync` the containing directory, which is what
/// `StateStore.writeDurably` already does for schedule state.
///
/// Errors before the rename leave the target untouched and are ordinary
/// failures (`LockFailure`, the package's errno-carrying I/O failure).
///
/// **After the rename, nothing throws.** The new file is live, and every
/// caller's notion of "the write failed" means "the old file is still
/// there" — a third, possibly-committed outcome leaked into each of them in
/// turn (#165 review). So a directory sync that fails after the rename is
/// reported on stderr and the write counts as done: the file is installed,
/// and the only exposure is to a power cut in the next moments, which an
/// `EIO` on the directory has already made the least of this disk's
/// problems.
enum DurableFile {
    /// `fsync(2)`, replaceable only by tests (task-local, so a test's
    /// injected failure cannot leak into a concurrently running test).
    @TaskLocal static var sync: @Sendable (Int32) -> Int32 = { descriptor in
        #if canImport(Darwin)
        Darwin.fsync(descriptor)
        #elseif canImport(Glibc)
        Glibc.fsync(descriptor)
        #elseif canImport(Musl)
        Musl.fsync(descriptor)
        #endif
    }

    /// Writes `data` to `tempFile` and syncs it, then renames it over `url`
    /// and syncs the directory. `mode` is filtered by the umask exactly as
    /// `Data.write(to:)` was, so existing files keep their permissions.
    static func write(_ data: Data, to url: URL, via tempFile: URL, mode: mode_t = 0o644) throws {
        try writeSynced(data, to: tempFile, exclusive: false, mode: mode)
        try AtomicFile.rename(from: tempFile, to: url)
        syncDirectoryAfterInstall(of: url)
    }

    /// Creates `url` only if it does not exist (`O_EXCL`), durably. Returns
    /// `false` when it already existed. The migration backup uses this: the
    /// source config is only overwritten once its backup is on disk, so —
    /// unlike an install — a directory sync failure here is a failure, and
    /// the unconfirmed entry is removed so no later run can mistake it for
    /// a durable backup.
    static func createExclusive(_ data: Data, at url: URL, mode: mode_t = 0o644) throws -> Bool {
        do {
            try writeSynced(data, to: url, exclusive: true, mode: mode)
        } catch let failure as LockFailure where failure.errnoValue == EEXIST {
            return false
        }
        do {
            try syncDirectory(of: url)
        } catch {
            unlink(url.path)
            throw error
        }
        return true
    }

    /// Writes and syncs a file that is not yet visible under its final name
    /// (a temp file, or an `O_EXCL` create). Removes a partial file on
    /// failure, except when `O_EXCL` found someone else's.
    static func writeSynced(_ data: Data, to url: URL, exclusive: Bool, mode: mode_t = 0o644) throws {
        let flags = O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : O_TRUNC)
        let descriptor = url.path.withCString { open($0, flags, mode) }
        guard descriptor >= 0 else {
            throw LockFailure(path: url.path, operation: "open", errnoValue: errno)
        }
        var closed = false
        func discard() {
            if !closed { close(descriptor); closed = true }
            unlink(url.path)
        }

        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Foundation.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw LockFailure(path: url.path, operation: "write", errnoValue: errno)
                    }
                    offset += written
                }
            }
            try syncDescriptor(descriptor, path: url.path, operation: "fsync")
        } catch {
            discard()
            throw error
        }
        closed = true
        if close(descriptor) != 0 {
            let code = errno
            unlink(url.path)
            throw LockFailure(path: url.path, operation: "close", errnoValue: code)
        }
    }

    /// Removes `url` and syncs its directory, so a reboot cannot resurrect
    /// a file a caller reported removed. An absent file is not an error.
    /// The unlink is the commit point, as the rename is for a write: a
    /// directory sync that fails after it is reported, not thrown.
    static func remove(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            throw LockFailure(path: url.path, operation: "unlink", errnoValue: errno)
        }
        syncDirectoryAfterInstall(of: url, removed: true)
    }

    /// Syncs the directory holding an already-installed (or just-removed)
    /// file, reporting a failure on stderr instead of throwing (see the
    /// type's note).
    static func syncDirectoryAfterInstall(of url: URL, removed: Bool = false) {
        do {
            try syncDirectory(of: url)
        } catch {
            StandardStream.write(
                Data(("restic-station: \(url.path) is \(removed ? "removed" : "saved"), but syncing its "
                    + "directory to disk failed (\(error)); it may not survive a power loss\n").utf8),
                to: .standardError
            )
        }
    }

    static func syncDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw LockFailure(path: directory.path, operation: "open directory for fsync", errnoValue: errno)
        }
        defer { close(descriptor) }
        try syncDescriptor(descriptor, path: directory.path, operation: "fsync directory")
    }

    private static func syncDescriptor(_ descriptor: Int32, path: String, operation: String) throws {
        while sync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw LockFailure(path: path, operation: operation, errnoValue: errno)
        }
    }
}
