import Foundation

/// `restic cat config` (fixture `cat-config.json`) — the cheap
/// remote-reachability probe. Plain JSON object, no `message_type`
/// envelope (unlike the streamed NDJSON commands).
public struct RepositoryConfig: Decodable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let chunkerPolynomial: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case id
        case chunkerPolynomial = "chunker_polynomial"
    }
}

/// Parses the single JSON object returned by `restic cat config`
/// (fixture `cat-config.json`).
public func parseRepositoryConfig(_ data: Data) throws -> RepositoryConfig {
    try makeResticJSONDecoder().decode(RepositoryConfig.self, from: data)
}

/// `{"message_type":"initialized", ...}` from `restic init --json`
/// (fixtures `init.json`, `init-secondary.json`).
public struct InitializedMessage: Decodable, Equatable, Sendable {
    public let id: String
    public let repository: String
}

/// Parses the single JSON object returned by `restic init --json`
/// (fixtures `init.json`, `init-secondary.json`).
public func parseInitialized(_ data: Data) throws -> InitializedMessage {
    try makeResticJSONDecoder().decode(InitializedMessage.self, from: data)
}
