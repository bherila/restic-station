import Foundation

// MARK: - AppConfig

/// The persisted, top-level application configuration (`config.json`).
///
/// See `docs/data-model.md` §config.json for the JSON shape. All persisted
/// JSON uses `JSONEncoder` with `.sortedKeys` + `.prettyPrinted`; `Optional`
/// fields are encoded as explicit JSON `null` (never omitted) so the file
/// stays diffable and matches the documented example byte-for-byte modulo
/// key order.
public struct AppConfig: Codable, Equatable, Sendable {
    /// Current config schema version. Bump on breaking schema change.
    public static let currentVersion = 1

    public var version: Int
    /// `nil` = not yet discovered.
    public var resticPath: String?
    public var showMenuBarIcon: Bool
    public var sets: [BackupSet]

    public init(
        version: Int = AppConfig.currentVersion,
        resticPath: String? = nil,
        showMenuBarIcon: Bool = true,
        sets: [BackupSet] = []
    ) {
        self.version = version
        self.resticPath = resticPath
        self.showMenuBarIcon = showMenuBarIcon
        self.sets = sets
    }

    private enum CodingKeys: String, CodingKey {
        case version, resticPath, showMenuBarIcon, sets
    }

    // Custom encode so `resticPath == nil` encodes as JSON `null` rather
    // than omitting the key (the compiler-synthesized encoder would use
    // `encodeIfPresent`, which omits it). Decoding is left to the
    // synthesized `init(from:)`, which treats a missing key and an
    // explicit `null` identically.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(resticPath, forKey: .resticPath)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encode(sets, forKey: .sets)
    }
}

// MARK: - BackupSet

public struct BackupSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute paths.
    public var sources: [String]
    /// restic `--exclude` patterns.
    public var excludes: [String]
    public var schedule: Schedule
    /// `nil` = never forget.
    public var retention: RetentionPolicy?
    /// `nil` = no scheduled checks.
    public var checkPolicy: CheckPolicy?
    /// Default 14.
    public var stalenessWarningDays: Int
    /// Invariant: exactly one `isPrimary`.
    public var destinations: [Destination]

    public init(
        id: UUID,
        name: String,
        sources: [String],
        excludes: [String] = [],
        schedule: Schedule,
        retention: RetentionPolicy? = nil,
        checkPolicy: CheckPolicy? = nil,
        stalenessWarningDays: Int = 14,
        destinations: [Destination]
    ) {
        self.id = id
        self.name = name
        self.sources = sources
        self.excludes = excludes
        self.schedule = schedule
        self.retention = retention
        self.checkPolicy = checkPolicy
        self.stalenessWarningDays = stalenessWarningDays
        self.destinations = destinations
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sources, excludes, schedule, retention, checkPolicy, stalenessWarningDays, destinations
    }

    // See AppConfig.encode(to:) — explicit null for `retention`/`checkPolicy`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sources, forKey: .sources)
        try container.encode(excludes, forKey: .excludes)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(retention, forKey: .retention)
        try container.encode(checkPolicy, forKey: .checkPolicy)
        try container.encode(stalenessWarningDays, forKey: .stalenessWarningDays)
        try container.encode(destinations, forKey: .destinations)
    }
}

// MARK: - Destination

public struct Destination: Codable, Equatable, Identifiable, Sendable {
    /// Keychain key — never regenerate.
    public var id: UUID
    public var label: String
    /// restic `-r` value, verbatim.
    public var repoURL: String
    public var isPrimary: Bool
    /// Extra env, non-secret only.
    public var nonSecretEnv: [String: String]

    public init(
        id: UUID,
        label: String,
        repoURL: String,
        isPrimary: Bool,
        nonSecretEnv: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.repoURL = repoURL
        self.isPrimary = isPrimary
        self.nonSecretEnv = nonSecretEnv
    }

    /// Derived from `repoURL`'s scheme prefix. Not encoded.
    public var kind: DestinationKind {
        if repoURL.hasPrefix("sftp:") {
            return .sftp
        } else if repoURL.hasPrefix("rest:") {
            return .rest
        } else if repoURL.hasPrefix("s3:") {
            return .s3
        } else if repoURL.hasPrefix("b2:")
            || repoURL.hasPrefix("azure:")
            || repoURL.hasPrefix("gs:")
            || repoURL.hasPrefix("swift:")
            || repoURL.hasPrefix("rclone:") {
            return .otherCloud
        } else {
            return .localPath
        }
    }
}

public enum DestinationKind: Equatable, Sendable {
    /// No scheme prefix; includes `/Volumes/...` and iCloud paths.
    case localPath
    /// `sftp:` prefix.
    case sftp
    /// `rest:` prefix.
    case rest
    /// `s3:` prefix (AWS or any S3-compatible endpoint, e.g. R2).
    case s3
    /// `b2:`, `azure:`, `gs:`, `swift:`, `rclone:`.
    case otherCloud
}

// MARK: - Schedule

public enum Schedule: Codable, Equatable, Sendable {
    /// `{"kind":"everyMinutes","minutes":30}`
    case everyMinutes(Int)
    /// `{"kind":"hourly","minute":15}`
    case hourly(minute: Int)
    /// `{"kind":"daily","hour":2,"minute":30}`
    case daily(hour: Int, minute: Int)
    /// weekday 1=Sunday…7=Saturday (Calendar convention).
    case weekly(weekday: Int, hour: Int, minute: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, minutes, minute, hour, weekday
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "everyMinutes":
            let minutes = try container.decode(Int.self, forKey: .minutes)
            self = .everyMinutes(minutes)
        case "hourly":
            let minute = try container.decode(Int.self, forKey: .minute)
            self = .hourly(minute: minute)
        case "daily":
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            self = .daily(hour: hour, minute: minute)
        case "weekly":
            let weekday = try container.decode(Int.self, forKey: .weekday)
            let hour = try container.decode(Int.self, forKey: .hour)
            let minute = try container.decode(Int.self, forKey: .minute)
            self = .weekly(weekday: weekday, hour: hour, minute: minute)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown Schedule kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everyMinutes(let minutes):
            try container.encode("everyMinutes", forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case .hourly(let minute):
            try container.encode("hourly", forKey: .kind)
            try container.encode(minute, forKey: .minute)
        case .daily(let hour, let minute):
            try container.encode("daily", forKey: .kind)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        case .weekly(let weekday, let hour, let minute):
            try container.encode("weekly", forKey: .kind)
            try container.encode(weekday, forKey: .weekday)
            try container.encode(hour, forKey: .hour)
            try container.encode(minute, forKey: .minute)
        }
    }
}

// MARK: - RetentionPolicy

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var keepLast: Int?
    public var keepHourly: Int?
    public var keepDaily: Int?
    public var keepWeekly: Int?
    public var keepMonthly: Int?
    public var keepYearly: Int?

    public init(
        keepLast: Int? = nil,
        keepHourly: Int? = nil,
        keepDaily: Int? = nil,
        keepWeekly: Int? = nil,
        keepMonthly: Int? = nil,
        keepYearly: Int? = nil
    ) {
        self.keepLast = keepLast
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
    }

    /// Engine refuses to forget with an empty policy.
    public var isEmpty: Bool {
        keepLast == nil
            && keepHourly == nil
            && keepDaily == nil
            && keepWeekly == nil
            && keepMonthly == nil
            && keepYearly == nil
    }

    private enum CodingKeys: String, CodingKey {
        case keepLast, keepHourly, keepDaily, keepWeekly, keepMonthly, keepYearly
    }

    // See AppConfig.encode(to:) — every field is explicit null when nil,
    // matching the documented example (which always shows all six keys).
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keepLast, forKey: .keepLast)
        try container.encode(keepHourly, forKey: .keepHourly)
        try container.encode(keepDaily, forKey: .keepDaily)
        try container.encode(keepWeekly, forKey: .keepWeekly)
        try container.encode(keepMonthly, forKey: .keepMonthly)
        try container.encode(keepYearly, forKey: .keepYearly)
    }
}

// MARK: - CheckPolicy

public struct CheckPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// `t` in `--read-data-subset=n/t`; default 20.
    public var readDataSubsetSlices: Int

    public init(enabled: Bool, readDataSubsetSlices: Int = 20) {
        self.enabled = enabled
        self.readDataSubsetSlices = readDataSubsetSlices
    }
}

// MARK: - ConfigError

/// Errors thrown by `AppConfig.validate()` and `ConfigStore`.
public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `config.version` is greater than `AppConfig.currentVersion` — refuse
    /// to load a config written by a newer build.
    case newerVersion(found: Int, supported: Int)
    /// Invariant 1: a set does not have exactly one primary destination.
    case notExactlyOnePrimaryDestination(setId: UUID, count: Int)
    /// Invariant 2: a set or destination UUID is duplicated in the config.
    case duplicateIdentifier(UUID)
    /// Invariant 3: a set has no sources.
    case emptySources(setId: UUID)
    /// Invariant 3: a set has a non-absolute source path.
    case relativeSourcePath(setId: UUID, path: String)
    /// Invariant 4: a `Schedule` field is out of range.
    case invalidSchedule(setId: UUID, reason: String)
    /// Invariant 5: `stalenessWarningDays < 1`.
    case invalidStalenessWarningDays(setId: UUID, value: Int)
    /// Invariant 5: `checkPolicy.readDataSubsetSlices` not in `2...100`.
    case invalidReadDataSubsetSlices(setId: UUID, value: Int)

    public var description: String {
        switch self {
        case .newerVersion(let found, let supported):
            return "config written by a newer Restic Station (version \(found), this build supports up to \(supported))"
        case .notExactlyOnePrimaryDestination(let setId, let count):
            return "backup set \(setId) must have exactly one primary destination, found \(count)"
        case .duplicateIdentifier(let id):
            return "duplicate identifier \(id) — set and destination UUIDs must be unique across the config"
        case .emptySources(let setId):
            return "backup set \(setId) has no sources"
        case .relativeSourcePath(let setId, let path):
            return "backup set \(setId) has a non-absolute source path: \(path)"
        case .invalidSchedule(let setId, let reason):
            return "backup set \(setId) has an invalid schedule: \(reason)"
        case .invalidStalenessWarningDays(let setId, let value):
            return "backup set \(setId) has invalid stalenessWarningDays \(value) (must be >= 1)"
        case .invalidReadDataSubsetSlices(let setId, let value):
            return "backup set \(setId) has invalid checkPolicy.readDataSubsetSlices \(value) (must be in 2...100)"
        }
    }
}

extension ConfigError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - AppConfig.validate()

extension AppConfig {
    /// Enforces the five invariants documented in `docs/data-model.md`
    /// §Invariants. Called on every save and after every load.
    public func validate() throws {
        var seenIDs = Set<UUID>()

        for set in sets {
            if seenIDs.contains(set.id) {
                throw ConfigError.duplicateIdentifier(set.id)
            }
            seenIDs.insert(set.id)

            // Invariant 1: exactly one primary destination.
            let primaryCount = set.destinations.filter(\.isPrimary).count
            if primaryCount != 1 {
                throw ConfigError.notExactlyOnePrimaryDestination(setId: set.id, count: primaryCount)
            }

            // Invariant 2: destination UUIDs unique across the whole config.
            for destination in set.destinations {
                if seenIDs.contains(destination.id) {
                    throw ConfigError.duplicateIdentifier(destination.id)
                }
                seenIDs.insert(destination.id)
            }

            // Invariant 3: sources non-empty; every source absolute.
            if set.sources.isEmpty {
                throw ConfigError.emptySources(setId: set.id)
            }
            for source in set.sources where !source.hasPrefix("/") {
                throw ConfigError.relativeSourcePath(setId: set.id, path: source)
            }

            // Invariant 4: Schedule fields in range.
            try Self.validateSchedule(set.schedule, setId: set.id)

            // Invariant 5: stalenessWarningDays >= 1; readDataSubsetSlices in 2...100.
            if set.stalenessWarningDays < 1 {
                throw ConfigError.invalidStalenessWarningDays(setId: set.id, value: set.stalenessWarningDays)
            }
            if let checkPolicy = set.checkPolicy, !(2...100).contains(checkPolicy.readDataSubsetSlices) {
                throw ConfigError.invalidReadDataSubsetSlices(setId: set.id, value: checkPolicy.readDataSubsetSlices)
            }
        }
    }

    private static func validateSchedule(_ schedule: Schedule, setId: UUID) throws {
        switch schedule {
        case .everyMinutes(let minutes):
            if minutes < 5 {
                throw ConfigError.invalidSchedule(setId: setId, reason: "everyMinutes must be >= 5, got \(minutes)")
            }
        case .hourly(let minute):
            try validateMinute(minute, setId: setId)
        case .daily(let hour, let minute):
            try validateHour(hour, setId: setId)
            try validateMinute(minute, setId: setId)
        case .weekly(let weekday, let hour, let minute):
            if !(1...7).contains(weekday) {
                throw ConfigError.invalidSchedule(setId: setId, reason: "weekday must be 1...7, got \(weekday)")
            }
            try validateHour(hour, setId: setId)
            try validateMinute(minute, setId: setId)
        }
    }

    private static func validateMinute(_ minute: Int, setId: UUID) throws {
        if !(0...59).contains(minute) {
            throw ConfigError.invalidSchedule(setId: setId, reason: "minute must be 0...59, got \(minute)")
        }
    }

    private static func validateHour(_ hour: Int, setId: UUID) throws {
        if !(0...23).contains(hour) {
            throw ConfigError.invalidSchedule(setId: setId, reason: "hour must be 0...23, got \(hour)")
        }
    }
}
