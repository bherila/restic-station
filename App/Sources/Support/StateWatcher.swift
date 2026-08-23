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
/// All actual reads go through `StateStore`/`RunStore`, which are tolerant
/// of missing/partial/corrupt files by construction (state is a regenerable
/// cache, never a source of truth the reader must trust blindly — see
/// `docs/data-model.md` §Versioning). `StateWatcher` itself never parses
/// file contents; it only reacts to *that something changed* and re-reads
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
    /// Live lock-health result, refreshed for state/run writes and every
    /// change under `locks/`. A lock failure can prevent all other writes,
    /// so the lock directory needs its own event source.
    @Published public private(set) var lockingFailure: LockingHealthFailure?

    private let paths: AppPaths
    private let runStore: RunStore
    private let stateStore: StateStore
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
    /// Watches `paths.root` purely so that a delete+recreate of `state/`,
    /// `runs/`, or `locks/` (which this watcher cannot keep an open fd across)
    /// has a
    /// second, still-open fd from which to notice the recreation and retry
    /// reopening — see `attemptReopen(_:)`. This is what lets the watcher
    /// survive the directory being deleted and recreated without polling.
    private var rootDirSource: DispatchSourceFileSystemObject?

    /// Directories whose watch source is currently unavailable because the
    /// directory didn't exist at the last open attempt (typically: deleted
    /// and not yet recreated). Retried opportunistically whenever
    /// `rootDirSource` fires, and once more on `start()`.
    private var pendingReopen: Set<WatchedDirectory> = []

    private var distributedNotificationObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false

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
        configuredSetIds: Set<UUID> = []
    ) {
        self.paths = paths
        self.runStore = runStore
        self.stateStore = stateStore
        self.configuredSetIds = configuredSetIds
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
        stateDirSource?.cancel()
        runsDirSource?.cancel()
        locksDirSource?.cancel()
        lockFileSources.values.forEach { $0.cancel() }
        rootDirSource?.cancel()
        if let distributedNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
        }
    }

    // MARK: - Lifecycle

    /// Opens the directory watches, registers the distributed-notification
    /// observer, and performs an initial synchronous `reloadNow()` so
    /// `@Published` state is populated before the first SwiftUI render.
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

        rootDirSource = makeSource(watching: paths.root, reportDeleteAsDirectory: nil)
        for directory in WatchedDirectory.allCases {
            attemptReopen(directory)
        }

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

        stateDirSource?.cancel()
        stateDirSource = nil
        runsDirSource?.cancel()
        runsDirSource = nil
        locksDirSource?.cancel()
        locksDirSource = nil
        lockFileSources.values.forEach { $0.cancel() }
        lockFileSources.removeAll()
        rootDirSource?.cancel()
        rootDirSource = nil
        pendingReopen.removeAll()

        if let distributedNotificationObserver {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
            self.distributedNotificationObserver = nil
        }
    }

    /// Synchronously re-reads every published property through
    /// `StateStore`/`RunStore`. Safe to call at any time (including before
    /// `start()`, e.g. to pre-populate a preview) — every read tolerates a
    /// missing file or directory.
    public func reloadNow() {
        lockingFailure = LockingHealth.probe(paths: paths, configuredSetIds: configuredSetIds)
        if isRunning { refreshLockFileSources() }
        scheduleState = stateStore.readScheduleState()
        fdaCheck = stateStore.readFdaCheck()

        let discovered = enumerateStateDirectory()
        currentRuns = discovered.currentRuns
        repoStatuses = discovered.repoStatuses

        recentRuns = (try? runStore.recentRuns(limit: 200)) ?? []
    }

    // MARK: - Debounce

    private func scheduleDebouncedReload() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.reloadNow()
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

    /// Opens `url` `O_EVTONLY` and wires up a source for content,
    /// permission, deletion, and rename changes.
    /// `DispatchSourceFileSystemObject`. Returns `nil` if `open(2)` fails
    /// (most commonly: the directory doesn't exist yet) — callers track
    /// that as "pending" and retry later rather than treating it as fatal.
    ///
    /// - Parameter reportDeleteAsDirectory: when non-nil, a `.delete` or
    ///   `.rename` event is treated as "this watched *sub*directory is no
    ///   longer reachable at its configured path" and
    ///   routed to `handleDirectoryInvalidated(_:)` for that
    ///   `WatchedDirectory`. `nil` for the root watcher, which exists only
    ///   to notice churn in `paths.root`'s children and drive reopen
    ///   retries — root itself is not expected to disappear.
    private func makeSource(
        watching url: URL,
        reportDeleteAsDirectory directory: WatchedDirectory?
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
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
                if let directory, needsReopen {
                    self.handleDirectoryInvalidated(directory)
                } else if directory == nil {
                    // Root watcher: opportunistically retry any directory
                    // that's been waiting to be reopened since a prior
                    // delete, then treat this like any other nudge.
                    for pending in self.pendingReopen {
                        self.attemptReopen(pending)
                    }
                }
                self.scheduleDebouncedReload()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    /// A watched subdirectory (`state/`, `runs/`, or `locks/`) was deleted or
    /// renamed out from under us: the now-stale fd/source is torn down and an immediate
    /// reopen is attempted (covers the common `rm -rf && mkdir` race where
    /// recreation has already happened by the time this handler runs). If
    /// that also fails, the directory is marked pending and will be
    /// retried the next time `rootDirSource` fires (see `makeSource`).
    private func handleDirectoryInvalidated(_ directory: WatchedDirectory) {
        invalidateSource(for: directory)
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
        guard let source = makeSource(watching: directory.url(paths: paths), reportDeleteAsDirectory: directory) else {
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
        let urls = [
            paths.tickLockFile,
            paths.healthLockFile,
            paths.secretsLockFile,
            paths.scheduleStateLockFile,
            paths.stateHealthLockFile,
            paths.previewTokensLockFile,
            paths.runsIndexLockFile,
            paths.runsHealthLockFile,
        ] + configuredSetIds.map { paths.setLockFile(setId: $0) }
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
