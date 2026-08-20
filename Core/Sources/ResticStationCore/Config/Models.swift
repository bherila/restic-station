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
    ///
    /// - 1: the original single-machine schema.
    /// - 2: per-machine scoping — `machines` overrides on `BackupSet` and
    ///   `Destination`, and `resticPath` relocated to `machine.json`.
    /// - 3: `purgeExcludes` on `BackupSet` — patterns excluded from new
    ///   backups *and* rewritten out of existing snapshots.
    public static let currentVersion = 3

    public var version: Int
    /// **Deprecated** — superseded by `MachineConfig.resticPath`, because
    /// the path to a binary is host-local and `config.json` is shared across
    /// every machine. Still read (and still written by builds that predate
    /// schema v2) as the fallback when `machine.json` has no `resticPath`,
    /// so a v1 config keeps working untouched. `nil` = not yet discovered.
    public var resticPath: String?
    public var showMenuBarIcon: Bool
    /// `true` once the first-launch setup assistant has been completed or
    /// skipped (`docs/ui-spec.md` §Onboarding). `nil` — the value in every
    /// config written before this field existed — means "never ran", which
    /// is why it is an `Optional<Bool>` rather than a defaulted `Bool`: the
    /// three states (never ran / ran / explicitly reset) stay distinguishable
    /// and old configs keep decoding unchanged.
    public var onboardingCompleted: Bool?
    public var sets: [BackupSet]

    public init(
        version: Int = AppConfig.currentVersion,
        resticPath: String? = nil,
        showMenuBarIcon: Bool = true,
        onboardingCompleted: Bool? = nil,
        sets: [BackupSet] = []
    ) {
        self.version = version
        self.resticPath = resticPath
        self.showMenuBarIcon = showMenuBarIcon
        self.onboardingCompleted = onboardingCompleted
        self.sets = sets
    }

    private enum CodingKeys: String, CodingKey {
        case version, resticPath, showMenuBarIcon, onboardingCompleted, sets
    }

    // Custom encode so `resticPath == nil` encodes as JSON `null` rather
    // than omitting the key (the compiler-synthesized encoder would use
    // `encodeIfPresent`, which omits it). Decoding is left to the
    // synthesized `init(from:)`, which treats a missing key and an
    // explicit `null` identically.
    //
    // `onboardingCompleted` is the one deliberate exception: it uses
    // `encodeIfPresent`, so a config that has never seen the setup assistant
    // is byte-identical to one written by a build that predates the field.
    // Emitting `"onboardingCompleted": null` would instead rewrite every
    // existing config.json on the first save and change the documented
    // example in `docs/data-model.md` §config.json (which this file's
    // round-trip tests pin byte-for-byte modulo key order). Absent and
    // `null` decode identically either way, so nothing else has to care.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(resticPath, forKey: .resticPath)
        try container.encode(showMenuBarIcon, forKey: .showMenuBarIcon)
        try container.encodeIfPresent(onboardingCompleted, forKey: .onboardingCompleted)
        try container.encode(sets, forKey: .sets)
    }
}

// MARK: - BackupSet

public struct BackupSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute paths.
    public var sources: [String]
    /// restic `--exclude` patterns. Forward-only: they keep matching paths
    /// out of *new* snapshots and do nothing to snapshots already written.
    public var excludes: [String]
    /// restic `--exclude` patterns that are **also applied retroactively**
    /// (schema v3): matching paths are kept out of new snapshots exactly as
    /// ``excludes`` are, and are additionally rewritten out of the snapshots
    /// already in each destination.
    ///
    /// Deliberately a second list rather than a flag on ``excludes``. The
    /// retroactive half deletes backup data irreversibly, so it must be
    /// something a person opts a pattern into — not a behaviour that changes
    /// underneath every exclude anyone has ever configured.
    ///
    /// Note the asymmetry with removal: adding a pattern here destroys data,
    /// while removing one restores nothing. `restic rewrite --forget` has no
    /// inverse.
    public var purgeExcludes: [String]
    public var schedule: Schedule
    /// `nil` = never forget.
    public var retention: RetentionPolicy?
    /// `nil` = no scheduled checks.
    public var checkPolicy: CheckPolicy?
    /// Default 14.
    public var stalenessWarningDays: Int
    /// Invariant: exactly one `isPrimary`.
    public var destinations: [Destination]
    /// Per-machine overrides, keyed by `MachineConfig.machineId` (schema v2).
    ///
    /// `nil`, or a map with no entry for this machine, means **inherit the
    /// values above and run** — which is why an existing single-machine
    /// config behaves exactly as it did before v2, and why adding a second
    /// machine is purely additive.
    public var machines: [String: BackupSetMachineOverride]?

    public init(
        id: UUID,
        name: String,
        sources: [String],
        excludes: [String] = [],
        purgeExcludes: [String] = [],
        schedule: Schedule,
        retention: RetentionPolicy? = nil,
        checkPolicy: CheckPolicy? = nil,
        stalenessWarningDays: Int = 14,
        destinations: [Destination],
        machines: [String: BackupSetMachineOverride]? = nil
    ) {
        self.id = id
        self.name = name
        self.sources = sources
        self.excludes = excludes
        self.purgeExcludes = purgeExcludes
        self.schedule = schedule
        self.retention = retention
        self.checkPolicy = checkPolicy
        self.stalenessWarningDays = stalenessWarningDays
        self.destinations = destinations
        self.machines = machines
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sources, excludes, purgeExcludes, schedule, retention, checkPolicy
        case stalenessWarningDays, destinations
        case machines
    }

    // Hand-written decode, where every other type here relies on the
    // synthesized one, for a single reason: `purgeExcludes` is a v3 key that
    // must decode out of a v1 or v2 file, and decoding happens *before*
    // migration runs (`ConfigStore.load()` decodes, validates, then
    // migrates). The synthesized decoder would throw `keyNotFound` on every
    // pre-v3 config and no migration would ever get the chance to run.
    // Absent and explicit `null` both read as "no purge patterns".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sources = try container.decode([String].self, forKey: .sources)
        excludes = try container.decode([String].self, forKey: .excludes)
        purgeExcludes = try container.decodeIfPresent([String].self, forKey: .purgeExcludes) ?? []
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        retention = try container.decodeIfPresent(RetentionPolicy.self, forKey: .retention)
        checkPolicy = try container.decodeIfPresent(CheckPolicy.self, forKey: .checkPolicy)
        stalenessWarningDays = try container.decode(Int.self, forKey: .stalenessWarningDays)
        destinations = try container.decode([Destination].self, forKey: .destinations)
        machines = try container.decodeIfPresent([String: BackupSetMachineOverride].self, forKey: .machines)
    }

    // See AppConfig.encode(to:) — explicit null for `retention`/`checkPolicy`.
    //
    // `machines` is the second deliberate `encodeIfPresent` exception (after
    // `onboardingCompleted`): absence is the "runs everywhere" default, so a
    // config with no per-machine overrides — every config written before v2 —
    // stays byte-identical apart from its `version` number instead of gaining
    // a `"machines": null` on every set and destination.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sources, forKey: .sources)
        try container.encode(excludes, forKey: .excludes)
        try container.encode(purgeExcludes, forKey: .purgeExcludes)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(retention, forKey: .retention)
        try container.encode(checkPolicy, forKey: .checkPolicy)
        try container.encode(stalenessWarningDays, forKey: .stalenessWarningDays)
        try container.encode(destinations, forKey: .destinations)
        try container.encodeIfPresent(machines, forKey: .machines)
    }

    /// Every pattern that must reach `restic backup` as `--exclude`: the
    /// forward-only ``excludes`` followed by ``purgeExcludes``, deduped with
    /// first-occurrence order preserved.
    ///
    /// The forward half of purging is exactly "these patterns are also
    /// ordinary excludes", so it costs nothing — which is why this is the
    /// single place the two lists are ever concatenated. Nothing else should
    /// do it by hand: a caller that forgets leaves a purge pattern being
    /// rewritten out of history on every run and immediately backed up again
    /// by the next one.
    public var effectiveBackupExcludes: [String] {
        var seen = Set<String>()
        return (excludes + purgeExcludes).filter { seen.insert($0).inserted }
    }
}

// MARK: - BackupSetMachineOverride

/// What one machine changes about a `BackupSet` (schema v2).
///
/// **Overrides replace, they never merge**: an override `sources` array
/// replaces the top-level array wholesale. Merging arrays produces
/// surprising unions and offers no way to express a removal.
///
/// Every field is optional and `nil` means "inherit". Unlike the rest of
/// `config.json`, absent fields are encoded as *absent* rather than as
/// explicit `null` — an override is a sparse patch, and `"sources": null`
/// inside one reads like "override to no sources" when it means the opposite.
public struct BackupSetMachineOverride: Codable, Equatable, Sendable {
    /// `false` skips this set entirely on this machine — scheduling, backup,
    /// check and prune alike. `nil`/`true` = run it.
    public var enabled: Bool?
    /// Replaces `BackupSet.sources` wholesale. An empty array is legal and
    /// means "nothing to back up here"; resolution drops the set with a
    /// recorded reason rather than running a sourceless backup.
    public var sources: [String]?
    /// Replaces `BackupSet.schedule`.
    public var schedule: Schedule?

    public init(enabled: Bool? = nil, sources: [String]? = nil, schedule: Schedule? = nil) {
        self.enabled = enabled
        self.sources = sources
        self.schedule = schedule
    }
}

// MARK: - DestinationMachineOverride

/// What one machine changes about a `Destination` (schema v2). Same
/// replace-not-merge and sparse-encoding rules as
/// ``BackupSetMachineOverride``.
public struct DestinationMachineOverride: Codable, Equatable, Sendable {
    /// `false` excludes this destination from this machine's runs — the way
    /// a Mac-local external drive stops being probed by the Linux host.
    /// `nil`/`true` = use it.
    public var enabled: Bool?
    /// Replaces `Destination.repoURL`.
    public var repoURL: String?
    /// Replaces `Destination.nonSecretEnv` wholesale.
    public var nonSecretEnv: [String: String]?

    public init(enabled: Bool? = nil, repoURL: String? = nil, nonSecretEnv: [String: String]? = nil) {
        self.enabled = enabled
        self.repoURL = repoURL
        self.nonSecretEnv = nonSecretEnv
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
    /// Per-machine overrides, keyed by `MachineConfig.machineId` (schema v2).
    /// `nil`, or no entry for this machine, means inherit and use.
    public var machines: [String: DestinationMachineOverride]?

    public init(
        id: UUID,
        label: String,
        repoURL: String,
        isPrimary: Bool,
        nonSecretEnv: [String: String] = [:],
        machines: [String: DestinationMachineOverride]? = nil
    ) {
        self.id = id
        self.label = label
        self.repoURL = repoURL
        self.isPrimary = isPrimary
        self.nonSecretEnv = nonSecretEnv
        self.machines = machines
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, repoURL, isPrimary, nonSecretEnv, machines
    }

    // `machines` uses `encodeIfPresent` for the same reason as
    // `BackupSet.encode(to:)`; the remaining fields are non-optional, so the
    // synthesized behaviour is already what the house convention asks for.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(repoURL, forKey: .repoURL)
        try container.encode(isPrimary, forKey: .isPrimary)
        try container.encode(nonSecretEnv, forKey: .nonSecretEnv)
        try container.encodeIfPresent(machines, forKey: .machines)
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

public extension Destination {
    /// The repository identity a maintenance preview authorizes. Local paths
    /// are resolved before binding so a symlink retarget between preview and
    /// confirmation invalidates the capability instead of redirecting prune
    /// to an unpreviewed repository. Remote URLs are opaque to Foundation
    /// and must remain verbatim.
    func pruneRepositoryURL() -> String {
        guard kind == .localPath else { return repoURL }
        return URL(fileURLWithPath: repoURL)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// The exact destination passed to the preview and destructive prune.
    /// Keeping the resolved local URL in the invocation closes the remaining
    /// time-of-check/time-of-use gap after its fingerprint was validated.
    func pruneInvocationDestination() -> Destination {
        guard kind == .localPath else { return self }
        var resolved = self
        resolved.repoURL = pruneRepositoryURL()
        return resolved
    }

    /// Stable binding for a destructive maintenance confirmation. The helper
    /// supplies the stored secret environment, so the binding covers every
    /// destination value that affects a restic invocation without ever
    /// exposing a secret on argv or in app memory.
    func pruneConfirmationFingerprint(
        secretEnv: [String: String],
        executableIdentity: String? = nil
    ) -> String {
        struct EffectiveDestination: Codable {
            let repoURL: String
            let nonSecretEnv: [String: String]
            let secretEnv: [String: String]
            let executableIdentity: String?
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let effective = EffectiveDestination(
            repoURL: pruneRepositoryURL(),
            nonSecretEnv: nonSecretEnv,
            secretEnv: secretEnv,
            executableIdentity: executableIdentity
        )
        // Encoding an in-memory String dictionary cannot fail in practice;
        // fail closed with an impossible-to-match fingerprint if it ever did.
        guard let data = try? encoder.encode(effective) else { return "" }
        return SHA256Digest.hex(data)
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
    /// Invariant 3: a set has an empty `purgeExcludes` pattern.
    case emptyPurgeExcludePattern(setId: UUID, index: Int)
    /// Invariant 4: a `Schedule` field is out of range.
    case invalidSchedule(setId: UUID, reason: String)
    /// Invariant 5: `stalenessWarningDays < 1`.
    case invalidStalenessWarningDays(setId: UUID, value: Int)
    /// Invariant 5: `checkPolicy.readDataSubsetSlices` not in `2...100`.
    case invalidReadDataSubsetSlices(setId: UUID, value: Int)
    /// Invariant 6: a `machines` key is not a valid `machineId` slug.
    case invalidMachineIdKey(setId: UUID, machineId: String)
    /// Invariant 6: an override `sources` entry is not an absolute path.
    case relativeOverrideSourcePath(setId: UUID, machineId: String, path: String)
    /// Invariant 7: after resolving for `machineId`, a set that still runs
    /// there does not have exactly one primary destination — e.g. a config
    /// that disables the primary on some machine without disabling the set.
    case notExactlyOnePrimaryDestinationForMachine(setId: UUID, machineId: String, count: Int)

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
        case .emptyPurgeExcludePattern(let setId, let index):
            return "backup set \(setId) has an empty purgeExcludes pattern at position \(index) — "
                + "remove the blank row; an empty pattern would be passed to restic as --exclude \"\""
        case .invalidSchedule(let setId, let reason):
            return "backup set \(setId) has an invalid schedule: \(reason)"
        case .invalidStalenessWarningDays(let setId, let value):
            return "backup set \(setId) has invalid stalenessWarningDays \(value) (must be >= 1)"
        case .invalidReadDataSubsetSlices(let setId, let value):
            return "backup set \(setId) has invalid checkPolicy.readDataSubsetSlices \(value) (must be in 2...100)"
        case .invalidMachineIdKey(let setId, let machineId):
            return "backup set \(setId) has an invalid machines key \"\(machineId)\" — a machineId must be "
                + "non-empty and use only lowercase letters, digits and '-'"
        case .relativeOverrideSourcePath(let setId, let machineId, let path):
            return "backup set \(setId) has a non-absolute source path for machine \"\(machineId)\": \(path)"
        case .notExactlyOnePrimaryDestinationForMachine(let setId, let machineId, let count):
            return "backup set \(setId) must have exactly one primary destination on machine \"\(machineId)\", "
                + "found \(count) — disable the whole set for that machine instead of its primary destination"
        }
    }
}

extension ConfigError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - AppConfig.validate()

extension AppConfig {
    /// Enforces the seven invariants documented in `docs/data-model.md`
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

            // Invariant 3: no blank purge pattern. `excludes` is deliberately
            // left unvalidated — a stray blank row there is harmless noise —
            // but `--exclude ""` in a list that also drives `rewrite --forget`
            // is not something to find out about from a repository.
            for (index, pattern) in set.purgeExcludes.enumerated() where pattern.isEmpty {
                throw ConfigError.emptyPurgeExcludePattern(setId: set.id, index: index)
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

            // Invariant 6: per-machine override keys and values.
            try Self.validateOverrides(in: set)
        }

        // Invariant 7: the per-set invariants that only mean something once
        // the overrides are applied.
        try validateResolutions()
    }

    // MARK: Invariant 6 — override shape

    /// Every `machines` key on a set or on one of its destinations must be a
    /// valid `machineId` slug, and the values an override supplies get the
    /// *same* checks the fields they replace already get.
    private static func validateOverrides(in set: BackupSet) throws {
        for (machineId, override) in set.machines ?? [:] {
            guard MachineIdentity.isValid(machineId) else {
                throw ConfigError.invalidMachineIdKey(setId: set.id, machineId: machineId)
            }
            // Same rule as invariant 3 for the array it replaces. An *empty*
            // override array is deliberately allowed where an empty
            // top-level array is not: it is how a machine says "nothing to
            // back up here", and resolution drops the set with a recorded
            // reason rather than running a sourceless backup.
            for source in override.sources ?? [] where !source.hasPrefix("/") {
                throw ConfigError.relativeOverrideSourcePath(setId: set.id, machineId: machineId, path: source)
            }
            // Same rule as invariant 4 for the schedule it replaces.
            if let schedule = override.schedule {
                try validateSchedule(schedule, setId: set.id)
            }
        }

        for destination in set.destinations {
            for machineId in (destination.machines ?? [:]).keys {
                guard MachineIdentity.isValid(machineId) else {
                    throw ConfigError.invalidMachineIdKey(setId: set.id, machineId: machineId)
                }
            }
        }
    }

    // MARK: Invariant 7 — post-resolution

    /// "Exactly one primary destination" has to hold **per machine**, not
    /// just on the shared values: a config where a machine disables the
    /// primary but leaves the set running resolves to a set with nowhere to
    /// back up to, which the engine can only report as misconfigured at run
    /// time — on a headless host, with no one watching.
    ///
    /// The rule is deliberately stated on the set *before* resolution drops
    /// anything: **if a set runs on a machine, its primary must be enabled
    /// there.** Disabling the primary is never a legitimate way to say "do
    /// not run this here" — `"machines": {"<id>": {"enabled": false}}` on the
    /// set is, and it says so unambiguously. Checking after the drop would
    /// let "every destination disabled" quietly become "set skipped", which
    /// is the same silence this invariant exists to prevent.
    ///
    /// Checked for every `machineId` the config mentions. Machines with no
    /// overrides at all need no check: they see the shared values, which
    /// invariant 1 has already validated.
    private func validateResolutions() throws {
        for machineId in referencedMachineIds {
            for set in sets {
                // A set this machine does not run has no destinations to
                // require.
                if set.machines?[machineId]?.enabled == false {
                    continue
                }
                let primaryCount = set.destinations.filter { destination in
                    destination.isPrimary && destination.machines?[machineId]?.enabled != false
                }.count
                if primaryCount != 1 {
                    throw ConfigError.notExactlyOnePrimaryDestinationForMachine(
                        setId: set.id, machineId: machineId, count: primaryCount
                    )
                }
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
