import Foundation
import ResticStationCore

/// The single place T27's "what will this machine do, and what did it
/// exclude — and why" report is assembled, shared by `config validate`'s
/// effective-plan section and `config show`. Building it once, in one place,
/// is what keeps the two commands from ever disagreeing about what "enabled
/// here" means.
///
/// Built from **both** resolution views deliberately (per
/// `HelperContext`'s doc comment and `docs/data-model.md` §Per-machine
/// scoping): `addressable` supplies the full set of sets/destinations to
/// describe (nothing dropped), and `scheduled` supplies which of them
/// actually run here plus *why* the rest do not. Reading only `scheduled`
/// would silently omit every excluded set and destination from the report —
/// exactly the failure this whole task exists to prevent.
struct EffectiveConfigReport: Encodable {
    struct DestinationEntry: Encodable {
        let id: UUID
        let label: String
        let repoURL: String
        let isPrimary: Bool
        let nonSecretEnv: [String: String]
        /// This machine actually writes to (or reads from, for `.scheduling`
        /// purposes) this destination — i.e. it is present in the
        /// `.scheduling` view, not just the `.addressable` one.
        let enabledHere: Bool
    }

    struct SetEntry: Encodable {
        let id: UUID
        let name: String
        /// This machine backs this set up — present in the `.scheduling`
        /// view. `false` means every field below still describes the
        /// *addressable* shape (sources/schedule as this machine would see
        /// them if it did run the set), which is what `restore`/`probe-repo`
        /// still use even when a set never backs up here.
        let enabledHere: Bool
        let sources: [String]
        let excludes: [String]
        let purgeExcludes: [String]
        let schedule: Schedule
        let retention: RetentionPolicy?
        let checkPolicy: CheckPolicy?
        let stalenessWarningDays: Int
        let destinations: [DestinationEntry]

        private enum CodingKeys: String, CodingKey {
            case id, name, enabledHere, sources, excludes, purgeExcludes, schedule, retention, checkPolicy
            case stalenessWarningDays, destinations
        }

        // Explicit `null` for `retention`/`checkPolicy` when absent, matching
        // `AppConfig.encode(to:)`'s house convention (`docs/data-model.md`
        // preamble) — this is a documented `--json` interface, not debug
        // output, so it gets the same "never omit, always null" stability
        // guarantee every persisted file gets.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(enabledHere, forKey: .enabledHere)
            try container.encode(sources, forKey: .sources)
            try container.encode(excludes, forKey: .excludes)
            try container.encode(purgeExcludes, forKey: .purgeExcludes)
            try container.encode(schedule, forKey: .schedule)
            try container.encode(retention, forKey: .retention)
            try container.encode(checkPolicy, forKey: .checkPolicy)
            try container.encode(stalenessWarningDays, forKey: .stalenessWarningDays)
            try container.encode(destinations, forKey: .destinations)
        }
    }

    struct Exclusion: Encodable {
        /// `"backupSet"` or `"destination"`.
        let subject: String
        /// The owning set's id — equal to `id` when `subject == "backupSet"`.
        let setId: UUID
        let id: UUID
        let name: String
        /// `"disabledForMachine"` | `"noEnabledDestinations"` | `"noSources"`
        /// — `ResolvedOmission.Reason`'s raw cases, spelled out for `--json`
        /// consumers that should not have to parse the prose `description`.
        let reason: String
        /// The same one-line, human-readable explanation `tick` prints —
        /// kept here too so `--json` consumers get the full sentence without
        /// having to re-derive it from `reason` + `name`.
        let description: String
    }

    let machineId: String
    let version: Int
    /// The deprecated top-level fallback, if this view still carries one —
    /// `nil` on any config that has completed v1→v2 migration and has a
    /// `machine.json` resticPath.
    let resticPath: String?
    let sets: [SetEntry]
    let excludedHere: [Exclusion]

    private enum CodingKeys: String, CodingKey {
        case machineId, version, resticPath, sets, excludedHere
    }

    // Explicit `null` for `resticPath` when absent — see `SetEntry.encode(to:)`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machineId, forKey: .machineId)
        try container.encode(version, forKey: .version)
        try container.encode(resticPath, forKey: .resticPath)
        try container.encode(sets, forKey: .sets)
        try container.encode(excludedHere, forKey: .excludedHere)
    }

    /// - Parameters:
    ///   - addressable: every set/destination this machine can address —
    ///     `ResolvedConfig.Scope.addressable`. Supplies the full inventory.
    ///   - scheduled: what this machine actually backs up —
    ///     `ResolvedConfig.Scope.scheduling`. Supplies `enabledHere` and the
    ///     omissions.
    static func build(addressable: ResolvedConfig, scheduled: ResolvedConfig) -> EffectiveConfigReport {
        let scheduledSetsByID = Dictionary(uniqueKeysWithValues: scheduled.config.sets.map { ($0.id, $0) })

        let sets: [SetEntry] = addressable.config.sets.map { set in
            let scheduledSet = scheduledSetsByID[set.id]
            let enabledHere = scheduledSet != nil
            let scheduledDestinationIDs = Set((scheduledSet?.destinations ?? []).map(\.id))

            let destinations = set.destinations.map { destination in
                DestinationEntry(
                    id: destination.id,
                    label: destination.label,
                    repoURL: destination.repoURL,
                    isPrimary: destination.isPrimary,
                    nonSecretEnv: destination.nonSecretEnv,
                    enabledHere: scheduledDestinationIDs.contains(destination.id)
                )
            }

            return SetEntry(
                id: set.id,
                name: set.name,
                enabledHere: enabledHere,
                sources: set.sources,
                excludes: set.excludes,
                purgeExcludes: set.purgeExcludes,
                schedule: set.schedule,
                retention: set.retention,
                checkPolicy: set.checkPolicy,
                stalenessWarningDays: set.stalenessWarningDays,
                destinations: destinations
            )
        }

        let excludedHere: [Exclusion] = scheduled.omissions.map { omission in
            let subject: String
            let setId: UUID
            switch omission.subject {
            case .backupSet:
                subject = "backupSet"
                setId = omission.id
            case .destination(let owningSetId):
                subject = "destination"
                setId = owningSetId
            }
            return Exclusion(
                subject: subject,
                setId: setId,
                id: omission.id,
                name: omission.name,
                reason: Self.reasonString(omission.reason),
                description: "\(omission)"
            )
        }

        return EffectiveConfigReport(
            machineId: scheduled.machineId,
            version: addressable.config.version,
            resticPath: addressable.config.resticPath,
            sets: sets,
            excludedHere: excludedHere
        )
    }

    private static func reasonString(_ reason: ResolvedOmission.Reason) -> String {
        switch reason {
        case .disabledForMachine: return "disabledForMachine"
        case .noEnabledDestinations: return "noEnabledDestinations"
        case .noSources: return "noSources"
        }
    }

    // MARK: - Human rendering

    /// One block per set (in config order), then a trailing "excluded here"
    /// section if anything was dropped. Shared verbatim by `config
    /// validate`'s effective-plan section and `config show`'s default
    /// output — see the type doc comment for why sharing this matters.
    func humanLines() -> [String] {
        var lines: [String] = []
        for set in sets {
            let status = set.enabledHere ? "RUNS HERE" : "does not run here"
            lines.append("set \"\(set.name)\" (\(set.id.uuidString.lowercased())) — \(status)")
            lines.append("    sources: \(set.sources.isEmpty ? "(none)" : set.sources.joined(separator: ", "))")
            lines.append("    excludes: \(set.excludes.isEmpty ? "(none)" : set.excludes.joined(separator: ", "))")
            lines.append("    purge excludes: \(set.purgeExcludes.isEmpty ? "(none)" : set.purgeExcludes.joined(separator: ", "))")
            lines.append("    schedule: \(Self.describe(set.schedule))")
            for destination in set.destinations {
                let role = destination.isPrimary ? "primary" : "secondary"
                let suffix = destination.enabledHere ? "" : "  (excluded here)"
                lines.append("      - \(role) \"\(destination.label)\": \(destination.repoURL)\(suffix)")
            }
        }
        if !excludedHere.isEmpty {
            lines.append("")
            lines.append("excluded here, and why:")
            for exclusion in excludedHere {
                lines.append("  - \(exclusion.description)")
            }
        }
        return lines
    }

    static func describe(_ schedule: Schedule) -> String {
        switch schedule {
        case .everyMinutes(let minutes):
            return "every \(minutes) minutes"
        case .hourly(let minute):
            return String(format: "hourly at :%02d", minute)
        case .daily(let hour, let minute):
            return String(format: "daily %02d:%02d", hour, minute)
        case .weekly(let weekday, let hour, let minute):
            let names = ["?", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            let name = (1...7).contains(weekday) ? names[weekday] : "day \(weekday)"
            return String(format: "weekly %@ %02d:%02d", name, hour, minute)
        }
    }
}
