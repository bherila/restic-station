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
///
/// **There are two views, and picking the wrong one is a real bug** — see
/// ``Scope``. Both apply this machine's overrides; they differ only in
/// whether `enabled: false` *removes* things.
public struct ResolvedConfig: Equatable, Sendable {

    /// Which question a resolved view answers.
    ///
    /// The distinction exists because "what do I back up here?" and "which
    /// repositories can I address from here?" are genuinely different
    /// questions, and the milestone's headline case makes the difference
    /// load-bearing: a host set up as restore/mirror-only disables every
    /// set, and must still be able to restore from, probe, and unlock every
    /// repository in the shared config.
    public enum Scope: String, Equatable, Sendable {
        /// **What this machine backs up.** Overrides applied, then sets and
        /// destinations disabled here are dropped (with recorded reasons).
        ///
        /// The right view for `tick`, `run-set` (backup/check/prune), and
        /// the app's health derivation.
        case scheduling

        /// **Every repository this machine can address.** Overrides applied,
        /// **nothing dropped** — `enabled` is ignored, because it means "do
        /// not back up here", not "pretend this repository does not exist".
        ///
        /// The right view for `restore`, `probe-repo`, `unlock`,
        /// `init-secondary`, and every read-only app query that names a
        /// repository (the restore browser, maintenance sizes and
        /// `forget --dry-run`, "Initialize repository").
        case addressable
    }

    /// Which question this value answers. Carried on the value so a mix-up
    /// is visible at the point of use rather than implied by the call site.
    public let scope: Scope
    /// The machine this view was resolved for.
    public let machineId: String
    /// Effective config: overrides applied, every `machines` key stripped,
    /// and — in ``Scope/scheduling`` only — disabled sets and destinations
    /// removed.
    public let config: AppConfig
    /// Every set and destination this view dropped, and why — so the CLI can
    /// *explain* an omission instead of silently doing nothing. Always empty
    /// for ``Scope/addressable``, which drops nothing.
    public let omissions: [ResolvedOmission]

    public init(scope: Scope, machineId: String, config: AppConfig, omissions: [ResolvedOmission]) {
        self.scope = scope
        self.machineId = machineId
        self.config = config
        self.omissions = omissions
    }

    // MARK: - Lookup

    /// The set with this id, from *this* view.
    ///
    /// Callers go through these rather than filtering `config.sets`
    /// themselves: it keeps "which view am I reading?" at the call site and
    /// makes the lookup itself testable in one place.
    public func set(id: UUID) -> BackupSet? {
        config.sets.first { $0.id == id }
    }

    /// The destination with this id and the set that owns it, from *this*
    /// view — with this machine's `repoURL` / `nonSecretEnv` overrides
    /// already applied. A destination id is unique across the whole config
    /// (`docs/data-model.md` §Invariants).
    public func destination(id: UUID) -> (set: BackupSet, destination: Destination)? {
        for set in config.sets {
            if let destination = set.destinations.first(where: { $0.id == id }) {
                return (set, destination)
            }
        }
        return nil
    }

    /// Every destination in this view, paired with its owning set, in config
    /// order. The one sanctioned way to enumerate repositories — nothing
    /// should ever flatten a raw `AppConfig.sets` to build a repository
    /// list, because that skips this machine's `repoURL` overrides.
    public var destinations: [(set: BackupSet, destination: Destination)] {
        config.sets.flatMap { set in
            set.destinations.map { (set: set, destination: $0) }
        }
    }

    /// The same value with `machine.resticPath` preferred over the
    /// deprecated `AppConfig.resticPath`.
    func applying(resticPathFrom machine: MachineConfig) -> ResolvedConfig {
        guard let resticPath = machine.resticPath, !resticPath.isEmpty else {
            return self
        }
        var updated = config
        updated.resticPath = resticPath
        return ResolvedConfig(scope: scope, machineId: machineId, config: updated, omissions: omissions)
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

    /// **What this machine backs up** (`ResolvedConfig.Scope.scheduling`).
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
    /// For anything that *addresses a repository* rather than backing one
    /// up — restore, probe, unlock, size queries — use ``addressable(for:)``
    /// instead, which applies steps 1–2 and skips 3–4.
    ///
    /// **This function depends only on `machineId` — never on the host OS.**
    /// There is no platform branch, no filesystem access and no environment
    /// lookup anywhere in it, so `config.resolved(for: "linux-nas")` returns
    /// the same bytes whether it runs on macOS or on Linux. A test asserts
    /// that on both platforms.
    public func resolved(for machineId: String) -> ResolvedConfig {
        applyOverrides(for: machineId, scope: .scheduling)
    }

    /// **Every repository this machine can address**
    /// (`ResolvedConfig.Scope.addressable`).
    ///
    /// Steps 1–2 of the resolution rules and nothing else: this machine's
    /// `repoURL`, `nonSecretEnv`, `sources` and `schedule` overrides are
    /// applied, and every `machines` map is stripped, but `enabled` is
    /// ignored so **no set and no destination is ever dropped**.
    ///
    /// `enabled: false` means "do not back this up here". It does not mean
    /// "pretend this repository does not exist" — a host configured as a
    /// restore/mirror target by disabling every set must still be able to
    /// restore from, probe, and unlock every repository in the shared
    /// config. Using ``resolved(for:)`` for those operations is the bug this
    /// method exists to make impossible.
    ///
    /// Same platform-independence guarantee as ``resolved(for:)``.
    public func addressable(for machineId: String) -> ResolvedConfig {
        applyOverrides(for: machineId, scope: .addressable)
    }

    /// The single implementation behind both views. `scope` decides only
    /// whether `enabled` removes anything — every override is applied
    /// identically either way, so the two views can never disagree about
    /// what a repository *is*.
    private func applyOverrides(for machineId: String, scope: ResolvedConfig.Scope) -> ResolvedConfig {
        let drops = scope == .scheduling
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
            if drops, override?.enabled == false {
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

                if drops, destinationOverride?.enabled == false {
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
            if drops, effectiveDestinations.isEmpty {
                omissions.append(ResolvedOmission(
                    subject: .backupSet, id: set.id, name: set.name, reason: .noEnabledDestinations
                ))
                continue
            }
            if drops, effectiveSet.sources.isEmpty {
                omissions.append(ResolvedOmission(
                    subject: .backupSet, id: set.id, name: set.name, reason: .noSources
                ))
                continue
            }

            resolvedSets.append(effectiveSet)
        }

        effective.sets = resolvedSets
        return ResolvedConfig(scope: scope, machineId: machineId, config: effective, omissions: omissions)
    }

    /// ``resolved(for:)`` plus the one host-local value that lives outside
    /// `config.json`: `machine.resticPath` wins over the deprecated
    /// `AppConfig.resticPath`, which stays as the fallback so a config
    /// written before schema v2 keeps working untouched.
    public func resolved(for machine: MachineConfig) -> ResolvedConfig {
        resolved(for: machine.machineId).applying(resticPathFrom: machine)
    }

    /// ``addressable(for:)`` with the same host-local `resticPath` applied.
    public func addressable(for machine: MachineConfig) -> ResolvedConfig {
        addressable(for: machine.machineId).applying(resticPathFrom: machine)
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
