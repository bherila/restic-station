import Combine
import Dispatch
import Foundation
import ResticStationCore

#if canImport(Darwin)
import Darwin
#endif

/// Reactive bridge from the on-disk `state/`, `runs/`, and `locks/`
/// directories to SwiftUI, per `docs/architecture.md` §Process model: **the directory
/// watcher is the source of truth**; the `DistributedNotificationCenter`
/// nudge posted by `StateStore` after every write (see
/// `Core/Sources/ResticStationCore/Engine/StateStore.swift`) is a latency
/// optimization only — it feeds the exact same debounced reload path as the
/// filesystem events, so a dropped/coalesced notification never causes stale
/// UI, only a slightly later (bounded by the next filesystem event) refresh.
///
/// All actual reads go through `StateStore`/`RunStore`. Regenerable state
/// caches tolerate missing/partial/corrupt files; destructive canonical run
/// metadata deliberately fails closed because skipping it could authorize a
/// second destructive launch. `StateWatcher` itself never parses file
/// contents; it only reacts to *that something changed* and re-reads
/// everything through those APIs.
///
/// No polling: every refresh is triggered by a `DispatchSource` filesystem
/// event or a distributed notification, coalesced behind a 250 ms
/// Task-based debounce so a burst of writes (e.g. a throttled progress
/// stream) produces one UI update, not dozens.
@MainActor
public final class StateWatcher: ObservableObject {
    @Published public private(set) var scheduleState: ScheduleState?
    /// Live in-flight run progress, keyed by `BackupSet.id`. Sourced from
    /// `state/current-run-<setId>.json` files, discovered by enumerating
    /// `state/` and matching the `current-run-<uuid>.json` filename pattern
    /// (the UUID is the dictionary key, not read from the file body).
    @Published public private(set) var currentRuns: [UUID: CurrentRunState] = [:]
    /// Destination reachability/sync status, keyed by `Destination.id`.
    /// Sourced from `state/repo-status-<destId>.json` files, discovered the
    /// same way as `currentRuns`.
    @Published public private(set) var repoStatuses: [UUID: RepoStatus] = [:]
    @Published public private(set) var fdaCheck: FdaCheckResult?
    /// `RunStore.recentRuns(limit: 200)`, newest first.
    @Published public private(set) var recentRuns: [RunIndexEntry] = []
    /// Destructive runs whose launch marker has no complete terminal
    /// metadata/index pair. Reconstructed from run history on every reload;
    /// never a second persisted source of truth.
    @Published public private(set) var auditFailures: [RunAuditFailure] = []
    /// Verification itself failed, so absence of a decoded failure is not
    /// evidence of safety. The app treats this as critical and the helper
    /// reports the underlying state-read error.
    @Published public private(set) var auditVerificationFailed = false
    /// Live lock-health result, refreshed for state/run writes and every
    /// change under `locks/`. A lock failure can prevent all other writes,
    /// so the lock directory needs its own event source.
    @Published public private(set) var lockingFailure: LockingHealthFailure?
    /// Byte fingerprint of the currently visible `config.json`, or a stable
    /// sentinel for absence/unreadability. AppModel compares this with the
    /// revision its editors loaded; StateWatcher never decodes the config.
    @Published public private(set) var configFileFingerprint: String
    /// Advances on every observed config revision, even when the bytes later
    /// return to an earlier fingerprint. AppModel uses this ABA-safe identity
    /// to reject reload results overtaken by B -> A replacement sequences.
    @Published public private(set) var configFileRevision: UInt64 = 0

    private let paths: AppPaths
    private let runStore: RunStore
    private let auditHealthLoader: @Sendable () -> AuditHealthRefreshResult
    private let stateStore: StateStore
    private let secretBackend: SecretBackend
    private var configuredSetIds: Set<UUID>

    /// Every filesystem/notification event lands on this serial queue so
    /// source creation/teardown and event handling never race each other.
    /// Deliberately `.main` (not a background queue): it lets the event
    /// handlers use `MainActor.assumeIsolated` to hop straight into
    /// actor-isolated state with no `Task` indirection, since the main
    /// queue *is* the main actor's executor.
    private let watchQueue = DispatchQueue.main

    private var stateDirSource: DispatchSourceFileSystemObject?
    private var runsDirSource: DispatchSourceFileSystemObject?
    private var locksDirSource: DispatchSourceFileSystemObject?
    /// Metadata changes on a child do not emit `.attrib` on its parent
    /// directory vnode. Keep direct sources for every existing lock whose
    /// health is reported, while the directory sources discover creation and
    /// replacement and cause this set to be reconciled.
    private var lockFileSources: [String: DispatchSourceFileSystemObject] = [:]
    /// Watches the immediate parent of `paths.root`. Replacement safety is
    /// an invariant of the lock namespace, and a chmod on this directory
    /// changes only the parent's vnode — none of the sources below the root
    /// receive that event.
    private var rootParentDirSource: DispatchSourceFileSystemObject?
    /// Watches the parent of `rootParentDirSource` so replacement of the
    /// immediate root parent can be discovered after its descriptor becomes
    /// attached to the retired inode.
    private var rootGrandparentDirSource: DispatchSourceFileSystemObject?
    /// Watches `paths.root` purely so that a delete+recreate of `state/`,
    /// `runs/`, or `locks/` (which this watcher cannot keep an open fd across)
    /// has a
    /// second, still-open fd from which to notice the recreation and retry
    /// reopening — see `attemptReopen(_:)`. This is what lets the watcher
    /// survive the directory being deleted and recreated without polling.
    private var rootDirSource: DispatchSourceFileSystemObject?
    /// Direct vnode source catches in-place writes and chmod changes that do
    /// not modify the root directory entry. The root source discovers first
    /// creation and atomic replacement, then this source is reconciled.
    private var configFileSource: DispatchSourceFileSystemObject?

    /// Directories whose watch source is currently unavailable because the
    /// directory didn't exist at the last open attempt (typically: deleted
    /// and not yet recreated). Retried opportunistically whenever
    /// `rootDirSource` fires, and once more on `start()`.
    private var pendingReopen: Set<WatchedDirectory> = []

    private var distributedNotificationObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var explicitAuditRefreshTask: Task<Void, Never>?
    private var isRunning = false
    /// Invalidates an older detached scan whenever any newer synchronous or
    /// asynchronous refresh begins. Detached filesystem reads can finish out
    /// of order; only the newest requested observation may publish UI state.
    private var auditRefreshGeneration: UInt64 = 0

    private enum WatchTarget {
        case rootGrandparent
        case rootParent
        case root
        case directory(WatchedDirectory)
    }

    private enum WatchedDirectory: CaseIterable, Hashable {
        case state
        case runs
        case locks

        func url(paths: AppPaths) -> URL {
            switch self {
            case .state: return paths.stateDir
            case .runs: return paths.runsDir
            case .locks: return paths.locksDir
            }
        }
    }

    private static let stateChangedNotificationName = Notification.Name("net.herila.ResticStation.stateChanged")
    private static let debounceNanoseconds: UInt64 = 250_000_000 // 250 ms, per T12 spec.

    public init(
        paths: AppPaths,
        runStore: RunStore,
        stateStore: StateStore,
        secretBackend: SecretBackend = .configured,
        configuredSetIds: Set<UUID> = []
    ) {
        self.paths = paths
        self.runStore = runStore
        self.auditHealthLoader = {
            do {
                return .success(try runStore.unresolvedAuditFailures())
            } catch {
                return .verificationFailed
            }
        }
        self.stateStore = stateStore
        self.secretBackend = secretBackend
        self.configuredSetIds = configuredSetIds
        self.configFileFingerprint = ConfigStore(paths: paths).fileFingerprint()
    }

    /// Deterministic audit-loader seam for ordering tests. Production always
    /// uses the public initializer above and reads through `RunStore`.
    init(
        paths: AppPaths,
        runStore: RunStore,
        stateStore: StateStore,
        secretBackend: SecretBackend = .configured,
        configuredSetIds: Set<UUID> = [],
        auditHealthLoader: @escaping @Sendable () -> AuditHealthRefreshResult
    ) {
        self.paths = paths
        self.runStore = runStore
        self.auditHealthLoader = auditHealthLoader
        self.stateStore = stateStore
        self.secretBackend = secretBackend
        self.configuredSetIds = configuredSetIds
        self.configFileFingerprint = ConfigStore(paths: paths).fileFingerprint()
    }

    public func updateConfiguredSetIds(_ ids: Set<UUID>) {
        guard configuredSetIds != ids else { return }
        configuredSetIds = ids
        if isRunning { reloadNow() }
    }

    deinit {
        // Best-effort synchronous teardown; `stop()` is the supported path
        // and should always be called explicitly before releasing the last
        // reference, but a bare `deinit` must not leak fds/observers if a
        // caller forgets.
        debounceTask?.cancel()
        explicitAuditRefreshTask?.cancel()
        stateDirSource?.cancel()
        runsDirSource?.cancel()
        locksDirSource?.cancel()
        lockFileSources.values.forEach { $0.cancel() }
        configFileSource?.cancel()
        rootDirSource?.cancel()
        rootParentDirSource?.cancel()
        rootGrandparentDirSource?.cancel()
        if let distributedNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Opens the directory watches, registers the distributed-notification
    /// observer, and performs an initial `reloadNow()`. Cheap `@Published`
    /// state is populated synchronously; the potentially contended full
    /// audit scan is detached from the first SwiftUI render.
    /// Idempotent — a second call while already running is a no-op.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Best-effort: create root/state/runs so there is something to
        // `open(2)` on a first launch before the helper has ever run. If
        // this fails (e.g. permissions), the watchers below simply stay
        // pending and retry is driven by `reloadNow()`'s callers / future
        // notifications; reads remain tolerant either way.
        try? paths.ensureDirectories()

        let rootParent = paths.root.deletingLastPathComponent().standardizedFileURL
        if rootParent.path != paths.root.standardizedFileURL.path {
            let rootGrandparent = rootParent.deletingLastPathComponent().standardizedFileURL
            if rootGrandparent.path != rootParent.path {
                rootGrandparentDirSource = makeSource(
                    watching: rootGrandparent,
                    target: .rootGrandparent
                )
            }
            attemptReopenRootParent()
        }
        attemptReopenRoot()
        attemptPendingReopens()

        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.stateChangedNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // We're already on `.main`, i.e. the main actor's executor —
            // safe to assume isolation rather than hop through `Task`.
            MainActor.assumeIsolated {
                self?.scheduleDebouncedReload()
            }
        }
        distributedNotificationObserver = observer

        reloadNow()
    }

    /// Tears down every watch source and the notification observer. Safe to
    /// call when not running.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        debounceTask?.cancel()
        debounceTask = nil
        explicitAuditRefreshTask?.cancel()
        explicitAuditRefreshTask = nil

        stateDirSource?.cancel()
        stateDirSource = nil
        runsDirSource?.cancel()
        runsDirSource = nil
        locksDirSource?.cancel()
        locksDirSource = nil
        lockFileSources.values.forEach { $0.cancel() }
        lockFileSources.removeAll()
        configFileSource?.cancel()
        configFileSource = nil
        rootDirSource?.cancel()
        rootDirSource = nil
        rootParentDirSource?.cancel()
        rootParentDirSource = nil
        rootGrandparentDirSource?.cancel()
        rootGrandparentDirSource = nil
        pendingReopen.removeAll()

        if let distributedNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
            self.distributedNotificationObserver = nil
        }
    }

    /// Re-reads every published property through `StateStore`/`RunStore`.
    /// Event-backed caches update synchronously; the potentially contended
    /// full audit scan always runs detached and publishes later through its
    /// generation guard. Safe to call at any time, including before start.
    public func reloadNow() {
        reloadCachedStateNow()
        scheduleExplicitAuditRefresh()
    }

    /// Reloads event-backed caches that are cheap to read. Audit history is
    /// deliberately separate because it may contend on a lock and traverse
    /// every run; filesystem-triggered callers perform that scan detached.
    private func reloadCachedStateNow() {
        let observedConfigFingerprint = ConfigStore(paths: paths).fileFingerprint()
        if configFileFingerprint != observedConfigFingerprint {
            configFileFingerprint = observedConfigFingerprint
            configFileRevision &+= 1
        }
        lockingFailure = LockingHealth.probe(
            paths: paths,
            configuredSetIds: configuredSetIds,
            secretBackend: secretBackend
        )
        if isRunning {
            refreshConfigFileSource()
            refreshLockFileSources()
        }
        scheduleState = stateStore.readScheduleState()
        fdaCheck = stateStore.readFdaCheck()

        let discovered = enumerateStateDirectory()
        currentRuns = discovered.currentRuns
        repoStatuses = discovered.repoStatuses

        recentRuns = (try? runStore.recentRuns(limit: 200)) ?? []
    }

    /// Performs the potentially contended full run-history scan away from
    /// the main actor, then publishes only the small result here. A helper
    /// dying releases its flock but creates no filesystem event, so AppModel
    /// also calls this from its existing 30-second health refresh.
    public func refreshAuditHealthOffMain() async {
        auditRefreshGeneration &+= 1
        let generation = auditRefreshGeneration
        await refreshAuditHealthOffMain(generation: generation)
    }

    /// Runs a scan for a generation already reserved synchronously by its
    /// caller. In particular, an explicit reload must invalidate the task it
    /// replaces before the replacement Task gets a chance to execute.
    private func refreshAuditHealthOffMain(generation: UInt64) async {
        let loader = auditHealthLoader
        let result = await Task.detached(priority: .utility) {
            loader()
        }.value

        guard generation == auditRefreshGeneration else { return }

        switch result {
        case .success(let failures):
            auditFailures = failures
            auditVerificationFailed = false
        case .verificationFailed:
            auditFailures = []
            auditVerificationFailed = true
        }
    }

    private func scheduleExplicitAuditRefresh() {
        explicitAuditRefreshTask?.cancel()
        auditRefreshGeneration &+= 1
        let generation = auditRefreshGeneration
        explicitAuditRefreshTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refreshAuditHealthOffMain(generation: generation)
        }
    }

    // MARK: - Debounce

    /// Internal for deterministic ordering tests; production callers are the
    /// filesystem and distributed-notification event handlers above.
    func scheduleDebouncedReload() {
        debounceTask?.cancel()
        // Reserve the replacement observation now, before the debounce
        // sleep. Cancelling a Task does not cancel the detached loader it
        // may already be awaiting, so delaying this increment would let the
        // canceled scan publish stale health during the 250 ms window.
        auditRefreshGeneration &+= 1
        let generation = auditRefreshGeneration
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.reloadCachedStateNow()
            await self.refreshAuditHealthOffMain(generation: generation)
        }
    }

    // MARK: - state/ enumeration

    /// `state/current-run-<uuid>.json` and `state/repo-status-<uuid>.json`
    /// are discovered by filename pattern (the spec: "`current-run-*.json`
    /// files are enumerated by filename pattern to build the dictionary"),
    /// then each is re-read through the typed `StateStore` API — this
    /// method never decodes JSON itself. A directory listing failure (e.g.
    /// `state/` momentarily absent mid delete-recreate) yields empty
    /// dictionaries rather than throwing; the next event repopulates them.
    private func enumerateStateDirectory() -> (currentRuns: [UUID: CurrentRunState], repoStatuses: [UUID: RepoStatus]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.stateDir,
            includingPropertiesForKeys: nil
        ) else {
            return ([:], [:])
        }

        var currentRuns: [UUID: CurrentRunState] = [:]
        var repoStatuses: [UUID: RepoStatus] = [:]

        for entry in entries {
            let filename = entry.lastPathComponent
            if let setId = Self.extractUUID(from: filename, prefix: "current-run-", suffix: ".json") {
                if let state = stateStore.readCurrentRun(setId: setId) {
                    currentRuns[setId] = state
                }
            } else if let destId = Self.extractUUID(from: filename, prefix: "repo-status-", suffix: ".json") {
                if let status = stateStore.readRepoStatus(destId: destId) {
                    repoStatuses[destId] = status
                }
            }
        }

        return (currentRuns, repoStatuses)
    }

    private static func extractUUID(from filename: String, prefix: String, suffix: String) -> UUID? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return nil }
        guard filename.count >= prefix.count + suffix.count else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return UUID(uuidString: String(filename[start..<end]))
    }

    // MARK: - Directory watch sources

    /// Opens the configured directory entry itself for event-only access and
    /// wires up a source for content, permission, deletion, and rename
    /// changes. Directory-only, no-follow flags keep a watcher from silently
    /// binding to a replacement file or symlink target.
    /// `DispatchSourceFileSystemObject`. Returns `nil` if `open(2)` fails
    /// (most commonly: the directory doesn't exist yet) — callers track
    /// that as "pending" and retry later rather than treating it as fatal.
    ///
    private func makeSource(
        watching url: URL,
        target: WatchTarget
    ) -> DispatchSourceFileSystemObject? {
        // A watcher must describe the configured directory entry itself,
        // never a symlink target. Otherwise health can correctly reject a
        // hostile root while this source remains attached to the hostile
        // target and misses the later repair at the configured pathname.
        let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .attrib, .delete, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let needsReopen = source.data.contains(.delete) || source.data.contains(.rename)
            // The event handler is already scheduled on `watchQueue`
            // (`.main`), so this is a synchronous, same-thread hop into
            // actor-isolated state — no `Task` needed.
            MainActor.assumeIsolated {
                var shouldReload = true
                switch target {
                case .directory(let directory):
                    if needsReopen {
                        self.handleDirectoryInvalidated(directory)
                    }
                case .root:
                    if needsReopen {
                        self.handleRootInvalidated()
                    } else {
                        self.attemptPendingReopens()
                    }
                case .rootGrandparent:
                    // The grandparent remains attached when the immediate
                    // parent is replaced, so it drives retries against the
                    // configured parent pathname.
                    if self.rootParentDirSource == nil {
                        self.attemptReopenRootParent()
                        self.attemptReopenRoot()
                        self.attemptPendingReopens()
                    } else {
                        shouldReload = false
                    }
                case .rootParent:
                    // A parent event may be a permission change that affects
                    // lock health, or the recreation of a replaced root. An
                    // ordinary `.write` while the root is still watched is
                    // just sibling churn (especially under /tmp) and must not
                    // turn the watcher into a polling loop.
                    if needsReopen {
                        self.handleRootParentInvalidated()
                    } else if self.rootDirSource == nil {
                        self.attemptReopenRoot()
                    } else {
                        shouldReload = source.data.contains(.attrib)
                            || source.data.contains(.delete)
                            || source.data.contains(.rename)
                    }
                    self.attemptPendingReopens()
                }
                if shouldReload {
                    self.scheduleDebouncedReload()
                }
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    /// The root watcher is attached to an inode, not a pathname. If that
    /// inode is renamed or deleted, every child source remains attached to
    /// the retired tree. Tear the whole hierarchy down and resolve it again
    /// from the root's still-watched parent.
    private func handleRootInvalidated() {
        invalidateRootHierarchy()
        attemptReopenRoot()
        attemptPendingReopens()
    }

    private func handleRootParentInvalidated() {
        rootParentDirSource?.cancel()
        rootParentDirSource = nil
        invalidateRootHierarchy()
        attemptReopenRootParent()
        attemptReopenRoot()
        attemptPendingReopens()
    }

    private func attemptReopenRootParent() {
        guard rootParentDirSource == nil else { return }
        let rootParent = paths.root.deletingLastPathComponent().standardizedFileURL
        guard rootParent.path != paths.root.standardizedFileURL.path else { return }
        rootParentDirSource = makeSource(watching: rootParent, target: .rootParent)
    }

    private func attemptReopenRoot() {
        guard rootDirSource == nil else { return }

        let rootParent = paths.root.deletingLastPathComponent().standardizedFileURL
        if rootParent.path != paths.root.standardizedFileURL.path {
            guard rootParentDirSource != nil else { return }
        }

        // Child paths must never be resolved while the configured root is
        // unavailable (most importantly, while it is a symlink rejected by
        // `O_NOFOLLOW`). Otherwise `root/state`, `root/runs`, and
        // `root/locks` can still follow that intermediate symlink and leave
        // their sources attached to the hostile tree after the root is
        // repaired in place.
        invalidateDescendantSources()
        pendingReopen.formUnion(WatchedDirectory.allCases)

        rootDirSource = makeSource(watching: paths.root, target: .root)
    }

    private func invalidateRootHierarchy() {
        rootDirSource?.cancel()
        rootDirSource = nil
        invalidateDescendantSources()
        pendingReopen.formUnion(WatchedDirectory.allCases)
    }

    private func attemptPendingReopens() {
        guard rootDirSource != nil else { return }
        for pending in Array(pendingReopen) {
            attemptReopen(pending)
        }
    }

    private func invalidateDescendantSources() {
        for directory in WatchedDirectory.allCases {
            invalidateSource(for: directory)
        }
        lockFileSources.values.forEach { $0.cancel() }
        lockFileSources.removeAll()
        configFileSource?.cancel()
        configFileSource = nil
    }

    /// A watched subdirectory (`state/`, `runs/`, or `locks/`) was deleted or
    /// renamed out from under us: the now-stale fd/source is torn down and an immediate
    /// reopen is attempted (covers the common `rm -rf && mkdir` race where
    /// recreation has already happened by the time this handler runs). If
    /// that also fails, the directory is marked pending and will be
    /// retried the next time `rootDirSource` fires (see `makeSource`).
    private func handleDirectoryInvalidated(_ directory: WatchedDirectory) {
        invalidateSource(for: directory)
        // A child descriptor survives its parent being renamed, but then it
        // refers to the retired tree. Drop every direct lock source so the
        // next reload resolves all lock paths through the replacement
        // directories instead of treating stale path keys as still watched.
        lockFileSources.values.forEach { $0.cancel() }
        lockFileSources.removeAll()
        attemptReopen(directory)
    }

    private func invalidateSource(for directory: WatchedDirectory) {
        switch directory {
        case .state:
            stateDirSource?.cancel()
            stateDirSource = nil
        case .runs:
            runsDirSource?.cancel()
            runsDirSource = nil
        case .locks:
            locksDirSource?.cancel()
            locksDirSource = nil
        }
    }

    /// Tries to (re)open the watch source for `directory`. On success,
    /// installs it and clears the pending flag; on failure (directory
    /// still absent), records it in `pendingReopen` so the root watcher's
    /// next event retries. Safe to call redundantly (e.g. once from
    /// `start()` and again from a root-watcher event).
    private func attemptReopen(_ directory: WatchedDirectory) {
        guard rootDirSource != nil else {
            pendingReopen.insert(directory)
            return
        }
        guard let source = makeSource(watching: directory.url(paths: paths), target: .directory(directory)) else {
            pendingReopen.insert(directory)
            return
        }
        pendingReopen.remove(directory)
        switch directory {
        case .state:
            stateDirSource = source
        case .runs:
            runsDirSource = source
        case .locks:
            locksDirSource = source
        }
    }

    /// Reconciles direct vnode watches for every lock path the live health
    /// probe inspects. Absent companion and set locks stay absent: `open`
    /// never creates them, and their parent directory source installs the
    /// child watch after a later creation. Stable health locks are created by
    /// the probe and therefore become watchable during the same reload.
    private func refreshLockFileSources() {
        guard rootDirSource != nil else {
            lockFileSources.values.forEach { $0.cancel() }
            lockFileSources.removeAll()
            return
        }

        var urls: [URL] = []
        if locksDirSource != nil {
            urls += [
                paths.tickLockFile,
                paths.configLockFile,
                paths.destructiveAuditLockFile,
                paths.runPublicationLockFile,
                paths.healthLockFile,
            ]
            urls.append(paths.secretsLockFile)
            urls += configuredSetIds.map { paths.setLockFile(setId: $0) }
        }
        if stateDirSource != nil {
            urls += [
                paths.scheduleStateLockFile,
                paths.stateHealthLockFile,
                paths.previewTokensLockFile,
            ]
        }
        if runsDirSource != nil {
            urls += [
                paths.runsIndexLockFile,
                paths.runsHealthLockFile,
            ]
        }
        let desired = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.standardizedFileURL.path, $0.standardizedFileURL)
        })

        for key in Array(lockFileSources.keys) where desired[key] == nil {
            lockFileSources.removeValue(forKey: key)?.cancel()
        }
        for (key, url) in desired where lockFileSources[key] == nil {
            if let source = makeLockFileSource(watching: url, key: key) {
                lockFileSources[key] = source
            }
        }
    }

    private func refreshConfigFileSource() {
        guard rootDirSource != nil else {
            configFileSource?.cancel()
            configFileSource = nil
            return
        }
        guard configFileSource == nil else { return }

        let fd = open(paths.configFile.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .attrib, .delete, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let invalidated = source.data.contains(.delete) || source.data.contains(.rename)
            MainActor.assumeIsolated {
                if invalidated {
                    self.configFileSource?.cancel()
                    self.configFileSource = nil
                }
                self.scheduleDebouncedReload()
            }
        }
        source.setCancelHandler { close(fd) }
        configFileSource = source
        source.resume()
    }

    private func makeLockFileSource(
        watching url: URL,
        key: String
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.attrib, .delete, .rename],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let invalidated = source.data.contains(.delete) || source.data.contains(.rename)
            MainActor.assumeIsolated {
                if invalidated {
                    self.lockFileSources.removeValue(forKey: key)?.cancel()
                }
                self.scheduleDebouncedReload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}

enum AuditHealthRefreshResult: Sendable {
    case success([RunAuditFailure])
    case verificationFailed
}
