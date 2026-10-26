import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct SourceSyncGroupRecord: Codable {
    enum Status: String, Codable { case ready, running, synchronized, needsRecovery, backupNeedsAttention }
    var version: Int = 1
    var setId: UUID
    var groupId: UUID
    var baseline: SyncBaseline?
    var activeOperation: UUID?
    var status: Status
    var lastSynchronizedAt: Date?
    var hasHistory: Bool = false
}

struct StoredSyncPreview: Codable {
    var id: UUID
    var setId: UUID
    var plan: SourceSyncPlan
    var binding: String
    var createdAt: Date
    var group: SourceSyncGroup
}

struct SourceSyncJournal: Codable {
    enum Phase: String, Codable { case reserved, protected, installing, installed, agreed, backedUp, complete, cancelling, cancelled }
    var version: Int = 1
    var preview: StoredSyncPreview
    var phase: Phase
    var localPrepared: SyncEndpointReply?
    var peerPrepared: SyncEndpointReply?
    var protectedSnapshot: String?
    var protectedRepository: String?
    var localFinished: SyncEndpointReply?
    var peerFinished: SyncEndpointReply?
}

/// All reads are strict and every authority-bearing write is durable.
/// An absent baseline is valid only in a newly enrolled group record;
/// losing the record never silently turns an existing group into first run.
struct SourceSyncStore {
    let paths: AppPaths
    let setId: UUID
    let groupId: UUID
    let directory: DirectoryHandle

    init(paths: AppPaths, setId: UUID, groupId: UUID) throws {
        self.paths = paths
        self.setId = setId
        self.groupId = groupId
        try paths.ensureDirectories()
        let application = try SourceSyncFilesystem.openRoot(SourceSyncFilesystem.physicalDirectory(paths.root.path))
        let root = try SyncEndpointService.child("source-sync", in: application)
        let name = groupId.uuidString
        #if canImport(Darwin)
        let created = name.withCString { Darwin.mkdirat(root.descriptor, $0, 0o700) } == 0
        #else
        let created = name.withCString { mkdirat(root.descriptor, $0, 0o700) } == 0
        #endif
        directory = try SourceSyncFilesystem.openDirectory(name, in: root)
        if created, fsync(root.descriptor) != 0 {
            throw SourceSyncError.stateInvalid("The synchronization group could not be created durably.")
        }
        let lock = FileLock(name: "group.lock", in: directory)
        switch lock.acquire() {
        case .acquired: break
        case .busy: throw SourceSyncError.busy
        case .failed: throw SourceSyncError.stateInvalid("The synchronization state lock is unusable.")
        }
        defer { lock.release() }
        if let record = try SyncDurability.read(SourceSyncGroupRecord.self, named: "group.json", in: directory) {
            guard record.version == 1, record.setId == setId, record.groupId == groupId else {
                throw SourceSyncError.stateInvalid("The synchronization group identity changed.")
            }
        } else {
            guard created else { throw SourceSyncError.stateInvalid("The synchronization group record is missing. Recovery is required.") }
            try SyncDurability.write(SourceSyncGroupRecord(setId: setId, groupId: groupId, status: .ready), named: "group.json", in: directory)
        }
    }

    func record() throws -> SourceSyncGroupRecord {
        guard let record = try SyncDurability.read(SourceSyncGroupRecord.self, named: "group.json", in: directory),
              record.version == 1, record.setId == setId, record.groupId == groupId,
              record.hasHistory == (record.baseline != nil) else {
            throw SourceSyncError.stateInvalid("The synchronization group record is missing or incompatible.")
        }
        return record
    }

    func save(_ record: SourceSyncGroupRecord) throws {
        guard record.version == 1, record.setId == setId, record.groupId == groupId,
              record.hasHistory == (record.baseline != nil) else { throw SourceSyncError.stalePlan }
        try SyncDurability.write(record, named: "group.json", in: directory)
    }

    func lock(leaseToChildren: Bool = false) throws -> FileLock {
        let lock = FileLock(name: "group.lock", in: directory, leaseToChildren: leaseToChildren)
        switch lock.acquire() {
        case .acquired: return lock
        case .busy: throw SourceSyncError.busy
        case .failed: throw SourceSyncError.stateInvalid("The synchronization state lock is unusable.")
        }
    }

    func savePreview(_ preview: StoredSyncPreview, token: String) throws {
        let index = try SyncEndpointService.child("previews", in: directory)
        try SyncDurability.write(preview, named: SHA256Digest.hex(Data(token.utf8)) + ".json", in: index)
    }

    /// Each saved preview holds both full inventories. Once consumed, the
    /// journal keeps its own copy; once its token expires (15 minutes), no
    /// apply can read it. Neither can authorize anything, so both go. Only
    /// token-hash names in this private directory are ever removed.
    func removePreview(token: String) {
        guard let index = try? SourceSyncFilesystem.openDirectory("previews", in: directory) else { return }
        _ = (SHA256Digest.hex(Data(token.utf8)) + ".json").withCString { unlinkat(index.descriptor, $0, 0) }
        _ = fsync(index.descriptor)
    }

    func removePreviews(savedBefore cutoff: Date) {
        guard let index = try? SourceSyncFilesystem.openDirectory("previews", in: directory),
              let names = try? SourceSyncFilesystem.entryNames(in: index).filter(Self.isPreviewName) else { return }
        for name in names {
            var info = stat()
            guard name.withCString({ fstatat(index.descriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { continue }
            #if canImport(Darwin)
            let saved = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            #else
            let saved = Date(timeIntervalSince1970: TimeInterval(info.st_mtim.tv_sec))
            #endif
            if saved < cutoff { _ = name.withCString { unlinkat(index.descriptor, $0, 0) } }
        }
        _ = fsync(index.descriptor)
    }

    func preview(token: String) throws -> StoredSyncPreview {
        let index = try SourceSyncFilesystem.openDirectory("previews", in: directory)
        guard let result = try SyncDurability.read(StoredSyncPreview.self, named: SHA256Digest.hex(Data(token.utf8)) + ".json", in: index) else {
            throw SourceSyncError.stalePlan
        }
        return result
    }

    static func isPreviewName(_ name: String) -> Bool {
        name.count == 69 && name.hasSuffix(".json") && name.dropLast(5).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    func operation(_ id: UUID) throws -> DirectoryHandle {
        let operations = try SyncEndpointService.child("operations", in: directory)
        return try SyncEndpointService.child(id.uuidString, in: operations)
    }
}
