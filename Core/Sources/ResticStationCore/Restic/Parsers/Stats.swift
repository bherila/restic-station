import Foundation

/// `restic stats --json`, both `--mode raw-data` (fixture `stats-raw.json`)
/// and the default restore-size mode (fixture `stats-restore.json`). All
/// fields except `snapshotsCount` are optional since neither fixture alone
/// carries every field (raw-data adds compression fields; restore-size adds
/// `totalFileCount`).
public struct Stats: Decodable, Equatable, Sendable {
    public let totalSize: Int?
    public let totalUncompressedSize: Int?
    public let compressionRatio: Double?
    public let compressionProgress: Double?
    public let compressionSpaceSaving: Double?
    public let totalBlobCount: Int?
    public let totalFileCount: Int?
    public let snapshotsCount: Int

    private enum CodingKeys: String, CodingKey {
        case totalSize = "total_size"
        case totalUncompressedSize = "total_uncompressed_size"
        case compressionRatio = "compression_ratio"
        case compressionProgress = "compression_progress"
        case compressionSpaceSaving = "compression_space_saving"
        case totalBlobCount = "total_blob_count"
        case totalFileCount = "total_file_count"
        case snapshotsCount = "snapshots_count"
    }
}

/// Parses the single JSON object returned by `restic stats --json`
/// (fixtures `stats-raw.json`, `stats-restore.json`).
public func parseStats(_ data: Data) throws -> Stats {
    try makeResticJSONDecoder().decode(Stats.self, from: data)
}
