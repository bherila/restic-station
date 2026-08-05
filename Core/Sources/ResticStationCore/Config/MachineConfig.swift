import Foundation

// MARK: - MachineConfig

/// The host-local half of the configuration (`machine.json`).
///
/// **Never copy this file between machines.** `config.json` is shared — it
/// is the same file on every host, and it is what per-machine overrides are
/// written into. `machine.json` is what tells this host *which* of those
/// overrides are its own, plus the handful of values that are inherently
/// local to a box (the restic binary path). Copying it to a second machine
/// gives both machines the same `machineId`, which silently makes the second
/// machine back up the first machine's directories.
///
/// ```json
/// { "version": 1, "machineId": "studio-mac", "resticPath": "/usr/bin/restic" }
/// ```
///
/// See `docs/data-model.md` §machine.json.
public struct MachineConfig: Codable, Equatable, Sendable {
    /// Current `machine.json` schema version. Independent of
    /// `AppConfig.currentVersion` — the two files version separately.
    public static let currentVersion = 1

    public var version: Int
    /// The key `config.json`'s `machines` maps are keyed by. Must match
    /// ``MachineIdentity/isValid(_:)`` — the same slug charset the
    /// auto-generator produces.
    public var machineId: String
    /// Absolute path to the restic binary on *this* host. Takes precedence
    /// over the deprecated `AppConfig.resticPath`; `nil` = fall back to it.
    public var resticPath: String?

    public init(
        version: Int = MachineConfig.currentVersion,
        machineId: String,
        resticPath: String? = nil
    ) {
        self.version = version
        self.machineId = machineId
        self.resticPath = resticPath
    }

    private enum CodingKeys: String, CodingKey {
        case version, machineId, resticPath
    }

    // Explicit `null` for `resticPath` — same convention (and reasoning) as
    // `AppConfig.encode(to:)`: the file stays diffable and matches the
    // documented example modulo key order.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(resticPath, forKey: .resticPath)
    }
}

// MARK: - MachineIdentity

/// Generation and validation of `machineId` values.
///
/// Deliberately free of any I/O and of any platform branch except the one
/// call that asks the OS for its hostname, so the slug rules can be tested
/// identically on macOS and Linux.
public enum MachineIdentity {
    /// Environment variable that overrides the `machineId` read from
    /// `machine.json` — for tests, and for a user who wants two profiles on
    /// one host. Never written back to disk.
    public static let environmentOverrideKey = "RESTIC_STATION_MACHINE_ID"

    /// The charset a `machineId` may use: lowercase ASCII letters, digits
    /// and `-`. Exactly what ``slugify(_:)`` emits, which is what makes a
    /// hand-written `machines` key comparable with a generated one.
    public static func isValid(_ machineId: String) -> Bool {
        guard !machineId.isEmpty else { return false }
        return machineId.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        }
    }

    /// Lowercase, map every character outside `[a-z0-9-]` to `-`, collapse
    /// runs of `-`, trim leading/trailing `-`. Returns `nil` when nothing
    /// usable survives (empty input, or input made entirely of separators).
    ///
    /// Note the hostname's dots are *not* special-cased: `studio-mac.local`
    /// slugifies to `studio-mac-local`, not `studio-mac`. Stripping a
    /// trailing domain would be a guess, and `machineId` is a stable key —
    /// better a slightly long deterministic id the user can rename in
    /// `machine.json` than one that changes when the host joins a domain.
    public static func slugify(_ raw: String) -> String? {
        var slug = ""
        var lastWasSeparator = true // suppresses a leading `-`
        for character in raw.lowercased() {
            let isAllowed = character.isASCII && (character.isLowercase || character.isNumber)
            if isAllowed {
                slug.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? nil : slug
    }

    /// The `machineId` for a host that has no `machine.json` yet: the
    /// slugified hostname, or — when the hostname is empty or slugifies to
    /// nothing — a fresh lowercased UUID (which is itself a valid slug).
    public static func generate(hostName: String = ProcessInfo.processInfo.hostName) -> String {
        slugify(hostName) ?? UUID().uuidString.lowercased()
    }
}

// MARK: - MachineError

public enum MachineError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `machine.json` was written by a newer build.
    case newerVersion(found: Int, supported: Int)
    /// `machineId` is empty or uses characters outside `[a-z0-9-]`. Loud
    /// rather than lenient: a `machineId` that does not match what the
    /// `machines` keys use resolves to "no overrides", which silently backs
    /// up the wrong directories.
    case invalidMachineId(String)

    public var description: String {
        switch self {
        case .newerVersion(let found, let supported):
            return "machine.json was written by a newer Restic Station (version \(found), "
                + "this build supports up to \(supported))"
        case .invalidMachineId(let machineId):
            return "machine.json has an invalid machineId \"\(machineId)\" — it must be non-empty and use "
                + "only lowercase letters, digits and '-'"
        }
    }
}

extension MachineError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - MachineStore

/// Loads and atomically persists `machine.json`, the sibling of
/// `ConfigStore`. Same conventions: no caching, `.sortedKeys` +
/// `.prettyPrinted`, temp file + `rename(2)`.
///
/// The one behavioural difference from `ConfigStore` is that ``load()``
/// auto-creates the file when it is absent — every machine needs an identity
/// before it can resolve a shared `config.json`, and there is exactly one
/// sensible default (the slugified hostname).
public struct MachineStore: Sendable {
    public let paths: AppPaths
    /// Snapshot of the process environment, read once at construction.
    /// Injected rather than read at the point of use so tests can exercise
    /// `RESTIC_STATION_MACHINE_ID` hermetically instead of mutating a
    /// process-global that every other test in the run can see.
    private let environment: [String: String]

    public init(paths: AppPaths) {
        self.init(paths: paths, environment: ProcessInfo.processInfo.environment)
    }

    init(paths: AppPaths, environment: [String: String]) {
        self.paths = paths
        self.environment = environment
    }

    /// A store that ignores `RESTIC_STATION_MACHINE_ID` entirely — it reads
    /// and writes the host's **persistent, on-disk identity**.
    ///
    /// Use this for any path that *writes* `machine.json` for a reason
    /// unrelated to identity, the v1 → v2 migration's `resticPath`
    /// relocation being the only one today. The override is documented as
    /// non-persistent; a load-mutate-save round trip through the normal
    /// store would quietly bake a temporary test/profile id into the file,
    /// and the host would keep applying that profile's `machines` overrides
    /// long after the variable was unset.
    public static func persistentIdentity(paths: AppPaths) -> MachineStore {
        MachineStore(paths: paths, environment: [:])
    }

    /// Temp file for the atomic write — fixed, not randomized, for the same
    /// reason as `ConfigStore.tempConfigFile`.
    var tempMachineFile: URL {
        paths.machineFile.deletingLastPathComponent()
            .appendingPathComponent(paths.machineFile.lastPathComponent + ".tmp", isDirectory: false)
    }

    /// Reads `machine.json`, creating it with a generated `machineId` when
    /// it does not exist yet.
    ///
    /// `RESTIC_STATION_MACHINE_ID`, when set and non-empty, replaces the
    /// `machineId` in the returned value. It is applied *after* the file is
    /// read (or created) and is never written back, so switching profiles
    /// with the variable does not rewrite the host's own identity.
    ///
    /// Creating the file is best-effort: a host whose data directory is not
    /// writable still gets a usable identity in memory rather than a hard
    /// failure, and the generated id is a deterministic function of the
    /// hostname, so it stays stable across runs anyway.
    ///
    /// - Throws: ``MachineError`` for a file written by a newer build or
    ///   holding an unusable `machineId`, and any decode error. Both are
    ///   deliberately fatal: guessing here would silently resolve the wrong
    ///   set of overrides.
    public func load() throws -> MachineConfig {
        var machine: MachineConfig

        if FileManager.default.fileExists(atPath: paths.machineFile.path) {
            let data = try Data(contentsOf: paths.machineFile)
            machine = try ConfigStore.makeDecoder().decode(MachineConfig.self, from: data)
            if machine.version > MachineConfig.currentVersion {
                throw MachineError.newerVersion(found: machine.version, supported: MachineConfig.currentVersion)
            }
            guard MachineIdentity.isValid(machine.machineId) else {
                throw MachineError.invalidMachineId(machine.machineId)
            }
        } else {
            machine = MachineConfig(machineId: MachineIdentity.generate())
            try? save(machine)
        }

        if let override = environment[MachineIdentity.environmentOverrideKey], !override.isEmpty {
            guard MachineIdentity.isValid(override) else {
                throw MachineError.invalidMachineId(override)
            }
            machine.machineId = override
        }
        return machine
    }

    /// Validates the `machineId`, then writes atomically (temp file +
    /// `rename(2)`), creating the data directory if needed.
    public func save(_ machine: MachineConfig) throws {
        guard MachineIdentity.isValid(machine.machineId) else {
            throw MachineError.invalidMachineId(machine.machineId)
        }
        try paths.ensureDirectories()
        let data = try ConfigStore.makeEncoder().encode(machine)
        try data.write(to: tempMachineFile)
        try AtomicFile.rename(from: tempMachineFile, to: paths.machineFile)
    }
}
