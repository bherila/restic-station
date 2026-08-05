import Foundation

// MARK: - ResolvedConfig

/// The effective, override-free view of a shared `config.json` for one
/// machine (`docs/data-model.md` §Resolution).
///
/// This type is the whole point of schema v2: **resolution happens once, up
/// front**, at the edge that loads the config. Everything downstream —
/// `BackupEngine`, `ScheduleMath`, `RunStore`, the helper subcommands, the
/// app's health derivation — keeps consuming a plain `AppConfig` and never
/// learns that `machineId` exists. Nothing threads a machine identity into
/// the engine, so there is exactly one place a resolution bug can live.
///
/// ``config`` is a normal `AppConfig` with every override applied and every
/// `machines` map stripped, so it is impossible to resolve it a second time
/// or to accidentally save it back over the shared file's overrides.
public struct ResolvedConfig: Equatable, Sendable {
    /// The machine this view was resolved for.
    public let machineId: String
    /// Effective config: overrides applied, disabled sets and destinations
    /// removed, every `machines` key stripped.
    public let config: AppConfig
    /// Every set and destination that resolution dropped, and why — so the
    /// CLI can *explain* an omission instead of silently doing nothing.
    public let omissions: [ResolvedOmission]

    public init(machineId: String, config: AppConfig, omissions: [ResolvedOmission]) {
        self.machineId = machineId
        self.config = config
        self.omissions = omissions
    }
}

// MARK: - ResolvedOmission

/// One set or destination that this machine does not act on, with the reason
/// resolution dropped it.
public struct ResolvedOmission: Equatable, Sendable, CustomStringConvertible {
    public enum Subject: Equatable, Sendable {
        case backupSet
        /// A destination, plus the id of the set that owns it.
        case destination(setId: UUID)
    }

    public enum Reason: Equatable, Sendable {
        /// This machine's override sets `enabled: false`.
        case disabledForMachine
        /// Every destination of the set is disabled on this machine.
        ///
        /// `AppConfig.validate()` invariant 7 rejects this shape, so a
        /// config that came off disk cannot produce it — but the app
        /// resolves *drafts* too, and the resolver must never quietly hand
        /// the engine a set with nothing to write to.
        case noEnabledDestinations
        /// The effective `sources` list is empty (only reachable through an
        /// override that replaces `sources` with `[]`).
        case noSources
    }

    public let subject: Subject
    /// `BackupSet.id` or `Destination.id`.
    public let id: UUID
    /// `BackupSet.name` or `Destination.label`, for the human-readable line.
    public let name: String
    public let reason: Reason

    public init(subject: Subject, id: UUID, name: String, reason: Reason) {
        self.subject = subject
        self.id = id
        self.name = name
        self.reason = reason
    }

    /// One line, in the "what was skipped, why" shape the CLI prints.
    public var description: String {
        let noun: String
        switch subject {
        case .backupSet:
            noun = "backup set"
        case .destination:
            noun = "destination"
        }
        switch reason {
        case .disabledForMachine:
            return "\(noun) \"\(name)\" is disabled on this machine"
        case .noEnabledDestinations:
            return "\(noun) \"\(name)\" has no destinations enabled on this machine"
        case .noSources:
            return "\(noun) \"\(name)\" has no sources on this machine"
        }
    }
}

// MARK: - AppConfig.resolved

extension AppConfig {

    /// The effective configuration for `machineId`.
    ///
    /// The rules, in order (`docs/data-model.md` §Resolution):
    /// 1. start from the top-level values;
    /// 2. apply this machine's override if there is one — **replacing**, not
    ///    merging, each field it specifies;
    /// 3. drop sets and destinations whose effective `enabled` is `false`;
    /// 4. drop a set that ends up with zero enabled destinations, or with
    ///    zero sources while still enabled, recording why.
    ///
    /// Order is preserved: surviving sets and destinations stay in config
    /// order, because the tick runs sets in that order.
    ///
    /// **This function depends only on `machineId` — never on the host OS.**
    /// There is no platform branch, no filesystem access and no environment
    /// lookup anywhere in it, so `config.resolved(for: "linux-nas")` returns
    /// the same bytes whether it runs on macOS or on Linux. A test asserts
    /// that on both platforms.
    public func resolved(for machineId: String) -> ResolvedConfig {
        var effective = self
        var resolvedSets: [BackupSet] = []
        var omissions: [ResolvedOmission] = []

        for set in sets {
            let override = set.machines?[machineId]

            var effectiveSet = set
            effectiveSet.machines = nil
            if let override {
                if let sources = override.sources {
                    effectiveSet.sources = sources
                }
                if let schedule = override.schedule {
                    effectiveSet.schedule = schedule
                }
            }

            // Rule 3, set level: an explicitly disabled set is skipped
            // entirely — scheduling, backup, check and prune.
            if override?.enabled == false {
                omissions.append(ResolvedOmission(
                    subject: .backupSet, id: set.id, name: set.name, reason: .disabledForMachine
                ))
                continue
            }

            // Rule 3, destination level.
            var effectiveDestinations: [Destination] = []
            for destination in set.destinations {
                let destinationOverride = destination.machines?[machineId]

                var effectiveDestination = destination
                effectiveDestination.machines = nil
                if let destinationOverride {
                    if let repoURL = destinationOverride.repoURL {
                        effectiveDestination.repoURL = repoURL
                    }
                    if let nonSecretEnv = destinationOverride.nonSecretEnv {
                        effectiveDestination.nonSecretEnv = nonSecretEnv
                    }
                }

                if destinationOverride?.enabled == false {
                    omissions.append(ResolvedOmission(
                        subject: .destination(setId: set.id),
                        id: destination.id,
                        name: destination.label,
                        reason: .disabledForMachine
                    ))
                    continue
                }
                effectiveDestinations.append(effectiveDestination)
            }
            effectiveSet.destinations = effectiveDestinations

            // Rule 4.
            if effectiveDestinations.isEmpty {
                omissions.append(ResolvedOmission(
                    subject: .backupSet, id: set.id, name: set.name, reason: .noEnabledDestinations
                ))
                continue
            }
            if effectiveSet.sources.isEmpty {
                omissions.append(ResolvedOmission(
                    subject: .backupSet, id: set.id, name: set.name, reason: .noSources
                ))
                continue
            }

            resolvedSets.append(effectiveSet)
        }

        effective.sets = resolvedSets
        return ResolvedConfig(machineId: machineId, config: effective, omissions: omissions)
    }

    /// `resolved(for machineId:)` plus the one host-local value that lives
    /// outside `config.json`: `machine.resticPath` wins over the deprecated
    /// `AppConfig.resticPath`, which stays as the fallback so a config
    /// written before schema v2 keeps working untouched.
    ///
    /// This is the overload every entry point should call — it produces a
    /// config that is complete for this host, restic binary included.
    public func resolved(for machine: MachineConfig) -> ResolvedConfig {
        let resolved = resolved(for: machine.machineId)
        guard let resticPath = machine.resticPath, !resticPath.isEmpty else {
            return resolved
        }
        var config = resolved.config
        config.resticPath = resticPath
        return ResolvedConfig(machineId: resolved.machineId, config: config, omissions: resolved.omissions)
    }

    /// Every `machineId` this config mentions, in either a set's or a
    /// destination's `machines` map. Sorted, so callers (validation, and
    /// T27's `config validate`) iterate deterministically.
    ///
    /// A key here that no `machine.json` in the fleet claims is **not** an
    /// error — machines come and go and the config is shared — it is a
    /// warning for `config validate` to surface.
    public var referencedMachineIds: [String] {
        var ids = Set<String>()
        for set in sets {
            if let machines = set.machines {
                ids.formUnion(machines.keys)
            }
            for destination in set.destinations {
                if let machines = destination.machines {
                    ids.formUnion(machines.keys)
                }
            }
        }
        return ids.sorted()
    }
}
