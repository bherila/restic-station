import Foundation

/// A single match entry inside a `restic find --json` result group.
public struct FindMatch: Decodable, Equatable, Sendable {
    public let path: String
    public let type: LsNodeType?
    public let permissions: String?
    public let mode: Int?
    public let mtime: Date?
    public let atime: Date?
    public let ctime: Date?
    public let uid: Int?
    public let gid: Int?
    public let user: String?
    public let group: String?
    public let inode: Int?
    public let deviceId: Int?
    public let size: Int?
    public let links: Int?

    private enum CodingKeys: String, CodingKey {
        case path, type, permissions, mode, mtime, atime, ctime, uid, gid, user, group, inode
        case deviceId = "device_id"
        case size, links
    }
}

/// One element of the JSON array returned by `restic find --json`
/// (fixture `find.json`) — the hits found within a single snapshot.
public struct FindResult: Decodable, Equatable, Sendable {
    public let matches: [FindMatch]
    public let hits: Int
    public let snapshot: String
}

/// Parses the full JSON array returned by `restic find --json`
/// (fixture `find.json`).
public func parseFind(_ data: Data) throws -> [FindResult] {
    try makeResticJSONDecoder().decode([FindResult].self, from: data)
}
