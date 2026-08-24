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
/// disabling the manual path removes both defects from the shipping
/// *retention* path rather than deferring them behind a flag.
/// (`runPruneRepository` — reclaim space — keeps the same timestamp
/// comparison, but there it is defense in depth rather than the load-bearing
/// proof: reclaim only drops packs unreferenced within that one repository,
/// so a behind mirror's extra snapshots keep their data. #111 tracks it.)
///
/// ## What this costs
///
/// Timing, not capability. A mirror that is behind was already refused by
/// the manual path's own freshness guard, so nothing that used to work
/// stops working. A mirror that is caught up has its retention applied
/// after the next successful backup run's copy to it, and the primary's is
/// applied at the end of every backup run — scheduled tick and hand-started
/// Back Up Now alike, since `runSet` applies retention regardless of
/// trigger. Repositories do not grow without bound; cleanup is deferred to
/// the next backup run rather than removed.
///
/// One genuine capability exception: retention runs only after a
/// **successful** backup (`runSet` bails — "no copies, no retention" — when
/// the backup child fails). A set whose backups themselves fail, a full
/// destination volume being the canonical case, therefore receives no
/// retention at all, and with this gate closed there is no in-product way
/// to free that space by dropping snapshots ("Reclaim space" only removes
/// packs nothing references). Recovery is `restic forget` by hand against
/// the affected repository. This is deliberate: a break-glass flag here
/// would be a bypass of the very containment this type exists to hold.
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
    /// Deliberately says what a backup run *does*, not that one is
    /// imminent. Whether a run will actually happen depends on the
    /// background agent, the operator, and machine scope — none of which
    /// this string can know. "Scheduled, or started by hand" is the whole
    /// truth: `runSet` applies retention regardless of trigger, so a
    /// hand-started backup cleans up exactly as a scheduled one does.
    ///
    /// UI-agnostic on purpose — this is also the helper's stderr message,
    /// so it must not name app buttons. The app's copy names **Back Up
    /// Now**; `docs/cli-json.md` names `--kind backup`.
    /// "This delays cleanup; it does not remove it" used to end this
    /// message — deleted because it is false in the one case where the
    /// operator most needs the truth: a set whose backups are failing gets
    /// no retention at all, and the recovery path belongs here, in the
    /// message they are actually reading, not only in the docs.
    public static let reason = """
        Applying retention manually is unavailable in this build while exact-plan \
        authorization is completed. Retention is still applied by every backup run, \
        scheduled or started by hand: each successful run cleans the primary, and any \
        mirror whose copy in that run succeeded. If backups themselves are failing \
        (for example, a full volume), free space with restic forget by hand. \
        Previewing cleanup is read-only and remains available.
        """
}
