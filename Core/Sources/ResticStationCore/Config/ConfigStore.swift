import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Loads and atomically persists `config.json` at the location described by
/// an `AppPaths`. No caching — callers hold the decoded `AppConfig` value
/// and pass it back in to `save(_:)`.
public struct ConfigStore: Sendable {
    public let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    /// The temp file `save(_:)` writes before `rename(2)`-ing it over
    /// `configFile`. Fixed (not randomized) so a crash between the write
    /// and the rename leaves a deterministic, recognizable leftover that
    /// the next `save(_:)` simply overwrites.
    var tempConfigFile: URL {
        paths.configFile.deletingLastPathComponent()
            .appendingPathComponent(paths.configFile.lastPathComponent + ".tmp", isDirectory: false)
    }

    /// Missing file → default empty config. Version newer than this build
    /// supports → `ConfigError.newerVersion`. Otherwise decodes and
    /// validates (`AppConfig.validate()` is called on every load).
    public func load() throws -> AppConfig {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.configFile.path) else {
            return AppConfig()
        }

        let data = try Data(contentsOf: paths.configFile)
        let config = try Self.makeDecoder().decode(AppConfig.self, from: data)

        if config.version > AppConfig.currentVersion {
            throw ConfigError.newerVersion(found: config.version, supported: AppConfig.currentVersion)
        }

        try config.validate()
        return config
    }

    /// Validates, encodes (`.sortedKeys` + `.prettyPrinted` + ISO 8601 with
    /// fractional seconds), writes to a temp file in the same directory,
    /// then `rename(2)`s it over `configFile` — atomic even if a previous
    /// write crashed and left a stale temp file behind.
    public func save(_ config: AppConfig) throws {
        try config.validate()
        try paths.ensureDirectories()

        let data = try Self.makeEncoder().encode(config)
        try data.write(to: tempConfigFile)

        let fromPath = tempConfigFile.path
        let toPath = paths.configFile.path
        let renameResult = fromPath.withCString { fromC in
            toPath.withCString { toC in
                rename(fromC, toC)
            }
        }
        if renameResult != 0 {
            let renameErrno = errno
            try? FileManager.default.removeItem(at: tempConfigFile)
            throw ConfigStoreError.renameFailed(errno: renameErrno, from: fromPath, to: toPath)
        }
    }

    // MARK: - Encoding

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeISO8601Formatter().string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = makeISO8601Formatter().date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(string)"
                )
            }
            return date
        }
        return decoder
    }

    /// ISO 8601 with fractional seconds, per `docs/data-model.md`. `config.json`
    /// itself has no `Date` fields today, but this keeps the store consistent
    /// with the rest of the persisted-JSON policy for when it does. A fresh
    /// formatter is created per call — `ISO8601DateFormatter` is a mutable,
    /// non-`Sendable` class, and encode/decode can run concurrently.
    static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

/// Low-level failures from `ConfigStore.save(_:)`'s atomic rename step.
public enum ConfigStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case renameFailed(errno: Int32, from: String, to: String)

    public var description: String {
        switch self {
        case .renameFailed(let errno, let from, let to):
            return "rename(\(from), \(to)) failed: errno \(errno)"
        }
    }
}
