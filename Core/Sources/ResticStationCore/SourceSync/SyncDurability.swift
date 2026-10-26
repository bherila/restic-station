import Foundation
import ResticStationPOSIX

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum SyncDurability {
    @TaskLocal static var synchronize: @Sendable (Int32) -> Int32 = { fsync($0) }
    /// Authoritative journal writes retain a directory generation and check
    /// both barriers. A failure after installation is indeterminate; callers
    /// inspect the journal on recovery instead of assuming no write occurred.
    static func write<T: Encodable>(_ value: T, named name: String, in directory: DirectoryHandle) throws {
        let bytes = try ConfigStore.makeEncoder().encode(value)
        let temporary = ".sync-write-\(UUID().uuidString)"
        let fd = temporary.withCString { openat(directory.descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw SourceSyncError.stateInvalid("The synchronization journal cannot be created.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: bytes)
            guard synchronize(fd) == 0 else { throw SourceSyncError.stateInvalid("The synchronization journal could not be made durable.") }
            try file.close()
            let result = temporary.withCString { source in
                name.withCString { target in renameat(directory.descriptor, source, directory.descriptor, target) }
            }
            guard result == 0, synchronize(directory.descriptor) == 0 else {
                throw SourceSyncError.stateInvalid("The journal may have changed, but its durability could not be confirmed. Inspect recovery state.")
            }
        } catch {
            _ = temporary.withCString { unlinkat(directory.descriptor, $0, 0) }
            throw error
        }
    }

    static func read<T: Decodable>(_ type: T.Type, named name: String, in directory: DirectoryHandle) throws -> T? {
        let fd = name.withCString { openat(directory.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SourceSyncError.stateInvalid("Synchronization state cannot be read safely.")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o077 == 0 else {
            throw SourceSyncError.stateInvalid("Synchronization state is not a private regular file.")
        }
        guard let data = try file.readToEnd() else { throw SourceSyncError.stateInvalid("Synchronization state is empty.") }
        do { return try ConfigStore.makeDecoder().decode(type, from: data) }
        catch { throw SourceSyncError.stateInvalid("Synchronization state is unreadable or corrupt. Reconciliation is required.") }
    }

    static func moveExclusive(
        _ name: String, from source: DirectoryHandle,
        to target: DirectoryHandle, as targetName: String
    ) throws {
        let result = name.withCString { a in targetName.withCString { b in
            rs_sync_rename_exclusive(source.descriptor, a, target.descriptor, b)
        } }
        guard result == 0 else {
            if errno == EEXIST || errno == ENOENT { throw SourceSyncError.stalePlan }
            throw SourceSyncError.stateInvalid("The filesystem could not perform an exclusive atomic move. Inspect recovery state and filesystem support before retrying.")
        }
        guard synchronize(source.descriptor) == 0, synchronize(target.descriptor) == 0 else {
            throw SourceSyncError.stateInvalid("An entry may have moved, but durability is uncertain. Inspect recovery state.")
        }
    }
}
