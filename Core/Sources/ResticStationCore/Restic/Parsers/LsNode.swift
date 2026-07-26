import Foundation

/// The `type` of a node as reported by `restic ls`/`find` (`"file"`,
/// `"dir"`, `"symlink"`), tolerant of any future value via `.other`.
public enum LsNodeType: Equatable, Sendable {
    case file
    case dir
    case symlink
    case other(String)
}

extension LsNodeType: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "file": self = .file
        case "dir": self = .dir
        case "symlink": self = .symlink
        default: self = .other(raw)
        }
    }
}

/// A `{"message_type":"node", ...}` line from `restic ls --json`
/// (fixture `ls-src.ndjson`).
public struct LsNode: Decodable, Equatable, Sendable {
    public let name: String
    public let type: LsNodeType
    public let path: String
    /// Absent for directories.
    public let size: Int?
    public let mtime: Date
    public let permissions: String?

    private enum CodingKeys: String, CodingKey {
        case name, type, path, size, mtime, permissions
    }
}
