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

        // Both sides are normalized: restic records the paths it was given
        // after its own normalization, while config.json keeps the operator's
        // string verbatim. Comparing them raw made `/a//b` and `/a/b` — the
        // same directory — unequal, so every snapshot fell into
        // `unattributed` and purge silently did nothing.
        let comparableSources = Set(sourcePaths.map(Self.normalizedForComparison))
        let attributed = snapshots.filter { snapshot in
            let pathsMatch = Set(snapshot.paths.map(Self.normalizedForComparison))
                .isSubset(of: comparableSources)
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

    /// Lexically normalizes an absolute path so two spellings of the same
    /// directory compare equal.
    ///
    /// Collapses repeated separators and strips a trailing separator. It is
    /// deliberately **pure**: this type has no filesystem or restic
    /// dependency, so no symlink is resolved and the disk is never consulted.
    /// `.` and `..` are left alone for the same reason — resolving them
    /// lexically is wrong in the presence of symlinks, and
    /// `AppConfig.validate()` already requires absolute source paths.
    ///
    /// Comparison only. Never write a normalized path back to config, and
    /// never pass one to restic: the operator's string stays authoritative.
    static func normalizedForComparison(_ path: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(path.count)
        var previousWasSeparator = false
        for character in path {
            if character == "/" {
                if previousWasSeparator { continue }
                previousWasSeparator = true
            } else {
                previousWasSeparator = false
            }
            collapsed.append(character)
        }
        if collapsed.count > 1, collapsed.hasSuffix("/") {
            collapsed.removeLast()
        }
        return collapsed
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
        /// Local process-control state failed before any restic preview
        /// command ran. Distinct from `failed`, which means the repository
        /// query itself could not complete.
        case infrastructureFailure
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

/// One purge preview pass over a set's destinations, together with the
/// capability it earned.
///
/// This type exists so that the preview and the token cannot disagree about
/// which restic binary they describe.  ``BackupEngine/previewPurgeSession``
/// resolves the executable **once, before the first query**, pins every
/// preview command to it, and mints the token against that same identity —
/// so "what the operator reviewed" and "what the token authorizes" are the
/// same program by construction, not by the caller remembering to make them
/// so (#118).
///
/// ``token`` is `nil` when there is nothing destructive to authorize: no
/// patterns, no attributed snapshots, or a destination that did not finish
/// its preview.
public struct PurgePreviewSession: Sendable {
    public struct DestinationPreview: Sendable {
        public let destination: Destination
        public let result: PurgePlanResult

        public init(destination: Destination, result: PurgePlanResult) {
            self.destination = destination
            self.result = result
        }
    }

    public let previews: [DestinationPreview]
    public let token: PreviewToken?

    public init(previews: [DestinationPreview], token: PreviewToken?) {
        self.previews = previews
        self.token = token
    }
}

/// A completed token-gated purge group.  `children` are ordinary run records
/// (`RunKind.purge`), so callers can report and audit every destination
/// without ever exposing the preview token itself.
public struct PurgeRunResult: Equatable, Sendable {
    public let status: RunStatus
    public let children: [SetRunChild]
    /// Exact unambiguous snapshot id prefixes proven to be the output
    /// generation of each successful rewrite. Callers use these ids for
    /// `restic copy` so a snapshot created after the purge query cannot bypass
    /// the rewrite and hitch a ride to a mirror.
    public let snapshotIDsByDestination: [UUID: [String]]

    public init(
        status: RunStatus,
        children: [SetRunChild],
        snapshotIDsByDestination: [UUID: [String]] = [:]
    ) {
        self.status = status
        self.children = children
        self.snapshotIDsByDestination = snapshotIDsByDestination
    }
}

/// Failures while preparing or recording a token-gated purge. Messages and
/// CLI classification intentionally never carry token material.
public enum PurgeApplyError: Error, Equatable, Sendable {
    case token(PreviewTokenError)
    case tokenDoesNotMatchCurrentPlan
    case busy
    /// The set lock could not be *used* — not held by someone else, but
    /// unopenable, wrong owner, or on an uncreatable directory. Kept apart
    /// from ``busy`` because a caller may sensibly retry contention and must
    /// never quietly retry a broken lock directory (#110).
    case lockUnusable(String)
    /// Local durable state failed outside set-lock acquisition. The flag is
    /// required because a rewrite or an earlier destination may already have
    /// changed repository data before terminal history or watermark storage
    /// failed; callers must not encourage a blind retry in that case.
    case infrastructureFailure(reason: String, operationMayHaveRun: Bool)
    /// A destructive run's canonical id is known and must be returned as
    /// structured CLI data rather than flattened into presentation text.
    case auditFailure(reason: String, operationMayHaveRun: Bool, runId: String)
    case destinationOffline(destinationId: UUID)
    case unavailable
    /// No restic executable could be identified, so no destructive purge
    /// capability may be minted or honoured. Distinct from ``unavailable``
    /// because the remedy is specific: restore the configured binary
    /// (#109 exact-head review).
    case resticUnavailable
}
