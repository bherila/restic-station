/// Whether **Apply retention now** — the manual, operator-initiated
/// application of a set's retention policy — may run at all.
///
/// It may not, and this type is the single place that says so.
///
/// ## Why
///
/// `BackupEngine.runPrune` is the manual path, and it carries two defects
/// that the scheduled path does not:
///
/// 1. **Its mirror-safety proof is a persisted wall-clock comparison**
///    (`mirrorSyncedAt >= primarySyncedAt`), which a clock rollback, a
///    copied state directory, or an external repository change can satisfy
///    while the mirror is genuinely behind — issue #111.
/// 2. **No exact plan crosses the app/helper boundary.** The confirmation
///    the operator reads is built from a dry run, but only the
///    configuration fingerprint is forwarded; the helper then re-derives
///    the policy against whatever repository state exists at apply time.
///    A backup landing between preview and confirm changes the removal set
///    from the one that was authorized — issue #82.
///
/// Scheduled retention inside `runSet` has neither defect: it prunes a
/// mirror only when *this run's* copy to it succeeded — a live proof, not a
/// stored timestamp — and it orders secondaries before the primary. So
/// disabling the manual path removes both defects from shipping code rather
/// than deferring them behind a flag.
///
/// ## What this costs
///
/// Timing, not capability. A mirror that is behind was already refused by
/// the manual path's own freshness guard, so nothing that used to work
/// stops working. A mirror that is caught up has its retention applied
/// after its next successful scheduled copy, and the primary's is applied
/// at the end of every scheduled run. Repositories do not grow without
/// bound; cleanup is deferred to the schedule.
///
/// ## Deliberately not configurable
///
/// No environment variable, no `--force`, no preference. A containment that
/// can be switched off by the party it constrains is not a containment.
/// Tests that need the underlying mechanics call the internal
/// `BackupEngine.runPruneUnchecked(_:expectedExecutableIdentity:)` through
/// `@testable`, which is unreachable from any shipping caller.
///
/// Re-enabling this is the acceptance criterion for #111 and #82 together.
public enum ManualRetentionApplyAvailability {
    /// Always `false` for now. When #111 and #82 land, this becomes a real
    /// condition rather than a constant, and the two issues' proofs — live
    /// repository synchronization and an exact plan token — become its
    /// preconditions.
    public static let isEnabled = false

    /// Operator-facing explanation. Shared by the CLI refusal, the app's
    /// disabled affordance, and `docs/ui-spec.md`, so the three cannot
    /// drift into saying different things about the same posture.
    /// Deliberately says what a scheduled run *does*, not that one is
    /// imminent. Whether a tick will actually happen depends on the
    /// background agent being registered and on the set running on this
    /// machine — neither of which this string can know, and both of which
    /// it would be lying about if it promised a schedule outright.
    public static let reason = """
        Applying retention manually is unavailable in this build while exact-plan \
        authorization is completed. Retention is applied by scheduled runs instead: \
        each successful scheduled run cleans the primary, and cleans any mirror whose \
        copy in that run succeeded. This delays cleanup; it does not remove it. \
        Previewing cleanup is read-only and remains available.
        """
}
