import Foundation

/// The read-only decision about which snapshots a purge may address.
///
/// This type deliberately has no filesystem or restic dependency.  It is the
/// boundary between an untrusted repository-wide snapshot list and the ids a
/// future destructive operation may be allowed to use.
public struct PurgePlan: Equatable, Sendable {
    public let destinationId: UUID
    public let matched: [Snapshot]
    public let unattributed: [Snapshot]
    public let patterns: [String]

    public init(
        destinationId: UUID,
        snapshots: [Snapshot],
        sourcePaths: Set<String>,
        hostnames: Set<String>,
        patterns: [String]
    ) {
        self.destinationId = destinationId
        self.patterns = patterns

        let attributed = snapshots.filter { snapshot in
            let pathsMatch = Set(snapshot.paths).isSubset(of: sourcePaths)
            let hostnameMatches = hostnames.contains(snapshot.hostname)
                || hostnames.contains(where: {
                    MachineIdentity.slugify($0) == MachineIdentity.slugify(snapshot.hostname)
                })
            return pathsMatch && hostnameMatches
        }
        let matchedIDs = Set(attributed.map(\.id))
        self.matched = attributed
        self.unattributed = snapshots.filter { !matchedIDs.contains($0.id) }
    }

    /// Convenience for pure callers that have a raw, shared `BackupSet`.
    /// The source union includes every machine override, even though each
    /// override replaces (rather than merges) the source list for that one
    /// machine.
    public init(
        destinationId: UUID,
        snapshots: [Snapshot],
        set: BackupSet,
        hostnames: Set<String> = []
    ) {
        var sourcePaths = Set(set.sources)
        if let machines = set.machines {
            for override in machines.values {
                sourcePaths.formUnion(override.sources ?? [])
            }
        }
        self.init(
            destinationId: destinationId,
            snapshots: snapshots,
            sourcePaths: sourcePaths,
            hostnames: hostnames,
            patterns: set.purgeExcludes
        )
    }
}

/// The result of a non-destructive purge preview.  No run record is created:
/// this is a query, not an operation, and its exact argv sequence is asserted
/// by the engine tests.
public struct PurgePlanResult: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case empty
        case ready
        case busy
        case offline
        case failed
    }

    public let plan: PurgePlan
    public let changed: [Snapshot]
    public let rewrite: RewriteResult?
    public let status: Status
    public let message: String?

    public init(
        plan: PurgePlan,
        changed: [Snapshot] = [],
        rewrite: RewriteResult? = nil,
        status: Status,
        message: String? = nil
    ) {
        self.plan = plan
        self.changed = changed
        self.rewrite = rewrite
        self.status = status
        self.message = message
    }
}
