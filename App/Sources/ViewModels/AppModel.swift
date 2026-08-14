import AppKit
import Combine
import Foundation
import ResticStationCore

/// The object every screen builds on (`docs/ui-spec.md` §Shell): it owns the
/// loaded `AppConfig`, the live on-disk state (`StateWatcher`), the launchd
/// registration (`LaunchdManager`), helper invocation (`HelperInvoker`), and
/// the derived health values the menu bar and the set list render.
///
/// Two rules it exists to enforce:
///
/// 1. **All mutations go config-edit → save → (if schedule-relevant)
///    kickstart tick.** `saveConfig(_:)` is the only writer of `config.json`;
///    it validates first (so an invalid draft can never reach disk) and asks
///    `ConfigDiff` whether launchd needs to hear about the change.
/// 2. **The app never computes schedules** (`docs/scheduling.md` §What the
///    app does). `SetHealth.nextDue` is display-only; the helper's `tick`
///    remains the sole decider of what actually runs.
///
/// Derived state is recomputed on demand — when config changes, when
/// `StateWatcher` publishes, when the launchd status is refreshed, and
/// whenever a window or the menu appears (`refresh()`). There is no timer:
/// per T12, the app must be idle when nothing is happening, and the only
/// purely time-driven transition (a destination crossing its staleness
/// threshold) is a day-scale event that `refresh()` picks up.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published state

    /// The loaded configuration, **as written** — every per-machine
    /// `machines` override still on it. This is the value the editors read
    /// and `saveConfig(_:)` writes back, which is what keeps round-tripping
    /// safe: the app does not yet edit `machines` keys (per-machine editing
    /// UI is a follow-up), and it must never drop the ones it finds.
    /// Read-only to views; edits go through `saveConfig(_:)` /
    /// `updateConfig(_:)`.
    @Published private(set) var config: AppConfig
    /// **What this machine backs up** (`ResolvedConfig.Scope.scheduling`):
    /// overrides applied, sets and destinations this machine does not run
    /// removed, `resticPath` filled in from `machine.json`.
    ///
    /// Health, staleness and the menu bar read this one, so the app shows
    /// what this machine actually does. Anything that *names a repository*
    /// reads ``addressableConfig`` instead; anything *edited* reads `config`.
    @Published private(set) var resolvedConfig: AppConfig
    /// **Every repository this machine can address**
    /// (`ResolvedConfig.Scope.addressable`): the same overrides applied, but
    /// nothing dropped.
    ///
    /// Every read-only query and utility that names a repository goes
    /// through this — the restore browser, maintenance sizes and
    /// `forget --dry-run`, "Initialize repository". Using `config` there
    /// would address the *shared* `repoURL` instead of this machine's, and
    /// using `resolvedConfig` would hide repositories on a host that
    /// disables its sets.
    @Published private(set) var addressableConfig: ResolvedConfig
    /// This host's `machine.json`. Never shared between machines.
    @Published private(set) var machine: MachineConfig
    /// Non-`nil` when `config.json` exists but could not be loaded (corrupt,
    /// invalid, or written by a newer build). While set, saving is refused —
    /// overwriting a config we failed to understand would destroy the user's
    /// backup definitions.
    @Published private(set) var configLoadError: String?
    /// Non-`nil` when `machine.json` exists but could not be read. Tracked
    /// separately from `configLoadError` because it blocks a *different*
    /// write: `machine` is only a generated fallback while this is set, so
    /// persisting it — which restic discovery in Settings would otherwise do
    /// on its own — would overwrite the user's real `machineId` with a guess.
    @Published private(set) var machineLoadError: String?
    /// Last save/validation failure, for surfacing in the UI.
    @Published private(set) var lastConfigError: String?

    /// One entry per configured set, in config order.
    @Published private(set) var setHealths: [SetHealth] = []
    /// Drives the menu bar icon (`docs/ui-spec.md` §Menu bar).
    @Published private(set) var appHealth: AppHealth = .idle

    /// restic binary status for the Settings pane. Discovery itself (probing
    /// `/opt/homebrew/bin` etc.) is T18's `ResticDiscovery`; this only
    /// validates the path already recorded in `AppModel.resticPath`.
    @Published private(set) var resticStatus: ResticStatus = .unknown

    /// Result of the most recent helper invocation started from the UI, so a
    /// "Back Up Now" that comes back `.busy` or `.failed` can be surfaced.
    @Published private(set) var lastHelperMessage: HelperMessage?

    /// Sets with a helper invocation started from this app that has not yet
    /// returned. Union'd with the live `current-run-*.json` state to decide
    /// whether an action is available: there is a short window between
    /// spawning the helper and the run's state file appearing, and a second
    /// click in that window would just collide on the per-set lock.
    @Published private(set) var pendingActionSetIds: Set<UUID> = []

    // MARK: - Collaborators

    let paths: AppPaths
    let configStore: ConfigStore
    let machineStore: MachineStore
    let stateStore: StateStore
    let runStore: RunStore
    let stateWatcher: StateWatcher
    let launchd: LaunchdManager
    let helper: HelperInvoker

    /// The minimum restic the docs require (`docs/restic-cli.md` §version).
    static let minimumResticVersion = "0.17.0"

    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false

    // MARK: - Init

    init(
        paths: AppPaths = .default(),
        launchd: LaunchdManager? = nil,
        helper: HelperInvoker = HelperInvoker(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.configStore = ConfigStore(paths: paths)
        self.machineStore = MachineStore(paths: paths)
        self.stateStore = StateStore(paths: paths)
        self.runStore = RunStore(paths: paths)
        self.stateWatcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        self.launchd = launchd ?? LaunchdManager()
        self.helper = helper
        self.calendar = calendar
        self.now = now

        // **Config first, machine second.** `ConfigStore.load()` may run the
        // v1 → v2 migration, which moves `resticPath` out of `config.json`
        // and into `machine.json`. Reading the machine identity beforehand
        // would capture it without that path, so the first session after an
        // upgrade would resolve `resticPath == nil` and report restic as
        // missing until the app was restarted.
        //
        // Failures are accumulated locally: `self.configLoadError` cannot be
        // *read* until every stored property is initialized, and the machine
        // branch below needs to append to whatever the config branch found.
        var loadFailures: [String] = []

        let loadedConfig: AppConfig
        do {
            loadedConfig = try configStore.load()
        } catch {
            // A default, empty config keeps the UI alive and explainable;
            // `configLoadError` blocks writes so nothing is clobbered.
            loadedConfig = AppConfig()
            loadFailures.append(Self.describe(configLoadFailure: error, path: paths.configFile.path))
        }

        // A machine identity we cannot read is not fatal — the app still
        // shows and edits the shared config — but no overrides can apply, so
        // it blocks writes to both files for the same reason a bad config
        // does. `machineLoadError` is what stops `updateMachine(_:)` from
        // overwriting the unreadable file with the generated fallback below.
        let loadedMachine: MachineConfig
        do {
            loadedMachine = try machineStore.load()
        } catch {
            loadedMachine = MachineConfig(machineId: MachineIdentity.generate())
            let description = Self.describe(machineLoadFailure: error, path: paths.machineFile.path)
            self.machineLoadError = description
            // Appended, not assigned: when *both* files failed, the config
            // diagnosis is the one that explains why the user's backup sets
            // have vanished from the UI, and overwriting it would leave them
            // reading about machine.json instead.
            loadFailures.append(description)
        }

        self.configLoadError = loadFailures.isEmpty ? nil : loadFailures.joined(separator: "\n\n")

        self.machine = loadedMachine
        self.config = loadedConfig
        self.resolvedConfig = loadedConfig.resolved(for: loadedMachine).config
        self.addressableConfig = loadedConfig.addressable(for: loadedMachine)

        observeCollaborators()

        // Derive once before the first render: the menu bar icon is drawn
        // from `appHealth` and can be the only visible part of the app at
        // launch. Reading state before `start()` is safe — every
        // `StateStore`/`RunStore` read tolerates missing files.
        stateWatcher.reloadNow()
        recomputeDerivedState()
    }

    // MARK: - Lifecycle

    /// Starts the state watcher and performs the first derivation. Idempotent
    /// — SwiftUI can call it from more than one `onAppear`.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        stateWatcher.start()
        launchd.refreshStatus()
        recomputeDerivedState()
        Task { await refreshResticInfo() }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        stateWatcher.stop()
    }

    /// Cheap re-read of everything that has no change notification of its own
    /// (the launchd status can be flipped behind our back in System
    /// Settings), plus a re-derivation against the current clock. Call it
    /// when a window or the menu becomes visible.
    func refresh() {
        launchd.refreshStatus()
        stateWatcher.reloadNow()
        recomputeDerivedState()
    }

    // MARK: - Config

    /// Validates, persists, and — when the change can affect what the next
    /// tick does — asks launchd to run one now instead of within
    /// `StartInterval`.
    func saveConfig(_ newConfig: AppConfig) throws {
        if let configLoadError {
            throw AppModelError.configUnreadable(configLoadError)
        }
        do {
            try newConfig.validate()
            try configStore.save(newConfig)
        } catch {
            lastConfigError = "\(error)"
            throw error
        }

        let previous = config
        let previousResticPath = resticPath
        config = newConfig
        resolvedConfig = newConfig.resolved(for: machine).config
        addressableConfig = newConfig.addressable(for: machine)
        lastConfigError = nil
        recomputeDerivedState()

        if ConfigDiff.isScheduleRelevantChange(from: previous, to: newConfig) {
            launchd.kickstartTick()
        }
        if previousResticPath != resticPath {
            Task { await refreshResticInfo() }
        }
    }

    /// Persists an edit to `machine.json` — the host-local half of the
    /// configuration (`docs/data-model.md` §machine.json). Kept separate
    /// from `saveConfig(_:)` because the two files have different lifetimes:
    /// `config.json` is shared across every machine, this one never leaves
    /// the host.
    ///
    /// **This method never writes an identity.** `machine.machineId` here may
    /// be `RESTIC_STATION_MACHINE_ID`'s temporary value — the two-profiles
    /// feature — and this path is reached *automatically* by restic
    /// discovery, not by a user asking to save anything, so persisting it
    /// would silently and permanently rebind the host to a profile it was
    /// only visiting. `savePreservingIdentity(_:)` writes every other field
    /// and keeps the id that is already on disk; the override keeps applying
    /// in memory, which is the whole point of it.
    func updateMachine(_ mutate: (inout MachineConfig) -> Void) throws {
        // While `machine.json` is unreadable, `machine` is a *generated
        // fallback*, not the user's identity. Writing it back would replace
        // a `machineId` we merely failed to parse with one we invented, and
        // every per-machine override keyed to the real id would silently
        // stop applying. Restic discovery in Settings reaches this path on
        // its own, without the user asking to save anything, so the guard
        // has to live here rather than in the callers.
        if let machineLoadError {
            throw AppModelError.machineUnreadable(machineLoadError)
        }

        var draft = machine
        mutate(&draft)
        guard draft != machine else { return }

        let persisted: MachineConfig
        do {
            persisted = try machineStore.savePreservingIdentity(draft)
        } catch {
            lastConfigError = "\(error)"
            throw error
        }

        // Take every field from what was actually written, then restore the
        // in-memory (possibly overridden) id — so this machine keeps
        // resolving against the profile it was launched with.
        var updated = persisted
        updated.machineId = machine.machineId

        let previousResticPath = resticPath
        machine = updated
        resolvedConfig = config.resolved(for: updated).config
        addressableConfig = config.addressable(for: updated)
        lastConfigError = nil
        recomputeDerivedState()

        // Same rule as `saveConfig(_:)`: a machine that just gained a usable
        // restic binary should start backing up now, not within
        // `StartInterval`.
        if previousResticPath != resticPath {
            launchd.kickstartTick()
            Task { await refreshResticInfo() }
        }
    }

    /// The restic binary this machine will actually use: `machine.json`'s
    /// path, else the deprecated `AppModel.resticPath` fallback. Always read
    /// this rather than either field directly.
    var resticPath: String? {
        resolvedConfig.resticPath
    }

    /// `saveConfig` over an inout draft, for call sites that only want to
    /// flip one field.
    func updateConfig(_ mutate: (inout AppConfig) -> Void) throws {
        var draft = config
        mutate(&draft)
        guard draft != config else { return }
        try saveConfig(draft)
    }

    /// Bound to `MenuBarExtra(isInserted:)` and the General settings toggle.
    /// A failed save (only possible when the on-disk config is unreadable) is
    /// recorded in `lastConfigError` rather than thrown — a toggle binding
    /// has nowhere to throw to.
    var showMenuBarIcon: Bool {
        get { config.showMenuBarIcon }
        set {
            do {
                try updateConfig { $0.showMenuBarIcon = newValue }
            } catch {
                lastConfigError = "\(error)"
                objectWillChange.send()
            }
        }
    }

    // MARK: - Health

    func setHealth(for setId: UUID) -> SetHealth? {
        setHealths.first { $0.setId == setId }
    }

    /// `true` when an operation for this set is (or is about to be) in
    /// flight — the disabled condition for per-set actions.
    func isBusy(setId: UUID) -> Bool {
        pendingActionSetIds.contains(setId) || stateWatcher.currentRuns[setId] != nil
    }

    private func recomputeDerivedState() {
        let currentDate = now()
        // Resolved, not raw: a set this machine does not run has no health
        // to report here, and a destination disabled on this machine must
        // not raise a staleness warning for a repo it never writes to.
        // A `current-run-*.json` whose process is gone is not a run in
        // flight. Same predicate for both derivations, and the same one
        // `restic-station-helper status` uses, so the menu bar and the CLI
        // cannot disagree about whether this machine is busy.
        let isRunAbandoned: (CurrentRunState) -> Bool = { [runStore] in
            runStore.liveness(ofCurrentRun: $0) == .abandoned
        }
        setHealths = HealthDerivation.setHealths(
            config: resolvedConfig,
            recentRuns: stateWatcher.recentRuns,
            currentRuns: stateWatcher.currentRuns,
            repoStatuses: stateWatcher.repoStatuses,
            scheduleState: stateWatcher.scheduleState,
            now: currentDate,
            calendar: calendar,
            visibleSince: paths.configurationVisibleSince(),
            isRunAbandoned: isRunAbandoned
        )
        appHealth = HealthDerivation.appHealth(
            setHealths: setHealths,
            runsInFlight: Array(stateWatcher.currentRuns.values),
            // Only a *definite* denial is a warning: a missing
            // `fda-check.json` means the probe has never run (or does not
            // apply on this platform), which the Permissions pane reports as
            // "unknown" (T18) rather than as a problem. The rule lives in
            // Core so the Linux build is held to it too (T25).
            fullDiskAccessDenied: HealthDerivation.fullDiskAccessDenied(from: stateWatcher.fdaCheck),
            backgroundAgentEnabled: launchd.isEnabled,
            isRunAbandoned: isRunAbandoned
        )
    }

    /// `StateWatcher` and `LaunchdManager` are nested `ObservableObject`s;
    /// SwiftUI does not propagate their changes through this one, and their
    /// values feed every derived property here. The `DispatchQueue.main` hop
    /// is what makes this correct rather than off-by-one:
    /// `objectWillChange` fires *before* the new value is stored, so
    /// recomputing synchronously would read the old state. (Main queue, not
    /// `RunLoop.main`: run-loop scheduling stalls while a menu is tracking
    /// events.)
    private func observeCollaborators() {
        for publisher in [stateWatcher.objectWillChange, launchd.objectWillChange] {
            publisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // Delivered on the main queue, i.e. the main actor's
                    // executor — same reasoning as `StateWatcher`'s handlers.
                    MainActor.assumeIsolated {
                        self?.recomputeDerivedState()
                    }
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Actions

    /// "Back Up Now" for one set (`docs/scheduling.md`: the app invokes
    /// `restic-station-helper run-set`, it never runs restic itself).
    /// Fire-and-forget: progress arrives through `StateWatcher`, and only the
    /// final outcome line is recorded here.
    func backUpNow(setId: UUID) {
        guard !isBusy(setId: setId) else { return }
        let setName = config.sets.first { $0.id == setId }?.name ?? "backup set"
        pendingActionSetIds.insert(setId)
        Task { [helper] in
            let result = await helper.backUpNow(setId: setId)
            pendingActionSetIds.remove(setId)
            lastHelperMessage = HelperMessage(setId: setId, setName: setName, result: result, at: now())
            // The helper writes state as it goes, but the final write may
            // land while the watcher's debounce is idle — re-read once.
            refresh()
        }
    }

    func clearLastHelperMessage() {
        lastHelperMessage = nil
    }

    // MARK: - restic

    /// Validates the binary this machine resolves to (`machine.json`'s
    /// `resticPath`, else the deprecated `AppModel.resticPath`) by running
    /// `restic version --json` (`docs/restic-cli.md` §version). Full
    /// discovery — candidate paths, manual locate — is T18.
    func refreshResticInfo() async {
        guard let path = resticPath, !path.isEmpty else {
            resticStatus = .notConfigured
            return
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            resticStatus = .unavailable(path: path, reason: "No executable at \(path).")
            return
        }

        let runner = DefaultProcessRunner()
        do {
            let result = try await runner.run(
                [path, "version", "--json"],
                env: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: 10
            )
            guard result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                resticStatus = .unavailable(
                    path: path,
                    reason: stderr.isEmpty ? "restic version exited \(result.exitCode)." : stderr
                )
                return
            }
            let info = try parseVersion(result.stdout)
            resticStatus = info.meetsMinimum(Self.minimumResticVersion)
                ? .ok(path: path, version: info.version)
                : .tooOld(path: path, version: info.version, minimum: Self.minimumResticVersion)
        } catch {
            resticStatus = .unavailable(path: path, reason: error.localizedDescription)
        }
    }

    // MARK: - Errors

    private static func describe(configLoadFailure error: Error, path: String) -> String {
        "Could not read \(path): \(error). Restic Station will not change this file until it is "
            + "valid again — fix or move it, then reopen Restic Station."
    }

    private static func describe(machineLoadFailure error: Error, path: String) -> String {
        "Could not read \(path): \(error). Restic Station cannot tell which machine it is running on, "
            + "so per-machine settings do not apply and saving is disabled — fix or delete that file "
            + "(it is re-created automatically), then reopen Restic Station."
    }
}

// MARK: - ResticStatus

/// The four states `docs/ui-spec.md` §Settings asks the restic chip to show.
enum ResticStatus: Equatable, Sendable {
    /// Not probed yet.
    case unknown
    /// No path in `AppModel.resticPath` (first launch, before T18's discovery).
    case notConfigured
    case ok(path: String, version: String)
    case tooOld(path: String, version: String, minimum: String)
    case unavailable(path: String, reason: String)
}

// MARK: - HelperMessage

/// The outcome of a UI-initiated helper invocation, with enough context to
/// name the set it belongs to.
struct HelperMessage: Equatable, Sendable, Identifiable {
    let id = UUID()
    let setId: UUID
    let setName: String
    let result: HelperResult
    let at: Date

    var isError: Bool { !result.isSuccess }

    /// "What failed (set), the mapped reason, one next step"
    /// (`docs/ui-spec.md` §Copy/tone rules).
    var text: String {
        switch result {
        case .ok:
            return "\(setName): backup started."
        case .busy:
            return "\(setName): another operation for this backup set is already running. "
                + "Wait for it to finish, then try again."
        case .offline(let output), .failed(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(setName): the backup could not be started. See Runs for the log."
                : "\(setName): \(detail)"
        }
    }
}

// MARK: - AppModelError

enum AppModelError: LocalizedError {
    case configUnreadable(String)
    case machineUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .configUnreadable(let detail):
            return "Restic Station cannot save changes while the existing configuration is unreadable.\n\n\(detail)"
        case .machineUnreadable(let detail):
            return "Restic Station cannot save this machine's settings while machine.json is unreadable — "
                + "writing it now would replace this machine's identity with a generated one.\n\n\(detail)"
        }
    }
}
