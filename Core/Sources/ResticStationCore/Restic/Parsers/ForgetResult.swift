import Foundation

/// Explains why a kept snapshot survived a `forget` policy evaluation.
public struct ForgetReason: Decodable, Equatable, Sendable {
    public let snapshot: Snapshot
    public let matches: [String]?
}

/// One retention-policy group from `restic forget --json`
/// (fixture `forget.json`, captured with `--dry-run`). `remove` is `null`
/// when nothing in the group is due for deletion — always optional.
public struct ForgetResult: Decodable, Equatable, Sendable {
    public let tags: [String]?
    public let host: String?
    public let paths: [String]?
    public let keep: [Snapshot]?
    public let remove: [Snapshot]?
    public let reasons: [ForgetReason]?
}

/// Parses the full JSON array returned by `restic forget --json`
/// (fixture `forget.json`). Note: with `--prune`, prune progress follows
/// the JSON as plain text on later lines — callers must only feed the
/// first line/object to this function.
public func parseForget(_ data: Data) throws -> [ForgetResult] {
    try makeResticJSONDecoder().decode([ForgetResult].self, from: data)
}
