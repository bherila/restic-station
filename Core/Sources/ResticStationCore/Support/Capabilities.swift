import Foundation

// MARK: - Safety classes

/// What a helper command can change (#83). Descriptive metadata for agents
/// choosing a command, **not authorization**: locks, preview tokens, config
/// validation and secret boundaries stay where they are.
///
/// A command's class describes its own effect. Start-up shared by every
/// command that loads configuration (creating `machine.json`, migrating
/// `config.json`) is not counted; `version` and `capabilities` skip it.
///
/// Five classes, not the four #83 proposed: `configurationWrite` is split
/// out of `localStateWrite`, because `secret rm` or `config import` changes
/// what every later backup does, and an agent must not read that as "updates
/// a cache".
public enum CommandSafetyClass: String, CaseIterable, Sendable, Encodable {
    /// Changes nothing, locally or in a repository.
    case readOnly
    /// Writes local files only: observations or bookkeeping (repo-status,
    /// the FDA probe result, a preview token, a cleared migration notice),
    /// or an output file the caller named (`config export --out`). Never
    /// configuration, secrets or a repository.
    case localStateWrite
    /// Changes configuration, stored secrets, the exclusion list, or host
    /// integration (the CLI symlink, the systemd timer).
    case configurationWrite
    /// Writes to a repository or restores from one: initializes, restores,
    /// unlocks, backs up without retention.
    case repositoryWrite
    /// Can remove repository data: `forget`, `prune`, `rewrite --forget`.
    case destructive
}

// MARK: - Command registry

/// One helper command as `capabilities --json` publishes it.
public struct CommandCapability: Sendable, Equatable {
    /// The full command path, as typed: `"snapshots list"`.
    public let name: String
    /// Whether it has a `--json` mode (`docs/cli-json.md` §Command matrix).
    public let json: Bool
    public let safetyClass: CommandSafetyClass
    /// Built only into the Linux helper (`timer …`).
    public let linuxOnly: Bool

    init(_ name: String, json: Bool, _ safetyClass: CommandSafetyClass, linuxOnly: Bool = false) {
        self.name = name
        self.json = json
        self.safetyClass = safetyClass
        self.linuxOnly = linuxOnly
    }
}

/// The one inventory of helper commands, shared by `capabilities --json`
/// and any future adapter (#83). The helper's registration test fails when
/// a command is added to the binary without an entry here or in
/// ``excludedCommands`` — the explicit decision #83 asks for.
public enum CommandRegistry {
    public static let commands: [CommandCapability] = [
        // Inspection.
        CommandCapability("version", json: true, .readOnly),
        CommandCapability("capabilities", json: true, .readOnly),
        CommandCapability("status", json: true, .readOnly),
        CommandCapability("sets list", json: true, .readOnly),
        CommandCapability("runs list", json: true, .readOnly),
        CommandCapability("runs show", json: true, .readOnly),
        CommandCapability("config show", json: true, .readOnly),
        CommandCapability("config validate", json: true, .readOnly),
        CommandCapability("excludes show", json: true, .readOnly),
        CommandCapability("secret list", json: true, .readOnly),
        CommandCapability("cli status", json: true, .readOnly),
        CommandCapability("timer status", json: false, .readOnly, linuxOnly: true),
        CommandCapability("backup dry-run", json: true, .readOnly),
        CommandCapability("snapshots list", json: true, .readOnly),
        CommandCapability("retention preview", json: true, .readOnly),
        // Bookkeeping.
        CommandCapability("probe-repo", json: true, .localStateWrite),
        CommandCapability("fda-check", json: true, .localStateWrite),
        CommandCapability("purge preview", json: true, .localStateWrite),
        CommandCapability("config acknowledge-migration", json: true, .localStateWrite),
        // `--out` creates or replaces the file the caller names.
        CommandCapability("config export", json: false, .localStateWrite),
        // Configuration and host integration.
        CommandCapability("config import", json: false, .configurationWrite),
        CommandCapability("config upgrade", json: true, .configurationWrite),
        CommandCapability("secret set", json: false, .configurationWrite),
        CommandCapability("secret set-env", json: false, .configurationWrite),
        CommandCapability("secret rm", json: false, .configurationWrite),
        CommandCapability("excludes enable", json: false, .configurationWrite),
        CommandCapability("excludes disable", json: false, .configurationWrite),
        CommandCapability("excludes add", json: false, .configurationWrite),
        CommandCapability("excludes remove", json: false, .configurationWrite),
        CommandCapability("excludes set", json: false, .configurationWrite),
        CommandCapability("excludes reset", json: false, .configurationWrite),
        CommandCapability("cli install", json: false, .configurationWrite),
        CommandCapability("cli uninstall", json: false, .configurationWrite),
        CommandCapability("timer install", json: false, .configurationWrite, linuxOnly: true),
        CommandCapability("timer uninstall", json: false, .configurationWrite, linuxOnly: true),
        // Repository writes.
        CommandCapability("init-secondary", json: false, .repositoryWrite),
        CommandCapability("restore", json: false, .repositoryWrite),
        CommandCapability("unlock", json: false, .repositoryWrite),
        // Can remove data: scheduled retention runs inside `tick` and
        // `run-set --kind backup`.
        CommandCapability("tick", json: false, .destructive),
        CommandCapability("run-set", json: false, .destructive),
        CommandCapability("purge apply", json: true, .destructive),
        CommandCapability("maintenance prune", json: true, .destructive),
    ]

    /// Registered commands deliberately left out, and why.
    public static let excludedCommands: [String: String] = [
        "print-password": "hidden; exists for RESTIC_PASSWORD_COMMAND and writes a secret to stdout",
    ]
}

// MARK: - Capability document

/// `capabilities --json`'s `data` (#83, `docs/cli-json.md` §`capabilities`).
///
/// Built by a pure function from what the helper observed, so both
/// platforms' documents can be produced and pinned on either platform.
/// Carries no absolute path, repository URL, source, username, secret name
/// or configuration content.
public struct CapabilityDocument: Sendable, Encodable {
    public enum Platform: String, Sendable, Encodable {
        case macOS
        case linux = "Linux"

        public static var current: Platform {
            #if os(macOS)
            return .macOS
            #else
            return .linux
            #endif
        }
    }

    /// An optional piece of behaviour: whether it is there, and why not.
    public struct Feature: Sendable, Encodable, Equatable {
        public let available: Bool
        public let reason: String?

        static func yes() -> Feature { Feature(available: true, reason: nil) }
        static func no(_ reason: String) -> Feature { Feature(available: false, reason: reason) }

        private enum CodingKeys: String, CodingKey { case available, reason }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(reason, forKey: .reason)
        }
    }

    public struct Application: Sendable, Encodable {
        public let name: String
        public let version: String
    }

    public struct ConfigSchema: Sendable, Encodable {
        /// The newest `config.json` schema this binary reads and writes.
        /// Older ones are migrated on load; a newer one is refused.
        public let current: Int
    }

    public struct Restic: Sendable, Encodable {
        public let available: Bool
        /// The discovered restic's version, reduced to a dotted triple, or
        /// `null`.
        public let version: String?
        public let minimumVersion: String
        public let reason: String?

        private enum CodingKeys: String, CodingKey { case available, version, minimumVersion, reason }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(available, forKey: .available)
            try container.encode(version, forKey: .version)
            try container.encode(minimumVersion, forKey: .minimumVersion)
            try container.encode(reason, forKey: .reason)
        }
    }

    public struct Features: Sendable, Encodable {
        public let backupDryRun: Feature
        public let excludeCloudFiles: Feature
        public let onlineOnlyFilesRefusedAtKernel: Feature
        public let cloudRepositoryDatalessPreflight: Feature
        public let purgeRequiresPreviewToken: Feature
        public let manualRetentionApply: Feature
    }

    public struct Scheduler: Sendable, Encodable {
        /// `launchd` or `systemdUser`.
        public let kind: String
        /// Who registers it: the app (`SMAppService`) or the helper
        /// (`timer install`).
        public let managedBy: String
    }

    public struct SecretBackendInfo: Sendable, Encodable {
        /// `keychain` or `file`, or `null` when
        /// `RESTIC_STATION_SECRET_BACKEND` names neither.
        public let kind: String?
        public let reason: String?

        private enum CodingKeys: String, CodingKey { case kind, reason }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    public struct Command: Sendable, Encodable {
        public let name: String
        public let json: Bool
        public let safetyClass: CommandSafetyClass
        public let available: Bool
        public let reason: String?

        private enum CodingKeys: String, CodingKey { case name, json, safetyClass, available, reason }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(json, forKey: .json)
            try container.encode(safetyClass, forKey: .safetyClass)
            try container.encode(available, forKey: .available)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// Bumped only for a breaking change to this document's shape; adding a
    /// field, feature or command is additive.
    public static let currentVersion = 1

    public let capabilitiesVersion: Int
    public let application: Application
    public let platform: Platform
    public let configSchema: ConfigSchema
    public let restic: Restic
    public let features: Features
    public let scheduler: Scheduler
    public let secretBackend: SecretBackendInfo
    public let safetyClasses: [CommandSafetyClass]
    public let commands: [Command]

    /// - Parameters:
    ///   - discovery: what a search of the well-known locations and `PATH`
    ///     found. The command never reads configuration, so a `resticPath`
    ///     configured on this host is not consulted.
    ///   - environment: consulted only for `RESTIC_STATION_SECRET_BACKEND`.
    public static func build(
        applicationName: String,
        applicationVersion: String,
        platform: Platform,
        discovery: ResticDiscoveryResult,
        environment: [String: String]
    ) -> CapabilityDocument {
        let restic: Restic
        if let chosen = discovery.chosen {
            restic = Restic(
                available: true,
                version: chosen.version.map(CLIFailure.boundedVersion),
                minimumVersion: ResticDiscovery.minimumVersion,
                reason: nil
            )
        } else if let tooOld = discovery.firstTooOld {
            restic = Restic(
                available: false,
                version: tooOld.version.map(CLIFailure.boundedVersion),
                minimumVersion: ResticDiscovery.minimumVersion,
                reason: "the restic found is older than \(ResticDiscovery.minimumVersion)"
            )
        } else if discovery.rejected.isEmpty {
            restic = Restic(
                available: false, version: nil, minimumVersion: ResticDiscovery.minimumVersion,
                reason: "no restic was found in the well-known locations or on PATH"
            )
        } else {
            restic = Restic(
                available: false, version: nil, minimumVersion: ResticDiscovery.minimumVersion,
                reason: "a restic was found but did not run or report a version"
            )
        }

        let isMacOS = platform == .macOS
        let needsRestic = Feature.no("restic is not available")
        let excludeCloudFiles: Feature
        if !isMacOS {
            excludeCloudFiles = .no("restic accepts --exclude-cloud-files only on macOS and Windows")
        } else if let version = restic.version, restic.available {
            excludeCloudFiles = VersionInfo.compareVersions(version, ResticRunner.excludeCloudFilesMinimumVersion) >= 0
                ? .yes()
                : .no("needs restic \(ResticRunner.excludeCloudFilesMinimumVersion) or newer")
        } else {
            excludeCloudFiles = needsRestic
        }
        let features = Features(
            backupDryRun: restic.available ? .yes() : needsRestic,
            excludeCloudFiles: excludeCloudFiles,
            onlineOnlyFilesRefusedAtKernel: isMacOS ? .yes() : .no("Linux has no online-only files"),
            cloudRepositoryDatalessPreflight: isMacOS ? .yes() : .no("Linux has no online-only files"),
            purgeRequiresPreviewToken: .yes(),
            manualRetentionApply: ManualRetentionApplyAvailability.isEnabled
                ? .yes()
                : .no(CLIFailure.bounded(ManualRetentionApplyAvailability.reason))
        )

        // The default is the *document's* platform's, not the host's:
        // `SecretBackend.resolve` falls back to the compiled-in default, which
        // would describe a Linux helper as using the keychain whenever this
        // is built for a platform other than the one running it (a test).
        let secretBackend: SecretBackendInfo
        let override = environment[SecretBackend.environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let backend: SecretBackend = override.isEmpty
                ? (isMacOS ? .keychain : .file)
                : try SecretBackend.resolve(environment: environment)
            if backend == .keychain && !isMacOS {
                // A valid name, but `SecretStoreFactory` refuses it off macOS:
                // there is no `/usr/bin/security` (`keychain-and-fda.md`
                // §Troubleshooting).
                secretBackend = SecretBackendInfo(
                    kind: nil,
                    reason: "\(SecretBackend.environmentKey) selects the keychain, which exists only on macOS"
                )
            } else {
                secretBackend = SecretBackendInfo(kind: backend.rawValue, reason: nil)
            }
        } catch {
            secretBackend = SecretBackendInfo(
                kind: nil,
                reason: "\(SecretBackend.environmentKey) names neither keychain nor file"
            )
        }

        let commands = CommandRegistry.commands.map { command -> Command in
            let unavailable = command.linuxOnly && isMacOS
            return Command(
                name: command.name,
                json: command.json,
                safetyClass: command.safetyClass,
                available: !unavailable,
                reason: unavailable ? "Linux only: on macOS the app registers the scheduler" : nil
            )
        }

        return CapabilityDocument(
            capabilitiesVersion: currentVersion,
            application: Application(name: applicationName, version: applicationVersion),
            platform: platform,
            configSchema: ConfigSchema(current: AppConfig.currentVersion),
            restic: restic,
            features: features,
            scheduler: isMacOS
                ? Scheduler(kind: "launchd", managedBy: "app")
                : Scheduler(kind: "systemdUser", managedBy: "helper"),
            secretBackend: secretBackend,
            safetyClasses: CommandSafetyClass.allCases,
            commands: commands
        )
    }
}
