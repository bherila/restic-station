import Foundation
import ResticStationPOSIX

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Descriptor-relative inspection. Inventories never follow a link, turn
/// an I/O error into an empty tree, or load a large file into memory.
public enum SourceSyncFilesystem {
    @TaskLocal static var rootCreation: @Sendable (Int32) throws -> String = { descriptor in
        var seconds: Int64 = 0
        var nanoseconds: Int32 = 0
        guard rs_sync_creation_time(descriptor, &seconds, &nanoseconds) == 0 else {
            throw SourceSyncError.unsafeRoot("This drive does not support safe folder identity checks. Choose another local filesystem for synchronization.")
        }
        return "\(seconds):\(nanoseconds)"
    }

    static func rootIdentity(_ root: DirectoryHandle) throws -> String {
        guard let identity = root.identity else { throw changed() }
        // Inode numbers may be reused after a directory is removed. Its
        // immutable creation generation distinguishes recreation from an
        // intentional edit/delete inside the original folder.
        return "\(identity.deviceID):\(identity.inode):\(try rootCreation(root.descriptor))"
    }
    public static func physicalDirectory(_ path: String) throws -> String {
        guard SourceSyncGroup.isAbsoluteCanonical(path), let resolved = realpath(path, nil) else { throw changed() }
        defer { free(resolved) }
        let physical = String(cString: resolved)
        guard !CloudStorageSafety.reachesCloudStorage(physical) else {
            throw SourceSyncError.unsafeRoot("Choose a folder outside a cloud-sync provider.")
        }
        return physical
    }

    public static func inventory(at path: String) throws -> SyncInventory {
        guard SourceSyncGroup.isAbsoluteCanonical(path),
              !CloudStorageSafety.reachesCloudStorage(path) else {
            throw SourceSyncError.unsafeRoot("Choose an absolute local folder outside a cloud-sync provider.")
        }
        let root = try openRoot(path)
        let identity = try rootIdentity(root)
        var items: [String: SyncItem] = [:]
        var names: Set<String> = []
        try scan(root, relative: "", items: &items, names: &names)
        return SyncInventory(rootIdentity: identity, items: items)
    }

    static func openRoot(_ path: String) throws -> DirectoryHandle {
        // Pin each component, including parents, before descending. A
        // no-follow open of only the final component is not sufficient.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw changed() }
        for part in path.split(separator: "/") {
            let next = String(part).withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(fd)
            guard next >= 0 else { throw changed() }
            fd = next
            do { try refuseRepository(fd) }
            catch { close(fd); throw error }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw SourceSyncError.unsafeRoot("The sync folder must be owned by this user and not writable by other users.")
        }
        return DirectoryHandle.adopting(descriptor: fd, path: URL(fileURLWithPath: path))
    }

    static func openDirectory(_ name: String, in parent: DirectoryHandle) throws -> DirectoryHandle {
        let fd = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw changed() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            close(fd)
            throw SourceSyncError.unsafeRoot("A sync subfolder is writable by another user or cannot be inspected safely.")
        }
        return DirectoryHandle.adopting(descriptor: fd, path: parent.path.appendingPathComponent(name))
    }

    /// Both sealed exports and installed directory candidates must carry
    /// the manifest mode independently of the helper's process umask.
    static func createDirectory(_ name: String, in parent: DirectoryHandle, mode: UInt16) throws -> DirectoryHandle {
        guard mode & ~UInt16(0o777) == 0, mode & 0o022 == 0 else { throw changed() }
        let result = name.withCString { mkdirat(parent.descriptor, $0, 0o700) }
        guard result == 0 || errno == EEXIST else { throw changed() }
        let directory = try openDirectory(name, in: parent)
        guard fchmod(directory.descriptor, mode_t(mode)) == 0, fsync(directory.descriptor) == 0,
              fsync(parent.descriptor) == 0 else { throw changed() }
        return directory
    }

    /// Parent handles remain bound even if their pathname is renamed.
    static func parent(of path: String, in root: DirectoryHandle, create: Bool = false) throws -> (DirectoryHandle, String) {
        guard SourceSyncPlanner.isRelativePath(path) else { throw changed() }
        var parts = path.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        var directory = root
        for part in parts {
            if create {
                let result = part.withCString { mkdirat(directory.descriptor, $0, 0o700) }
                guard result == 0 || errno == EEXIST else { throw changed() }
                if result == 0, fsync(directory.descriptor) != 0 { throw changed() }
            }
            directory = try openDirectory(part, in: directory)
        }
        return (directory, leaf)
    }

    /// Receipt verification may encounter an ancestor removed by a later
    /// operation. Only ENOENT means absence; links and inspection errors
    /// still refuse. The root itself was opened and identity-checked first.
    static func item(at path: String, in root: DirectoryHandle) throws -> SyncItem? {
        guard SourceSyncPlanner.isRelativePath(path) else { throw changed() }
        var parts = path.split(separator: "/").map(String.init)
        let leaf = parts.removeLast()
        var directory = root
        for part in parts {
            var info = stat()
            if part.withCString({ fstatat(directory.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
                if errno == ENOENT { return nil }
                throw changed()
            }
            directory = try openDirectory(part, in: directory)
        }
        return try item(named: leaf, in: directory, relative: path)
    }

    static func item(named name: String, in parent: DirectoryHandle, relative: String, synchronize: Bool = false) throws -> SyncItem? {
        var info = stat()
        let result = name.withCString { fstatat(parent.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw changed()
        }
        let mode = UInt16(info.st_mode & 0o777)
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR):
            return SyncItem(kind: .directory, digest: "", mode: mode)
        case mode_t(S_IFREG):
            guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw SourceSyncError.unsafeRoot("A sync file is owned or writable by another user.")
            }
            let fd = name.withCString { openat(parent.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard fd >= 0 else { throw changed() }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  stamp(info) == stamp(before) else { throw changed() }
            let digest = try SHA256Digest.fileHex(descriptor: fd)
            guard fstat(fd, &after) == 0, stamp(before) == stamp(after) else { throw changed() }
            if synchronize, SyncDurability.synchronize(fd) != 0 {
                throw SourceSyncError.stateInvalid("The incoming file could not be made durable before installation.")
            }
            return SyncItem(digest: digest, bytes: UInt64(after.st_size), mode: mode)
        case mode_t(S_IFLNK):
            let target = try linkTarget(named: name, in: parent)
            guard safeLink(target, relative: relative) else {
                throw SourceSyncError.unsafeRoot("A symbolic link leaves the selected sync folder.")
            }
            // Link permission bits are not portable (Darwin vs Linux).
            return SyncItem(kind: .symbolicLink, digest: SHA256Digest.hex(Data(target.utf8)), bytes: UInt64(target.utf8.count), mode: 0)
        default:
            throw SourceSyncError.unsafeRoot("Sync supports ordinary files, directories, and internal symbolic links only.")
        }
    }

    static func linkTarget(named name: String, in parent: DirectoryHandle) throws -> String {
        var bytes = [CChar](repeating: 0, count: 4097)
        // readlinkat's imported raw-pointer signature must receive the
        // array's element storage, not the address of its Swift value.
        // Older Swift toolchains do not bridge &Array at this boundary.
        let count = bytes.withUnsafeMutableBufferPointer { storage -> Int in
            guard let address = storage.baseAddress else { return -1 }
            return name.withCString { readlinkat(parent.descriptor, $0, address, storage.count) }
        }
        guard count >= 0, count < bytes.count,
              let target = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw changed() }
        return target
    }

    /// Seals a planned value into private staging through pinned handles.
    /// rsync subsequently reads this copy, never a mutable live pathname.
    static func exportItem(_ path: String, expected: SyncItem, from source: DirectoryHandle, to staging: DirectoryHandle) throws {
        let (from, name) = try parent(of: path, in: source)
        let (to, target) = try parent(of: path, in: staging, create: true)
        if let existing = try item(named: target, in: to, relative: path) {
            guard existing == expected else { throw SourceSyncError.stalePlan }
            return
        }
        guard try item(named: name, in: from, relative: path) == expected else { throw SourceSyncError.stalePlan }
        switch expected.kind {
        case .directory:
            _ = try createDirectory(target, in: to, mode: expected.mode)
        case .symbolicLink:
            let destination = try linkTarget(named: name, in: from)
            guard destination.withCString({ link in target.withCString { symlinkat(link, to.descriptor, $0) } }) == 0 else { throw changed() }
        case .file:
            let inputFD = name.withCString { openat(from.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard inputFD >= 0 else { throw changed() }
            let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
            let outputFD = target.withCString { openat(to.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(expected.mode)) }
            guard outputFD >= 0 else { throw changed() }
            let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
            while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try output.write(contentsOf: bytes)
            }
            guard fchmod(outputFD, mode_t(expected.mode)) == 0, fsync(outputFD) == 0 else { throw changed() }
            try output.close()
        }
        guard fsync(to.descriptor) == 0, try item(named: target, in: to, relative: path) == expected else {
            throw SourceSyncError.stalePlan
        }
    }

    private static func safeLink(_ target: String, relative: String) -> Bool {
        guard !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var parts = relative.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return false }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        return true
    }

    private static func scan(
        _ directory: DirectoryHandle, relative: String,
        items: inout [String: SyncItem], names: inout Set<String>
    ) throws {
        try refuseRepository(directory.descriptor)
        var before = stat(), after = stat()
        guard fstat(directory.descriptor, &before) == 0 else { throw changed() }
        // A separate open file description has its own directory offset;
        // dup() shares the original offset and also drops close-on-exec.
        let copied = openat(directory.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copied >= 0 else { throw changed() }
        guard let stream = fdopendir(copied) else { close(copied); throw changed() }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw changed() }
                break
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw SourceSyncError.unsafeRoot("A filename cannot be represented safely on both computers.") }
            if name == "." || name == ".." { continue }
            guard !name.hasPrefix(".restic-station-sync-") else {
                throw SourceSyncError.unsafeRoot("This folder contains synchronization recovery storage. Choose the specific child folder to synchronize.")
            }
            let path = relative.isEmpty ? name : relative + "/" + name
            let folded = path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard names.insert(folded).inserted else {
                throw SourceSyncError.unsafeRoot("Two filenames differ only by case or Unicode normalization.")
            }
            guard let value = try item(named: name, in: directory, relative: path) else { throw changed() }
            items[path] = value
            if value.kind == .directory {
                try scan(openDirectory(name, in: directory), relative: path, items: &items, names: &names)
            }
        }
        guard fstat(directory.descriptor, &after) == 0, stamp(before) == stamp(after) else { throw changed() }
    }

    private static func stamp(_ info: stat) -> [Int64] {
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_size), Int64(info.st_mode),
                Int64(modified.tv_sec), Int64(modified.tv_nsec), Int64(changed.tv_sec), Int64(changed.tv_nsec)]
    }

    static func changed() -> SourceSyncError {
        .unsafeRoot("A folder changed or could not be inspected safely. Preview the changes again.")
    }

    /// A live replica must never be a Restic repository, one of its
    /// descendants, or a parent that would transfer the repository tree.
    /// The standard on-disk layout is sufficient for a conservative refusal;
    /// no password or repository contents need to be read by an SSH worker.
    private static func refuseRepository(_ fd: Int32) throws {
        let layout: [(String, mode_t)] = [("config", mode_t(S_IFREG)), ("data", mode_t(S_IFDIR)),
            ("index", mode_t(S_IFDIR)), ("keys", mode_t(S_IFDIR)), ("locks", mode_t(S_IFDIR)), ("snapshots", mode_t(S_IFDIR))]
        for (name, type) in layout {
            var info = stat()
            if name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
                if errno == ENOENT { return }
                throw changed()
            }
            if info.st_mode & mode_t(S_IFMT) != type { return }
        }
        throw SourceSyncError.unsafeRoot("Backup repositories cannot be live sync folders. Choose the original files rather than the backup storage.")
    }

    /// Enumerate a pinned directory, independently of pathname aliases and
    /// other readers' directory offsets. Errors never become an empty list.
    static func entryNames(in directory: DirectoryHandle) throws -> [String] {
        let fd = openat(directory.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw changed() }
        guard let stream = fdopendir(fd) else { close(fd); throw changed() }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else { if errno != 0 { throw changed() }; break }
            let leaf: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
            }
            guard let leaf else { throw changed() }
            if leaf != "." && leaf != ".." { names.append(leaf) }
        }
        return names
    }

    /// Used only for private, already-protected operation storage, never a
    /// live source. Descend through retained descriptors without following
    /// symbolic links; an unexpected type or I/O error refuses cleanup.
    static func removeTree(_ name: String, in directory: DirectoryHandle) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw changed() }
        var info = stat()
        if name.withCString({ fstatat(directory.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) != 0 {
            if errno == ENOENT { return }
            throw changed()
        }
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            let child = try openDirectory(name, in: directory)
            let fd = openat(child.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw changed() }
            guard let stream = fdopendir(fd) else { close(fd); throw changed() }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else { if errno != 0 { throw changed() }; break }
                let leaf: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingCString: $0) }
                }
                guard let leaf else { throw changed() }
                if leaf != "." && leaf != ".." { try removeTree(leaf, in: child) }
            }
            guard name.withCString({ unlinkat(directory.descriptor, $0, AT_REMOVEDIR) }) == 0 else { throw changed() }
        } else {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) || info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                  name.withCString({ unlinkat(directory.descriptor, $0, 0) }) == 0 else { throw changed() }
        }
        guard fsync(directory.descriptor) == 0 else { throw SourceSyncError.stateInvalid("Recovery cleanup may have run but its durability is uncertain.") }
    }
}
