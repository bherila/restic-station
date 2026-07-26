import Foundation

/// A restic snapshot, matching elements of `restic snapshots --json`
/// (fixture `snapshots.json`) and the snapshot-header line of
/// `restic ls --json` (fixture `ls-src.ndjson`, which additionally carries
/// `message_type`/`struct_type` — ignored here since they're not declared
/// in `CodingKeys`).
public struct Snapshot: Decodable, Equatable, Sendable {
    public let id: String
    public let shortId: String
    public let time: Date
    public let parent: String?
    /// Present only on snapshots produced by `restic copy` — the snapshot
    /// id in the *source* repository.
    public let original: String?
    public let paths: [String]
    public let hostname: String
    public let username: String
    public let programVersion: String?
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case id
        case shortId = "short_id"
        case time
        case parent
        case original
        case paths
        case hostname
        case username
        case programVersion = "program_version"
        case summary
    }

    /// Nested `summary` object on a snapshot list/header entry. Distinct
    /// from ``BackupSummary`` (the streamed NDJSON summary line) even
    /// though the field sets overlap heavily.
    public struct Summary: Decodable, Equatable, Sendable {
        public let backupStart: Date?
        public let backupEnd: Date?
        public let filesNew: Int?
        public let filesChanged: Int?
        public let filesUnmodified: Int?
        public let dirsNew: Int?
        public let dirsChanged: Int?
        public let dirsUnmodified: Int?
        public let dataBlobs: Int?
        public let treeBlobs: Int?
        public let dataAdded: Int?
        public let dataAddedPacked: Int?
        public let totalFilesProcessed: Int?
        public let totalBytesProcessed: Int?

        private enum CodingKeys: String, CodingKey {
            case backupStart = "backup_start"
            case backupEnd = "backup_end"
            case filesNew = "files_new"
            case filesChanged = "files_changed"
            case filesUnmodified = "files_unmodified"
            case dirsNew = "dirs_new"
            case dirsChanged = "dirs_changed"
            case dirsUnmodified = "dirs_unmodified"
            case dataBlobs = "data_blobs"
            case treeBlobs = "tree_blobs"
            case dataAdded = "data_added"
            case dataAddedPacked = "data_added_packed"
            case totalFilesProcessed = "total_files_processed"
            case totalBytesProcessed = "total_bytes_processed"
        }
    }
}

/// Parses the full JSON array returned by `restic snapshots --json`
/// (fixture `snapshots.json`).
public func parseSnapshots(_ data: Data) throws -> [Snapshot] {
    try makeResticJSONDecoder().decode([Snapshot].self, from: data)
}
