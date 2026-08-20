import Combine
import Foundation
import ResticStationCore

// MARK: - MaintenanceLookup

/// Everything the Maintenance screen (`docs/ui-spec.md` §Maintenance) needs
/// from `AppModel` that is a *pure lookup* over already-loaded state.
///
/// Free functions over `AppModel` rather than an `extension AppModel`, on
/// purpose. `AppModel.swift` is off-limits to this task, and every other
/// screen is being built in parallel against the same type: two files each
/// adding their own `extension AppModel { func repoStatus(destId:) }` is a
/// redeclaration error that only appears at merge time. Nothing here needs to
/// be a method on `AppModel` — they are all one-line reads of state it
/// already publishes.
@MainActor
enum MaintenanceLookup {

    /// A `ResticRunner` for the app's **own** restic invocations.
    ///
    /// `docs/architecture.md` §The single-code-path rule: the app may run
    /// **read-only** queries (`snapshots`, `ls`, `find`, `stats`,
    /// `cat config`, `version`) directly, for interactive browsing in the
    /// Restore and Maintenance screens. Everything that mutates a repository
    /// — including the real `forget --prune` — goes through the helper.
    ///
    /// `forget --dry-run` is used here under that same exception: it takes no
    /// lock that matters, writes nothing, and produces no run record; it is a
    /// query that happens to be spelled with a destructive verb. The
    /// *unqualified* `forget` is never built anywhere in this target.
    static func resticRunner(_ model: AppModel) throws -> ResticRunner {
        guard let resticPath = model.resticPath, !resticPath.isEmpty else {
            throw MaintenanceError.resticNotConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: resticPath) else {
            throw MaintenanceError.resticUnavailable(path: resticPath)
        }
        let processRunner = DefaultProcessRunner()
        return ResticRunner(
            resticPath: resticPath,
            paths: model.paths,
            secrets: try model.makeSecretStore(),
            runner: processRunner
        )
    }

    /// The set Maintenance operates on, from the **addressable** view.
    ///
    /// Every query on this screen names a repository — `stats` for the size
    /// cards, `forget --dry-run` for the retention preview — so the
    /// destinations it hands to restic must carry this machine's `repoURL`
    /// and `nonSecretEnv` overrides. Raw `config` destinations would let a
    /// size card, or a "will delete N snapshots" count, describe another
    /// machine's repository while the confirm action prunes this one's.
    static func set(_ model: AppModel, id: UUID) -> BackupSet? {
        model.addressableConfig.set(id: id)
    }

    /// Newest finished `check` run for one destination — the "last check
    /// result + date per destination" the spec asks for. `recentRuns` is
    /// newest-first, and `.running` entries are skipped so an in-flight check
    /// never displaces the last real result.
    static func lastCheck(_ model: AppModel, setId: UUID, destId: UUID) -> RunIndexEntry? {
        model.stateWatcher.recentRuns.first {
            $0.kind == .check && $0.setId == setId && $0.destId == destId && $0.status != .running
        }
    }

    /// Newest finished run of `kind` for a set, whatever destination it hit —
    /// used to surface "the run this button just produced".
    static func lastRun(_ model: AppModel, setId: UUID, kind: RunKind) -> RunIndexEntry? {
        model.stateWatcher.recentRuns.first {
            $0.kind == kind && $0.setId == setId && $0.status != .running
        }
    }

    /// `n` from `--read-data-subset=n/t`, i.e. how many slices of this set's
    /// primary have been verified so far (`state/schedule-state.json`).
    static func checkSliceCursor(_ model: AppModel, setId: UUID) -> Int? {
        model.stateWatcher.scheduleState?.sets[setId]?.checkSliceCursor
    }

    static func repoStatus(_ model: AppModel, destId: UUID) -> RepoStatus? {
        model.stateWatcher.repoStatuses[destId]
    }

    /// Staleness per `docs/scheduling.md` §Staleness. Reuses the already
    /// derived `SetHealth` rather than recomputing the rule, so the
    /// Maintenance highlight, the destination list badge and the menu bar
    /// warning can never disagree about the same destination.
    static func isStale(_ model: AppModel, setId: UUID, destId: UUID) -> Bool {
        model.setHealth(for: setId)?.staleDestinationIds.contains(destId) ?? false
    }
}

// MARK: - MaintenanceError

enum MaintenanceError: LocalizedError, Equatable {
    case resticNotConfigured
    case resticUnavailable(path: String)
    /// restic ran and failed; `message` is already user-facing
    /// (`ResticExitClass.userFacingMessage`).
    case restic(destination: String, message: String)
    /// restic exited 0 but printed nothing we could parse.
    case unreadableOutput(destination: String, command: String)
    case noRetentionPolicy

    var errorDescription: String? {
        switch self {
        case .resticNotConfigured:
            return "No restic binary is configured. Open Settings and choose one, then try again."
        case .resticUnavailable(let path):
            return "There is no runnable restic at \(path). Update the path in Settings, then try again."
        case .restic(let destination, let message):
            return "\(destination): \(message)"
        case .unreadableOutput(let destination, let command):
            return "\(destination): restic \(command) finished but returned no readable output. "
                + "Check the destination in Settings, then try again."
        case .noRetentionPolicy:
            return "This backup set keeps every snapshot, so there is nothing to clean up. "
                + "Add a retention policy in the set editor first."
        }
    }
}

// MARK: - RepositorySizes

/// One destination's `stats` card (`docs/ui-spec.md` §Maintenance:
/// raw-data total_size "on disk", restore-size "protected data", snapshot
/// count).
struct RepositorySizes: Equatable, Sendable {
    /// `stats --mode raw-data` → `total_size`: what the repository occupies.
    var onDiskBytes: Int?
    /// default-mode `stats` → `total_size`: the logical size of everything
    /// the snapshots protect, before dedup and compression.
    var protectedBytes: Int?
    var snapshotCount: Int
    /// default-mode `total_file_count`.
    var fileCount: Int?
    var measuredAt: Date
}

/// Per-destination load state for the size cards.
enum SizeState: Equatable {
    case idle
    case loading
    case loaded(RepositorySizes)
    case failed(String)

    var isLoading: Bool { self == .loading }
}

/// The "cached in-memory per app session" store the spec asks for. Kept out
/// of ``MaintenanceModel`` on purpose: that one is a `@StateObject` and dies
/// whenever the user navigates to another sidebar section, which would make
/// every return trip re-run `stats` against every repository — including
/// remote ones.
@MainActor
final class MaintenanceStatsCache {
    static let shared = MaintenanceStatsCache()

    private(set) var sizes: [UUID: RepositorySizes] = [:]

    private init() {}

    func store(_ value: RepositorySizes, destId: UUID) {
        sizes[destId] = value
    }

    /// Called after anything that changes a repository's contents (a prune),
    /// so the card cannot keep showing pre-cleanup numbers.
    func invalidate(destIds: [UUID]) {
        for destId in destIds {
            sizes[destId] = nil
        }
    }
}

// MARK: - Retention preview

/// One destination's `forget --dry-run` result, as rendered in the
/// keep/remove table.
struct DestinationForgetPreview: Identifiable, Equatable, Sendable {
    let destId: UUID
    let label: String
    let isPrimary: Bool
    let keep: [Snapshot]
    let remove: [Snapshot]
    /// Non-`nil` when the dry-run could not be performed against this
    /// destination (an unplugged mirror is the common, expected case).
    let failure: String?

    var id: UUID { destId }
    var removeCount: Int { remove.count }
    var keepCount: Int { keep.count }
}

enum RetentionPreviewState: Equatable {
    case idle
    case loading
    case ready(previews: [DestinationForgetPreview], at: Date)
    case failed(String)
}

/// The confirmation payload for "Apply retention now". Built **only** from a
/// dry-run performed moments earlier — never from whatever the preview table
/// happens to be showing, which may be minutes old and describe a different
/// set of snapshots (T17 acceptance criterion: "Confirmation numbers always
/// come from a fresh dry-run, never from the stale preview").
struct PrunePlan: Identifiable, Equatable {
    enum Action: Equatable {
        case retention
        /// The exact addressable destination that the dry-run described.
        /// Confirm revalidates this value before it asks the helper to make
        /// changes, so a concurrent config edit cannot redirect the prune to
        /// another repository after the user has read the warning.
        case reclaimSpace(destination: Destination, isICloud: Bool)
    }

    let id = UUID()
    let setId: UUID
    let setName: String
    let previews: [DestinationForgetPreview]
    let action: Action

    init(setId: UUID, setName: String, previews: [DestinationForgetPreview]) {
        self.setId = setId
        self.setName = setName
        self.previews = previews
        action = .retention
    }

    init(setId: UUID, setName: String, destination: Destination, isICloud: Bool) {
        self.setId = setId
        self.setName = setName
        previews = []
        action = .reclaimSpace(destination: destination, isICloud: isICloud)
    }

    var confirmationTitle: String {
        switch action {
        case .retention: "Apply retention to \(setName)?"
        case .reclaimSpace: "Reclaim space from \(setName)?"
        }
    }

    var confirmationButton: String {
        switch action {
        case .retention: "Delete Snapshots"
        case .reclaimSpace: "Reclaim Space"
        }
    }

    var canConfirm: Bool {
        switch action {
        case .retention: totalRemoveCount > 0
        case .reclaimSpace: true
        }
    }

    /// Destinations that would actually lose snapshots.
    var affected: [DestinationForgetPreview] {
        previews.filter { $0.failure == nil && $0.removeCount > 0 }
    }

    var totalRemoveCount: Int {
        affected.reduce(0) { $0 + $1.removeCount }
    }

    /// Destinations the dry-run could not reach — named explicitly, because
    /// "nothing will be deleted there" is part of "state exactly what is and
    /// is not deleted" (`docs/ui-spec.md` §Copy/tone rules).
    var unreachable: [DestinationForgetPreview] {
        previews.filter { $0.failure != nil }
    }

    /// The confirmation body. The first block is the spec's copy verbatim,
    /// one line per destination ("This will permanently delete N snapshots
    /// from <dest>."); the rest satisfies the destructive-confirmation rule.
    var confirmationMessage: String {
        if case .reclaimSpace(let destination, let isICloud) = action {
            var lines = [
                "This runs restic prune for \(destination.label). It removes only pack data no current snapshot references; it does not change snapshot retention or touch source files.",
                "Stop other repository activity until it finishes. Prune can take a long time."
            ]
            if isICloud {
                lines.insert(
                    "This repository is in iCloud Drive. Make sure every repository file is fully downloaded locally — not an evicted Optimize Mac Storage placeholder — before continuing. Prune rewrites pack files and iCloud must download then upload them.",
                    at: 1
                )
            }
            return lines.joined(separator: "\n\n")
        }
        var lines: [String] = []
        if affected.isEmpty {
            lines.append("Nothing matches this set's retention policy right now — no snapshots will be deleted.")
        } else {
            for preview in affected {
                let plural = preview.removeCount == 1 ? "snapshot" : "snapshots"
                lines.append("This will permanently delete \(preview.removeCount) \(plural) from \(preview.label).")
            }
        }
        if !unreachable.isEmpty {
            let names = unreachable.map(\.label).joined(separator: ", ")
            lines.append("\(names) could not be reached and will be left untouched.")
        }
        lines.append(
            "Deleted snapshots cannot be recovered. Your source files are not touched, and only "
                + "\(setName)'s repositories are affected."
        )
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - MaintenanceActivity

/// The outcome banner for a helper-backed Maintenance action, with the run it
/// produced when there is one (`unlock` deliberately produces none — see
/// `Helper/Sources/Commands/Unlock.swift`).
struct MaintenanceActivity: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let isError: Bool
    let runId: String?
    let runStatus: RunStatus?
}

/// Which long-running Maintenance action is in flight, so exactly the right
/// button shows a spinner and the rest stay usable.
enum MaintenanceAction: Equatable {
    case prune(setId: UUID)
    case check(setId: UUID)
    case unlock(destId: UUID)
}

// MARK: - MaintenanceModel

/// View state for the Maintenance screen.
///
/// Holds no reference to `AppModel`: every method takes the one the view
/// already has from the environment. That keeps this a plain
/// `@StateObject`-able value with a trivial `init()` (SwiftUI evaluates the
/// default value before the environment is available) and keeps the
/// dependency direction one-way.
///
/// Two restic paths, kept strictly apart (`docs/architecture.md`
/// §single-code-path rule):
///
/// - **App-direct, read-only:** `stats` for the size cards and
///   `forget --dry-run` for the preview and for the pre-confirmation
///   re-check. Nothing here mutates a repository or writes a run record.
/// - **Via the helper:** the real `forget --prune` (`run-set --kind prune`),
///   standalone `prune` (`maintenance prune`; its dry run is an unrecorded
///   read-only helper query),
///   `check` (`run-set --kind check`), and `unlock`. Progress and results
///   come back through `StateWatcher`, exactly like "Back Up Now".
@MainActor
final class MaintenanceModel: ObservableObject {

    /// `nil` until the first render picks the first configured set.
    @Published var selectedSetId: UUID?

    @Published private(set) var sizes: [UUID: SizeState] = [:]
    @Published private(set) var retentionPreview: RetentionPreviewState = .idle
    /// Non-`nil` while the destructive confirmation is on screen.
    @Published var prunePlan: PrunePlan?
    /// A fresh dry-run is running in order to *build* that confirmation.
    @Published private(set) var isPreparingPrune = false
    /// `docs/ui-spec.md` §Maintenance: "Check now (structure-only toggle vs
    /// with-data-slice)". See `IntegritySection` for why this is currently
    /// pinned on.
    @Published var checkReadsDataSlice = true
    @Published private(set) var busyAction: MaintenanceAction?
    @Published var activity: MaintenanceActivity?

    /// How long a single read-only query may take before it is abandoned. A
    /// `stats` pass over a large remote repository is genuinely slow, so this
    /// is generous; without *some* ceiling an unreachable S3 endpoint would
    /// leave a spinner up forever.
    private nonisolated static let queryTimeout: TimeInterval = 300

    init() {
        // Warm the cards from the session cache so switching back to
        // Maintenance is instant and silent.
        for (destId, value) in MaintenanceStatsCache.shared.sizes {
            sizes[destId] = .loaded(value)
        }
    }

    // MARK: - Selection

    /// Resolves the picker's selection against the current config, falling
    /// back to the first set (and coping with the selected set being deleted
    /// in another window).
    func resolvedSet(in model: AppModel) -> BackupSet? {
        if let selectedSetId, let match = MaintenanceLookup.set(model, id: selectedSetId) {
            return match
        }
        // Addressable, for the same reason as `MaintenanceLookup.set`.
        return model.addressableConfig.config.sets.first
    }

    func isBusy(_ action: MaintenanceAction) -> Bool {
        busyAction == action
    }

    var isAnyActionRunning: Bool { busyAction != nil }

    // MARK: - Sizes

    /// Loads (or re-uses) `stats` for every destination of `set`.
    /// - Parameter force: bypasses the session cache — the Refresh button.
    func loadSizes(for set: BackupSet, in model: AppModel, force: Bool = false) {
        for destination in set.destinations {
            loadSizes(for: destination, in: model, force: force)
        }
    }

    func loadSizes(for destination: Destination, in model: AppModel, force: Bool) {
        if !force, let cached = MaintenanceStatsCache.shared.sizes[destination.id] {
            sizes[destination.id] = .loaded(cached)
            return
        }
        if sizes[destination.id]?.isLoading == true { return }
        sizes[destination.id] = .loading

        let runner: ResticRunner
        do {
            runner = try MaintenanceLookup.resticRunner(model)
        } catch {
            sizes[destination.id] = .failed(Self.describe(error))
            return
        }

        Task { [weak self] in
            do {
                let value = try await Self.fetchSizes(destination: destination, runner: runner)
                // Cached before the `self` check: the measurement is worth
                // keeping for the next visit even if this screen is gone.
                MaintenanceStatsCache.shared.store(value, destId: destination.id)
                self?.sizes[destination.id] = .loaded(value)
            } catch {
                self?.sizes[destination.id] = .failed(Self.describe(error))
            }
        }
    }

    /// The two documented `stats` invocations (`docs/restic-cli.md` §stats):
    /// `--mode raw-data` for actual disk usage, default mode (restore-size)
    /// for the logical protected size.
    private nonisolated static func fetchSizes(
        destination: Destination,
        runner: ResticRunner
    ) async throws -> RepositorySizes {
        let rawJSON = try await query(
            .stats(repo: destination.repoURL, mode: .rawData),
            label: "stats --mode raw-data",
            destination: destination,
            runner: runner
        )
        let raw = try parseStats(rawJSON)

        let restoreJSON = try await query(
            .stats(repo: destination.repoURL),
            label: "stats",
            destination: destination,
            runner: runner
        )
        let restore = try parseStats(restoreJSON)

        return RepositorySizes(
            onDiskBytes: raw.totalSize,
            protectedBytes: restore.totalSize,
            // Both modes report the same snapshot count; raw-data is the
            // pass that walks the packs, so take it from there.
            snapshotCount: raw.snapshotsCount,
            fileCount: restore.totalFileCount,
            measuredAt: Date()
        )
    }

    // MARK: - Retention

    /// **Preview cleanup** — `forget --dry-run` against every destination,
    /// rendered as a keep/remove table. Nothing is deleted.
    func previewCleanup(for set: BackupSet, in model: AppModel) {
        guard let policy = set.retention, !policy.isEmpty else {
            retentionPreview = .failed(MaintenanceError.noRetentionPolicy.localizedDescription)
            return
        }
        let runner: ResticRunner
        do {
            runner = try MaintenanceLookup.resticRunner(model)
        } catch {
            retentionPreview = .failed(Self.describe(error))
            return
        }
        retentionPreview = .loading
        Task { [weak self] in
            let previews = await Self.dryRun(set: set, policy: policy, runner: runner)
            self?.retentionPreview = .ready(previews: previews, at: Date())
        }
    }

    /// **Apply retention now**, step 1: a *fresh* dry-run whose counts become
    /// the confirmation's numbers. The visible preview table is refreshed
    /// from the same data, so what the user reads in the dialog and what they
    /// see behind it are the same measurement.
    func prepareApplyRetention(for set: BackupSet, in model: AppModel) {
        guard let policy = set.retention, !policy.isEmpty else {
            retentionPreview = .failed(MaintenanceError.noRetentionPolicy.localizedDescription)
            return
        }
        let runner: ResticRunner
        do {
            runner = try MaintenanceLookup.resticRunner(model)
        } catch {
            retentionPreview = .failed(Self.describe(error))
            return
        }
        isPreparingPrune = true
        Task { [weak self] in
            let previews = await Self.dryRun(set: set, policy: policy, runner: runner)
            guard let self else { return }
            self.isPreparingPrune = false
            let now = Date()
            self.retentionPreview = .ready(previews: previews, at: now)
            self.prunePlan = PrunePlan(setId: set.id, setName: set.name, previews: previews)
        }
    }

    /// **Reclaim space**, step 1: run restic's non-mutating `prune
    /// --dry-run` through the same helper boundary that will perform the real
    /// prune. The one shared `prunePlan` confirmation is intentional: a
    /// destructive action never gets a bypass simply because it leaves
    /// snapshots in place.
    func prepareReclaimSpace(for set: BackupSet, destination: Destination, in model: AppModel) {
        isPreparingPrune = true
        Task { [weak self] in
            let result = await model.helper.pruneRepository(setId: set.id, destId: destination.id, dryRun: true)
            guard let self else { return }
            self.isPreparingPrune = false
            guard result.isSuccess else {
                self.activity = Self.activity(
                    title: "Check reclaim space",
                    subject: set.name,
                    result: result,
                    run: MaintenanceLookup.lastRun(model, setId: set.id, kind: .prune)
                )
                return
            }
            self.prunePlan = PrunePlan(
                setId: set.id,
                setName: set.name,
                destination: destination,
                isICloud: Self.isICloudRepository(destination)
            )
        }
    }

    func cancelApplyRetention() {
        prunePlan = nil
    }

    /// **Apply retention now**, step 2: the confirmed, destructive half —
    /// which goes through the helper, never through this process
    /// (`docs/architecture.md` §The single-code-path rule).
    func confirmApplyRetention(_ plan: PrunePlan, in model: AppModel) {
        prunePlan = nil
        guard let set = MaintenanceLookup.set(model, id: plan.setId) else { return }
        let destIds: [UUID]
        let title: String
        let resultTask: () async -> HelperResult
        switch plan.action {
        case .retention:
            destIds = set.destinations.map(\.id)
            title = "Apply retention"
            resultTask = { await model.helper.prune(setId: plan.setId) }
        case .reclaimSpace(let previewedDestination, _):
            guard let destination = set.destinations.first(where: { $0.id == previewedDestination.id }),
                  destination == previewedDestination else {
                self.activity = Self.activity(
                    title: "Reclaim space",
                    subject: plan.setName,
                    result: .failed(output: "The destination changed after the reclaim preview. Review the updated repository and run a new dry run before confirming."),
                    run: nil
                )
                return
            }
            destIds = [destination.id]
            title = "Reclaim space"
            resultTask = { await model.helper.pruneRepository(setId: plan.setId, destId: destination.id, dryRun: false) }
        }
        busyAction = .prune(setId: plan.setId)
        let existingPruneRunIds = Set(
            model.stateWatcher.recentRuns.lazy
                .filter { $0.kind == .prune && $0.setId == set.id }
                .map(\.runId)
        )
        Task { [weak self] in
            let result = await resultTask()
            guard let self else { return }
            self.busyAction = nil
            model.refresh()
            let latestPrune = MaintenanceLookup.lastRun(model, setId: set.id, kind: .prune)
            let recordedRun: RunIndexEntry?
            if let latestPrune,
               destIds.contains(latestPrune.destId),
               !existingPruneRunIds.contains(latestPrune.runId) {
                recordedRun = latestPrune
            } else {
                recordedRun = nil
            }
            self.activity = Self.activity(
                title: title,
                subject: set.name,
                result: result,
                run: recordedRun
            )
            // Sizes and the keep/remove table both describe a repository
            // that just changed underneath them.
            MaintenanceStatsCache.shared.invalidate(destIds: destIds)
            self.retentionPreview = .idle
            self.loadSizes(for: set, in: model, force: true)
        }
    }

    /// One `forget --json --dry-run` per destination, tolerating per-
    /// destination failure: an unplugged mirror is the expected case, and it
    /// must not hide the primary's result.
    private nonisolated static func dryRun(
        set: BackupSet,
        policy: RetentionPolicy,
        runner: ResticRunner
    ) async -> [DestinationForgetPreview] {
        var previews: [DestinationForgetPreview] = []
        for destination in set.destinations {
            do {
                let json = try await query(
                    .forget(repo: destination.repoURL, policy: policy, dryRun: true),
                    label: "forget --dry-run",
                    destination: destination,
                    runner: runner
                )
                let groups = try parseForget(json)
                previews.append(DestinationForgetPreview(
                    destId: destination.id,
                    label: destination.label,
                    isPrimary: destination.isPrimary,
                    keep: groups.flatMap { $0.keep ?? [] },
                    remove: groups.flatMap { $0.remove ?? [] },
                    failure: nil
                ))
            } catch {
                previews.append(DestinationForgetPreview(
                    destId: destination.id,
                    label: destination.label,
                    isPrimary: destination.isPrimary,
                    keep: [],
                    remove: [],
                    failure: describe(error)
                ))
            }
        }
        return previews
    }

    /// Matches the destination editor's path handling: a valid local path
    /// can spell the iCloud root with harmless `.` or `..` components.
    /// Normalize before deciding whether destructive-maintenance warnings
    /// are required.
    nonisolated static func isICloudRepository(_ destination: Destination) -> Bool {
        let iCloudRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
            .path
        let path = (destination.repoURL as NSString).standardizingPath
        return path == iCloudRoot || path.hasPrefix(iCloudRoot + "/")
    }

    // MARK: - Integrity

    /// **Check now** → `run-set --kind check` (`HelperInvoker.check`), which
    /// checks structure and metadata and verifies the primary's next data
    /// slice, advancing `checkSliceCursor` on success.
    func checkNow(for set: BackupSet, in model: AppModel) {
        busyAction = .check(setId: set.id)
        Task { [weak self] in
            let result = await model.helper.check(setId: set.id)
            guard let self else { return }
            self.busyAction = nil
            model.refresh()
            self.activity = Self.activity(
                title: "Check now",
                subject: set.name,
                result: result,
                run: MaintenanceLookup.lastRun(model, setId: set.id, kind: .check)
            )
        }
    }

    // MARK: - Unlock

    /// The footer utility → the helper's `unlock` subcommand, which writes no
    /// run record by design (see `Helper/Sources/Commands/Unlock.swift`), so
    /// the printed line *is* the result.
    func removeStaleLocks(set: BackupSet, destination: Destination, in model: AppModel) {
        busyAction = .unlock(destId: destination.id)
        Task { [weak self] in
            let result = await model.helper.run(.unlock(setId: set.id, destId: destination.id))
            guard let self else { return }
            self.busyAction = nil
            model.refresh()
            self.activity = Self.activity(
                title: "Remove stale locks",
                subject: destination.label,
                result: result,
                run: nil
            )
        }
    }

    // MARK: - Helper result → banner

    private static func activity(
        title: String,
        subject: String,
        result: HelperResult,
        run: RunIndexEntry?
    ) -> MaintenanceActivity {
        let detail: String
        switch result {
        case .ok(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = trimmed.isEmpty ? "\(subject): finished." : "\(subject): \(trimmed)"
        case .busy:
            detail = "\(subject): another operation for this backup set is already running. "
                + "Wait for it to finish, then try again."
        case .offline(let output), .failed(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = trimmed.isEmpty
                ? "\(subject): the operation could not be completed. See Runs for the log."
                : "\(subject): \(trimmed)"
        }
        return MaintenanceActivity(
            title: title,
            detail: detail,
            isError: !result.isSuccess,
            runId: run?.runId,
            runStatus: run?.status
        )
    }

    func dismissActivity() {
        activity = nil
    }

    // MARK: - Read-only restic query

    /// Runs one read-only restic command and returns the first JSON line it
    /// printed on **stdout**.
    ///
    /// stdout only, via `ResticOutcome.messages` (which `ResticRunner` builds
    /// from stdout lines alone): `rawOutput` also carries stderr, and restic
    /// writes progress and warnings there, so feeding it to a JSON decoder
    /// would fail on repositories that are perfectly healthy. Commands with a
    /// JSON mode but no `message_type` envelope — `stats`, `forget` — decode
    /// to `.unparsed`, which is exactly the raw line we want.
    ///
    /// The *first* JSON line, not the whole stream: `forget` follows its JSON
    /// with plain-text prune progress (`docs/restic-cli.md` §forget), and
    /// tolerating that here means the parser never sees a mixed buffer.
    private nonisolated static func query(
        _ command: ResticCommand,
        label: String,
        destination: Destination,
        runner: ResticRunner
    ) async throws -> Data {
        let outcome = try await runner.run(
            command,
            for: ResticInvocation(destination: destination),
            timeout: queryTimeout
        )
        guard outcome.status.isSuccess else {
            throw MaintenanceError.restic(
                destination: destination.label,
                message: outcome.status.userFacingMessage
            )
        }
        let stdoutLines: [String] = outcome.messages.compactMap { message in
            guard case .unparsed(let line) = message else { return nil }
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let json = stdoutLines.first(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }) else {
            throw MaintenanceError.unreadableOutput(destination: destination.label, command: label)
        }
        return Data(json.utf8)
    }

    /// One user-facing line per the "what failed, mapped reason, one next
    /// step" rule (`docs/ui-spec.md` §Copy/tone rules). `MaintenanceError`
    /// and Core's restic errors already carry that shape; anything else falls
    /// back to its description.
    private nonisolated static func describe(_ error: Error) -> String {
        if let maintenanceError = error as? MaintenanceError {
            return maintenanceError.localizedDescription
        }
        if let runnerError = error as? ResticRunnerError {
            return runnerError.userFacingMessage
        }
        if error is DecodingError {
            return "restic returned output this version of Restic Station could not read. "
                + "Check that the configured restic is 0.17 or newer in Settings."
        }
        return error.localizedDescription
    }
}
