import Foundation

/// Streamed `{"message_type":"status", ...}` line from `restic backup --json`
/// (also emitted by `restore --json`). All fields except `percentDone` are
/// absent from the small captured fixtures, so they are optional.
public struct BackupStatus: Decodable, Equatable, Sendable {
    public let percentDone: Double
    public let totalFiles: Int?
    public let filesDone: Int?
    public let totalBytes: Int?
    public let bytesDone: Int?
    public let secondsRemaining: Int?
    public let currentFiles: [String]?
    public let errorCount: Int?

    private enum CodingKeys: String, CodingKey {
        case percentDone = "percent_done"
        case totalFiles = "total_files"
        case filesDone = "files_done"
        case totalBytes = "total_bytes"
        case bytesDone = "bytes_done"
        case secondsRemaining = "seconds_remaining"
        case currentFiles = "current_files"
        case errorCount = "error_count"
    }
}

/// Terminal `{"message_type":"summary", ...}` line from `restic backup --json`
/// (fixture `backup.ndjson` / `backup2.ndjson`). Distinct from
/// ``RestoreSummary``, which shares the same `message_type` but different
/// fields — ``ResticMessageDecoder`` disambiguates by field presence.
public struct BackupSummary: Decodable, Equatable, Sendable {
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
    public let totalDuration: Double?
    public let backupStart: Date?
    public let backupEnd: Date?
    public let snapshotId: String?

    private enum CodingKeys: String, CodingKey {
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
        case totalDuration = "total_duration"
        case backupStart = "backup_start"
        case backupEnd = "backup_end"
        case snapshotId = "snapshot_id"
    }
}

/// `{"message_type":"exit_error", ...}` — a fatal error delivered as an
/// NDJSON line on stdout instead of (only) a nonzero exit code (fixture
/// `locked-error.json`). Both fields are always present.
public struct ExitErrorMessage: Decodable, Equatable, Sendable {
    public let code: Int
    public let message: String
}

/// Terminal `{"message_type":"summary", ...}` line from `restic restore --json`
/// (fixture `restore.ndjson`).
public struct RestoreSummary: Decodable, Equatable, Sendable {
    public let totalFiles: Int?
    public let filesRestored: Int?
    public let totalBytes: Int?
    public let bytesRestored: Int?

    private enum CodingKeys: String, CodingKey {
        case totalFiles = "total_files"
        case filesRestored = "files_restored"
        case totalBytes = "total_bytes"
        case bytesRestored = "bytes_restored"
    }
}
