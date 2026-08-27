import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The identity of a specific inode, as `(st_dev, st_ino)`.
///
/// Two paths naming the same inode compare equal; a path whose directory
/// entry has been replaced does not. Read it from a descriptor you hold, never
/// from a second pathname lookup — the point is to avoid the lookup.
public struct InodeIdentity: Equatable, Sendable {
    public let deviceID: dev_t
    public let inode: ino_t

    public init(deviceID: dev_t, inode: ino_t) {
        self.deviceID = deviceID
        self.inode = inode
    }

    /// `nil` when the descriptor cannot be stat'ed at all.
    public init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(deviceID: info.st_dev, inode: info.st_ino)
    }
}

/// An open, verified handle to one directory inside the data root.
///
/// **Why this type exists.** A pathname is not a directory; it is a lookup
/// that can resolve somewhere else next time. `state/` can be renamed and
/// recreated between any two opens, so a component that validated something
/// through one pathname open and consumed it through another was never
/// holding the two together — it was re-checking "recently", which
/// `AGENTS.md` §Safety rule 1 rules out for exactly this reason.
///
/// Holding the descriptor makes the directory generation a property of the
/// handle. Every name resolved through it — the lock file, the canonical
/// document, the migration marker, each durable temp and its rename — lands
/// in the same directory inode, and keeps doing so even if the pathname is
/// swapped underneath. That is what lets a schedule-state lease publish its
/// watermark into the tree its lock actually protects.
///
/// The directory is opened and verified by the same code path `FileLock`
/// uses for a lock's parent (`O_NOFOLLOW`, owner-checked, no group/world
/// write), so this adds retention rather than a second security policy.
public final class DirectoryHandle: @unchecked Sendable {
    public let path: URL
    private var storedDescriptor: Int32

    private init(path: URL, descriptor: Int32) {
        self.path = path
        self.storedDescriptor = descriptor
    }

    /// `lstat(2)` of a directory pathname, returning `nil` for anything that
    /// is not a directory.
    ///
    /// **Diagnosis only.** A pathname lookup is not bound to any descriptor,
    /// so nothing that grants authority may depend on it. It exists for the
    /// cases where no descriptor can be obtained at all — a directory this
    /// user cannot open — and where the only decision left is which refusal
    /// to report.
    static func directoryStatByPathname(_ path: String) -> stat? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { return nil }
        return info
    }

    /// Opens and verifies `directory`, retaining the descriptor.
    ///
    /// - Parameter trustedRoot: the owner-controlled data-directory boundary
    ///   containing `directory`, resolved and verified first — the same
    ///   contract as `FileLock.init(path:trustedRoot:)`.
    public static func open(
        _ directory: URL,
        trustedRoot: URL?
    ) -> Result<DirectoryHandle, LockFailure> {
        switch FileLock.openVerifiedDirectory(directory, trustedRoot: trustedRoot) {
        case .success(let descriptor):
            return .success(DirectoryHandle(path: directory, descriptor: descriptor))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Takes ownership of a directory descriptor the caller has already
    /// opened and verified.
    ///
    /// For components that must open through their own injectable syscall
    /// seam (so tests can simulate an unopenable or hostile directory) but
    /// still want one retained generation for every later `*at(2)` call. The
    /// handle closes the descriptor on deinit; the caller must not.
    ///
    /// The caller owns the verification in this route, and this type cannot
    /// enforce it. Open with at least `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`
    /// and, on the descriptor, refuse anything that is not a directory owned
    /// by the effective uid, and any group- or world-writable mode — the
    /// policy ``FileLock/verifyDirectory`` applies to an immediate lock
    /// parent, since a directory adopted here is generally exactly that.
    ///
    /// Note this route deliberately does *not* reproduce
    /// ``open(_:trustedRoot:)`` in full: there is no trusted-root chain, so
    /// nothing here verifies the ancestors above `path`. Adopt only a
    /// directory whose parentage the caller has already established by other
    /// means.
    public static func adopting(descriptor: Int32, path: URL) -> DirectoryHandle {
        DirectoryHandle(path: path, descriptor: descriptor)
    }

    /// The retained descriptor. Valid for the lifetime of this handle and
    /// never handed out beyond it — callers pass it straight to an `*at(2)`
    /// call rather than storing it.
    public var descriptor: Int32 { storedDescriptor }

    /// Identity of the directory this handle holds open.
    public var identity: InodeIdentity? { InodeIdentity(descriptor: storedDescriptor) }

    /// Identity of a direct child, resolved through this handle without
    /// following a final symlink. `nil` when the entry is absent or unusable.
    public func identity(ofEntry name: String) -> InodeIdentity? {
        var info = stat()
        let result = name.withCString { entry in
            fstatat(storedDescriptor, entry, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { return nil }
        return InodeIdentity(deviceID: info.st_dev, inode: info.st_ino)
    }

    deinit {
        if storedDescriptor >= 0 {
            close(storedDescriptor)
            storedDescriptor = -1
        }
    }
}
