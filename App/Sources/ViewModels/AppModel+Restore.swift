import Combine
import Foundation
import ResticStationCore

// MARK: - RestoreRepository

/// One entry of the Restore screen's grouped destination picker
/// (`docs/ui-spec.md` §Restore: "pick destination (any repo, incl.
/// secondaries — grouped picker 'Set ▸ Destination')").
///
/// A restore is addressed by *both* ids: the helper takes `--set` (which
/// decides the lock and the run record) and `--dest` (which repository to
/// read from), so the picker's element has to carry the set it belongs to.
struct RestoreRepository: Identifiable, Hashable, Sendable {
    let setId: UUID
    let setName: String
    let destination: Destination

    /// Destination ids are unique across the whole config
    /// (`docs/architecture.md` §Identifiers), so they identify a row.
    var id: UUID { destination.id }
    var isPrimary: Bool { destination.isPrimary }

    /// "Projects ▸ Backblaze" — what the closed picker shows.
    var displayName: String { "\(setName) ▸ \(destination.label)" }

    // `Destination` is `Equatable` but not `Hashable`; identity is the
    // destination id either way (`docs/architecture.md` §Identifiers).
    static func == (lhs: RestoreRepository, rhs: RestoreRepository) -> Bool {
        lhs.id == rhs.id && lhs.setId == rhs.setId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - AppModel

extension AppModel {

    /// Every configured repository, primary first within each set. The
    /// Restore screen lists secondaries too: a mirror is a full repository
    /// and is exactly what you browse when the primary is a dead disk.
    var restoreRepositories: [RestoreRepository] {
        config.sets.flatMap { set in
            set.destinations
                .sorted { lhs, rhs in
                    // Stable: primary first, then config order.
                    lhs.isPrimary && !rhs.isPrimary
                }
                .map { RestoreRepository(setId: set.id, setName: set.name, destination: $0) }
        }
    }

    func restoreRepository(id: UUID?) -> RestoreRepository? {
        guard let id else { return nil }
        return restoreRepositories.first { $0.id == id }
    }

    /// Builds the **read-only** runner the Restore screen browses with.
    ///
    /// This is the one sanctioned exception in `docs/architecture.md`
    /// §The single-code-path rule: `snapshots`, `ls` and `find` may run
    /// straight from the app because they take no meaningful lock and
    /// produce no run record. Everything that *writes* — the restore
    /// itself — goes through `HelperInvoker` (`performRestore`), never
    /// through this runner.
    ///
    /// Returns `nil` when no restic binary is configured yet; the caller
    /// renders that as an explained empty state rather than an error.
    func makeBrowsingRunner() -> ResticRunner? {
        guard let path = config.resticPath, !path.isEmpty else { return nil }
        let processRunner = DefaultProcessRunner()
        return ResticRunner(
            resticPath: path,
            paths: paths,
            keychain: KeychainClient(runner: processRunner),
            runner: processRunner
        )
    }

    /// Runs `restic-station-helper restore`. The helper takes the set lock,
    /// writes `state/current-run-<setId>.json` while it works and a run
    /// record when it finishes — so progress reaches the UI through
    /// `StateWatcher`, exactly like a backup does.
    func performRestore(_ args: HelperRestoreArgs) async -> HelperResult {
        let result = await helper.restore(args)
        // The final state write may land while the watcher's debounce is
        // idle (same reasoning as `backUpNow`).
        refresh()
        return result
    }

    /// The most recent `restore` run for `setId` that started at or after
    /// `since` — how the completion summary finds the run log it should
    /// read the restore summary out of.
    func latestRestoreRun(setId: UUID, since: Date) -> RunIndexEntry? {
        stateWatcher.recentRuns.first { entry in
            entry.kind == .restore
                && entry.setId == setId
                && entry.status != .running
                // One second of slack: the helper's clock reading happens a
                // hair before ours, and `index.jsonl` stores millisecond
                // precision.
                && entry.start >= since.addingTimeInterval(-1)
        }
    }
}

// MARK: - RestoreBrowser

/// The Restore screen's model: it owns the read-only `ResticRunner` used for
/// browsing, the snapshot list, the lazily-loaded directory cache and the
/// search results.
///
/// Cache policy (`docs/tasks/T16-restore-ui.md`): directory listings are
/// cached per `(snapshot, path)` for the session. Snapshot ids are content
/// addresses — a mirrored copy of a snapshot has a *different* id — so the
/// cache stays valid across destination switches and is never cleared when
/// the picker changes.
@MainActor
final class RestoreBrowser: ObservableObject {

    /// Cache/loading key: a directory listing is identified by the snapshot
    /// it came from and the **in-snapshot** path that was listed.
    struct DirectoryKey: Hashable, Sendable {
        let snapshotID: String
        let path: String
    }

    enum SearchState: Equatable {
        case idle
        case searching
        case done(pattern: String)
        case failed(String)
    }

    // MARK: Published

    @Published private(set) var snapshots: [Snapshot] = []
    @Published private(set) var isLoadingSnapshots = false
    @Published private(set) var snapshotsError: String?

    /// Immediate children of a listed directory, self-node removed.
    @Published private(set) var children: [DirectoryKey: [LsNode]] = [:]
    @Published private(set) var loadingDirectories: Set<DirectoryKey> = []
    @Published private(set) var directoryErrors: [DirectoryKey: String] = [:]
    /// Every node seen so far, keyed by its own `(snapshot, path)` — lets a
    /// selected path be resolved back to its node (file vs directory)
    /// without walking the cache or rebuilding a path.
    @Published private(set) var nodeIndex: [DirectoryKey: LsNode] = [:]

    @Published private(set) var searchResults: [FindResult] = []
    @Published private(set) var searchState: SearchState = .idle

    // MARK: Collaborators

    private var runner: ResticRunner?
    private var repository: RestoreRepository?
    private var snapshotsTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// `snapshots`/`ls` are cheap metadata reads; a repository that is
    /// simply unreachable should surface as an error in seconds, not hang
    /// the pane. `find` walks every tree it is pointed at, so it gets a much
    /// longer leash.
    private static let queryTimeout: TimeInterval = 60
    private static let findTimeout: TimeInterval = 600

    // MARK: - Configuration

    /// Points the browser at a repository. Re-configuring with the same
    /// repository is a no-op, so it is safe to call from `onChange`.
    func configure(repository: RestoreRepository?, runner: ResticRunner?) {
        guard repository?.id != self.repository?.id else {
            // Same repository, but the restic path (and therefore the
            // runner) may have changed in Settings.
            self.runner = runner
            return
        }
        snapshotsTask?.cancel()
        searchTask?.cancel()
        self.repository = repository
        self.runner = runner
        snapshots = []
        snapshotsError = nil
        isLoadingSnapshots = false
        searchResults = []
        searchState = .idle
        // `children` deliberately survives: it is keyed by snapshot id.
    }

    // MARK: - Snapshots

    /// `restic -r <repo> snapshots --json`, newest first.
    func loadSnapshots(force: Bool = false) {
        guard let repository, let runner else { return }
        if !force, !snapshots.isEmpty || isLoadingSnapshots { return }
        snapshotsTask?.cancel()
        isLoadingSnapshots = true
        snapshotsError = nil

        snapshotsTask = Task { [weak self] in
            do {
                let stdout = try await Self.stdout(
                    of: .snapshots(repo: repository.destination.repoURL),
                    runner: runner,
                    destination: repository.destination,
                    timeout: Self.queryTimeout
                )
                let parsed = try parseSnapshots(Data(stdout.utf8))
                guard !Task.isCancelled else { return }
                self?.snapshots = parsed.sorted { $0.time > $1.time }
                self?.isLoadingSnapshots = false
            } catch is CancellationError {
                self?.isLoadingSnapshots = false
            } catch {
                guard !Task.isCancelled else { return }
                self?.snapshotsError = Self.describe(error)
                self?.isLoadingSnapshots = false
            }
        }
    }

    // MARK: - Directory browsing

    func children(snapshotID: String, path: String) -> [LsNode]? {
        children[DirectoryKey(snapshotID: snapshotID, path: path)]
    }

    func isLoading(snapshotID: String, path: String) -> Bool {
        loadingDirectories.contains(DirectoryKey(snapshotID: snapshotID, path: path))
    }

    func error(snapshotID: String, path: String) -> String? {
        directoryErrors[DirectoryKey(snapshotID: snapshotID, path: path)]
    }

    /// The node restic returned for this exact in-snapshot path, if it has
    /// been listed during this session.
    func node(snapshotID: String, path: String) -> LsNode? {
        nodeIndex[DirectoryKey(snapshotID: snapshotID, path: path)]
    }

    /// `restic -r <repo> ls --json <snapshot> <path>` for one directory.
    ///
    /// `path` **must** come from a node restic returned (or be the root
    /// `/`): in-snapshot paths are restic's own, and reconstructing them
    /// from names is the documented way to get "path not found"
    /// (`docs/restic-cli.md` §ls).
    ///
    /// A listing that matches nothing returns only the snapshot header —
    /// that is an *empty directory*, not an error (same section).
    func loadChildren(snapshotID: String, path: String, force: Bool = false) {
        guard let repository, let runner else { return }
        let key = DirectoryKey(snapshotID: snapshotID, path: path)
        if loadingDirectories.contains(key) { return }
        if !force, children[key] != nil { return }

        loadingDirectories.insert(key)
        directoryErrors[key] = nil

        Task { [weak self] in
            do {
                let messages = try await Self.messages(
                    of: .ls(repo: repository.destination.repoURL, snapshotID: snapshotID, path: path),
                    runner: runner,
                    destination: repository.destination,
                    timeout: Self.queryTimeout
                )
                let nodes = messages
                    .compactMap { message -> LsNode? in
                        guard case .node(let node) = message else { return nil }
                        return node
                    }
                    // `ls <dir>` returns the directory's own node plus its
                    // immediate children; only the children belong in the tree.
                    .filter { $0.path != path }
                    .sorted(by: Self.displayOrder)
                self?.children[key] = nodes
                for node in nodes {
                    self?.nodeIndex[DirectoryKey(snapshotID: snapshotID, path: node.path)] = node
                }
                self?.loadingDirectories.remove(key)
            } catch is CancellationError {
                self?.loadingDirectories.remove(key)
            } catch {
                self?.directoryErrors[key] = Self.describe(error)
                self?.loadingDirectories.remove(key)
            }
        }
    }

    /// Directories first, then case-insensitive by name — Finder's order.
    private static func displayOrder(_ lhs: LsNode, _ rhs: LsNode) -> Bool {
        let lhsIsDir = lhs.type == .dir
        let rhsIsDir = rhs.type == .dir
        if lhsIsDir != rhsIsDir { return lhsIsDir }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Search

    /// `restic -r <repo> find --json [--snapshot <id>] <pattern>`.
    ///
    /// Restricted to one snapshot by default because an unrestricted `find`
    /// walks *every* snapshot in the repository (`docs/restic-cli.md` §find).
    func search(pattern: String, snapshotID: String?, allSnapshots: Bool) {
        guard let repository, let runner else { return }
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            searchResults = []
            searchState = .idle
            return
        }
        searchState = .searching

        let restrictTo = allSnapshots ? nil : snapshotID
        searchTask = Task { [weak self] in
            do {
                let stdout = try await Self.stdout(
                    of: .find(repo: repository.destination.repoURL, pattern: trimmed, snapshotID: restrictTo),
                    runner: runner,
                    destination: repository.destination,
                    timeout: Self.findTimeout
                )
                let results = try parseFind(Data(stdout.utf8))
                guard !Task.isCancelled else { return }
                self?.searchResults = results
                self?.searchState = .done(pattern: trimmed)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchResults = []
                self?.searchState = .failed(Self.describe(error))
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchResults = []
        searchState = .idle
    }

    // MARK: - Running restic (read-only)

    /// Runs one read-only command and returns its decoded stdout messages.
    private static func messages(
        of command: ResticCommand,
        runner: ResticRunner,
        destination: Destination,
        timeout: TimeInterval
    ) async throws -> [ResticMessage] {
        let outcome = try await runner.run(
            command,
            for: ResticInvocation(destination: destination),
            timeout: timeout
        )
        guard outcome.status.isSuccess else {
            throw BrowseFailure.restic(outcome.status.userFacingMessage)
        }
        return outcome.messages
    }

    /// Runs one read-only command and returns **stdout only**, for the two
    /// commands whose output is a single JSON array rather than NDJSON
    /// (`snapshots`, `find`). `ResticOutcome.rawOutput` concatenates stdout
    /// and stderr, which would not parse as JSON if restic warned about
    /// anything; every stdout line of a non-NDJSON command decodes to
    /// `.unparsed`, so reassembling those gives clean stdout.
    private static func stdout(
        of command: ResticCommand,
        runner: ResticRunner,
        destination: Destination,
        timeout: TimeInterval
    ) async throws -> String {
        let collector = LineCollector()
        let outcome = try await runner.run(
            command,
            for: ResticInvocation(destination: destination),
            onLine: { message in
                if case .unparsed(let line) = message {
                    collector.append(line)
                }
            },
            timeout: timeout
        )
        guard outcome.status.isSuccess else {
            throw BrowseFailure.restic(outcome.status.userFacingMessage)
        }
        return collector.joined()
    }

    /// "What failed, the mapped reason, one next step"
    /// (`docs/ui-spec.md` §Copy/tone rules) — the mapped reason comes from
    /// `ResticError`'s own user-facing text wherever restic produced one.
    private static func describe(_ error: Error) -> String {
        switch error {
        case let failure as BrowseFailure:
            return failure.message
        case let failure as ResticRunnerError:
            return failure.userFacingMessage
        case is DecodingError:
            return "restic returned output Restic Station could not read. "
                + "Check that the restic binary in Settings is version 0.17 or newer."
        default:
            return "\(error)"
        }
    }
}

// MARK: - BrowseFailure

/// A read-only browse query that ran but failed. The message is already
/// user-facing (it comes from `ResticExitClass.userFacingMessage`).
enum BrowseFailure: Error {
    case restic(String)

    var message: String {
        switch self {
        case .restic(let message): return message
        }
    }
}

// MARK: - LineCollector

/// Accumulates stdout lines delivered on `ResticRunner`'s reader queue.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
