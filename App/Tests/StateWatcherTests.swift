import Foundation
import Combine
import ResticStationCore
import Testing
@testable import Restic_Station

private final class ScriptedAuditLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let firstStarted = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let newerResult: AuditHealthRefreshResult

    init(newerResult: AuditHealthRefreshResult) {
        self.newerResult = newerResult
    }

    func load() -> AuditHealthRefreshResult {
        lock.lock()
        callCount += 1
        let call = callCount
        lock.unlock()
        if call == 1 {
            firstStarted.signal()
            releaseFirst.wait()
            return .success([])
        }
        return newerResult
    }

    func waitUntilFirstStarted() {
        firstStarted.wait()
    }

    func finishFirst() {
        releaseFirst.signal()
    }
}

private final class AuditLoaderThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadObservations: [Bool] = []

    func load() -> AuditHealthRefreshResult {
        lock.lock()
        mainThreadObservations.append(Thread.isMainThread)
        lock.unlock()
        return .success([])
    }

    func reset() {
        lock.lock()
        mainThreadObservations = []
        lock.unlock()
    }

    var observations: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadObservations
    }
}

private final class ReplacementAuditLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let secondStarted = DispatchSemaphore(value: 0)
    private let releaseSecond = DispatchSemaphore(value: 0)
    private let thirdStarted = DispatchSemaphore(value: 0)
    private let releaseThird = DispatchSemaphore(value: 0)
    private let currentResult: AuditHealthRefreshResult

    init(currentResult: AuditHealthRefreshResult) {
        self.currentResult = currentResult
    }

    func load() -> AuditHealthRefreshResult {
        lock.lock()
        callCount += 1
        let call = callCount
        lock.unlock()
        switch call {
        case 1:
            return currentResult
        case 2:
            secondStarted.signal()
            releaseSecond.wait()
            return .success([])
        default:
            thirdStarted.signal()
            releaseThird.wait()
            return currentResult
        }
    }

    func waitUntilSecondStarted() { secondStarted.wait() }
    func finishSecond() { releaseSecond.signal() }
    func waitUntilThirdStarted() { thirdStarted.wait() }
    func finishThird() { releaseThird.signal() }
}

@Suite("StateWatcher lock health", .serialized)
@MainActor
struct StateWatcherTests {
    @Test("replacing the data-root parent rebinds the entire watch hierarchy")
    func rootParentReplacementRebindsHierarchy() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-root-parent-replacement-\(UUID().uuidString)", isDirectory: true)
        let parent = container.appendingPathComponent("parent", isDirectory: true)
        let retiredParent = container.appendingPathComponent("parent-retired", isDirectory: true)
        let root = parent.appendingPathComponent("data", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let initialTick = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(initialTick.acquire() == .acquired)
        initialTick.release()

        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure == nil)

        try FileManager.default.moveItem(at: parent, to: retiredParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try paths.ensureDirectories()
        let replacementTick = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(replacementTick.acquire() == .acquired)
        replacementTick.release()
        try await Task.sleep(nanoseconds: 750_000_000)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path)
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)
    }

    @Test("repairing a symlinked locks directory rebinds direct lock watches")
    func symlinkedLocksRepairRebindsDirectWatches() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-locks-symlink-watcher-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("data", isDirectory: true)
        let hostileLocks = parent.appendingPathComponent("hostile-locks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.removeItem(at: paths.locksDir)
        try FileManager.default.createDirectory(at: hostileLocks, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hostileLocks.path)
        let hostileTick = hostileLocks.appendingPathComponent("tick.lock", isDirectory: false)
        try Data().write(to: hostileTick)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostileTick.path)
        try FileManager.default.createSymbolicLink(at: paths.locksDir, withDestinationURL: hostileLocks)

        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure != nil)

        try FileManager.default.removeItem(at: paths.locksDir)
        try FileManager.default.createDirectory(
            at: paths.locksDir,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        let replacementTick = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(replacementTick.acquire() == .acquired)
        replacementTick.release()
        try await Task.sleep(nanoseconds: 500_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path)
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)
    }

    @Test("repairing a symlinked data root rebinds health and child watches")
    func symlinkedRootRepairRebindsWatches() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-root-symlink-watcher-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("data", isDirectory: true)
        let hostileTarget = parent.appendingPathComponent("hostile-target", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try AppPaths(root: hostileTarget).ensureDirectories()
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: hostileTarget)

        let paths = AppPaths(root: root)
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure != nil)

        try FileManager.default.removeItem(at: root)
        try paths.ensureDirectories()
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        let tickLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(tickLock.acquire() == .acquired)
        tickLock.release()
        try await Task.sleep(nanoseconds: 500_000_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path)
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)
    }

    @Test("data-root parent permission changes refresh lock health")
    func rootParentMetadataRefreshesHealth() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-root-parent-watcher-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("data", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: parent.path)
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == parent.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == parent.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)
    }

    @Test("replacing the data root rebinds every child watch")
    func rootReplacementRebindsChildWatches() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-root-replacement-watcher-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("data", isDirectory: true)
        let retiredRoot = parent.appendingPathComponent("data-retired", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let initialLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(initialLock.acquire() == .acquired)
        initialLock.release()

        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }

        try FileManager.default.moveItem(at: root, to: retiredRoot)
        try paths.ensureDirectories()
        let replacementLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(replacementLock.acquire() == .acquired)
        replacementLock.release()
        try await Task.sleep(nanoseconds: 750_000_000)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path)
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)
    }

    @Test("lock permission changes and directory renames refresh lock health")
    func lockMetadataAndRenameRefreshHealth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lock-watcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        let tickLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(tickLock.acquire() == .acquired)
        tickLock.release()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.lockingFailure == nil)

        // Child metadata does not mutate the parent directory vnode. The
        // direct lock-file source must still refresh live health.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        // A metadata-only permission change must make the app unhealthy even
        // though no file in state/ or runs/ changed.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o770], ofItemAtPath: paths.locksDir.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure?.scope == .machine { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.scope == .machine)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: paths.locksDir.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        // Exercise the rename/reopen path, not just a write delivered by the
        // source installed during start().
        let movedLocks = root.appendingPathComponent("locks-old", isDirectory: true)
        try FileManager.default.moveItem(at: paths.locksDir, to: movedLocks)
        try FileManager.default.createDirectory(
            at: paths.locksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementTickLock = FileLock(path: paths.tickLockFile, trustedRoot: root)
        #expect(replacementTickLock.acquire() == .acquired)
        replacementTickLock.release()
        // Let the replacement directory event reconcile direct sources. The
        // pathname is unchanged, so a source retained from the old tree
        // would otherwise make this metadata event invisible.
        try await Task.sleep(nanoseconds: 750_000_000)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure?.path == paths.tickLockFile.path { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.path == paths.tickLockFile.path)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.tickLockFile.path
        )
        for _ in 0..<40 {
            if watcher.lockingFailure == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure == nil)

        let setId = UUID()
        watcher.updateConfiguredSetIds([setId])
        try FileManager.default.createDirectory(
            at: paths.setLockFile(setId: setId),
            withIntermediateDirectories: true
        )

        for _ in 0..<40 {
            if watcher.lockingFailure?.scope == .set(setId) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.lockingFailure?.scope == .set(setId))
        #expect(watcher.lockingFailure?.path.contains(setId.uuidString) == true)
    }

    @Test("a settled lock-health reload does not trigger another reload")
    func lockHealthDoesNotTriggerItself() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-lock-watcher-idle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        var changes = 0
        let subscription = watcher.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 750_000_000)
        changes = 0
        try await Task.sleep(nanoseconds: 750_000_000)

        #expect(changes == 0)
    }

    @Test("the liveness refresh notices a destructive helper dying without a file event")
    func auditRefreshNoticesReleasedDestructiveGate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let runStore = RunStore(paths: paths)
        let run = try runStore.begin(kind: .prune, setId: UUID(), destId: UUID(), trigger: .manual)
        try runStore.markDestructiveLaunchAuthorized(run)
        let gate = FileLock(path: paths.destructiveAuditLockFile, trustedRoot: paths.root)
        #expect(gate.acquire() == .acquired)

        let watcher = StateWatcher(
            paths: paths,
            runStore: runStore,
            stateStore: StateStore(paths: paths)
        )
        watcher.reloadNow()
        await watcher.refreshAuditHealthOffMain()
        #expect(watcher.auditFailures.isEmpty)
        #expect(!watcher.auditVerificationFailed)

        // flock release has no vnode write for DispatchSource to observe.
        gate.release()
        await watcher.refreshAuditHealthOffMain()

        #expect(watcher.auditFailures.first?.runId == run.runId)
        #expect(watcher.auditFailures.first?.reason == .launchedWithoutTerminalMetadata)
        #expect(!watcher.auditVerificationFailed)
    }

    @Test("an older detached audit scan cannot replace a newer refresh")
    func staleDetachedAuditRefreshIsDiscarded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let failure = RunAuditFailure(
            runId: "newer-audit-state",
            kind: .prune,
            setId: UUID(),
            destId: UUID(),
            start: Date(),
            reason: .launchedWithoutTerminalMetadata
        )
        let loader = ScriptedAuditLoader(newerResult: .success([failure]))
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths),
            auditHealthLoader: { loader.load() }
        )

        let staleRefresh = Task { await watcher.refreshAuditHealthOffMain() }
        await Task.detached { loader.waitUntilFirstStarted() }.value
        await watcher.refreshAuditHealthOffMain()
        #expect(watcher.auditFailures == [failure])

        loader.finishFirst()
        await staleRefresh.value
        #expect(watcher.auditFailures == [failure])
        #expect(!watcher.auditVerificationFailed)
    }

    @Test("replacing an explicit audit scan invalidates it before the replacement starts")
    func explicitAuditReplacementInvalidatesSynchronously() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let failure = RunAuditFailure(
            runId: "current-audit-failure",
            kind: .purge,
            setId: UUID(),
            destId: UUID(),
            start: Date(),
            reason: .launchedWithoutTerminalMetadata
        )
        let loader = ReplacementAuditLoader(currentResult: .success([failure]))
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths),
            auditHealthLoader: { loader.load() }
        )

        await watcher.refreshAuditHealthOffMain()
        #expect(watcher.auditFailures == [failure])

        watcher.reloadNow()
        await Task.detached { loader.waitUntilSecondStarted() }.value
        watcher.reloadNow()
        loader.finishSecond()
        await Task.detached { loader.waitUntilThirdStarted() }.value

        // The replacement is deliberately still blocked. The canceled scan
        // has finished, but it must already be unable to publish its stale
        // healthy result.
        #expect(watcher.auditFailures == [failure])
        loader.finishThird()
    }

    @Test("a debounced replacement invalidates its prior scan before sleeping")
    func debouncedAuditReplacementInvalidatesSynchronously() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-debounce-generation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let failure = RunAuditFailure(
            runId: "current-debounced-audit-failure",
            kind: .prune,
            setId: UUID(),
            destId: UUID(),
            start: Date(),
            reason: .launchedWithoutTerminalMetadata
        )
        let loader = ReplacementAuditLoader(currentResult: .success([failure]))
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths),
            auditHealthLoader: { loader.load() }
        )

        await watcher.refreshAuditHealthOffMain()
        #expect(watcher.auditFailures == [failure])
        let staleRefresh = Task { await watcher.refreshAuditHealthOffMain() }
        await Task.detached { loader.waitUntilSecondStarted() }.value

        // This synchronous call represents a filesystem event. The
        // replacement is still in its 250 ms sleep when the old detached
        // loader finishes.
        watcher.scheduleDebouncedReload()
        loader.finishSecond()
        await staleRefresh.value
        #expect(watcher.auditFailures == [failure])

        await Task.detached { loader.waitUntilThirdStarted() }.value
        loader.finishThird()
    }

    @Test("explicit reload audit scans never run on the main thread")
    func explicitAuditRefreshRunsOffMain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-explicit-thread-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let recorder = AuditLoaderThreadRecorder()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths),
            auditHealthLoader: { recorder.load() }
        )

        watcher.reloadNow()
        for _ in 0..<40 {
            if !recorder.observations.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(!recorder.observations.isEmpty)
        #expect(recorder.observations.allSatisfy { !$0 })
    }

    @Test("filesystem-triggered audit scans never run on the main thread")
    func filesystemAuditRefreshRunsOffMain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-audit-event-thread-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        let stateStore = StateStore(paths: paths)
        let recorder = AuditLoaderThreadRecorder()
        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: stateStore,
            auditHealthLoader: { recorder.load() }
        )
        watcher.start()
        defer { watcher.stop() }
        recorder.reset()

        try stateStore.writeFdaCheck(FdaCheckResult(
            checkedAt: Date(),
            hasFullDiskAccess: true,
            probedPath: "/tmp",
            context: "test"
        ))
        for _ in 0..<40 {
            if !recorder.observations.isEmpty { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(!recorder.observations.isEmpty)
        #expect(recorder.observations.allSatisfy { !$0 })
    }

    @Test("atomic config replacement publishes the new file fingerprint")
    func configReplacementPublishesFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-config-watcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = AppPaths(root: root)
        let store = ConfigStore(paths: paths)
        try store.save(AppConfig(showMenuBarIcon: true))

        let watcher = StateWatcher(
            paths: paths,
            runStore: RunStore(paths: paths),
            stateStore: StateStore(paths: paths)
        )
        watcher.start()
        defer { watcher.stop() }
        let original = watcher.configFileFingerprint

        try store.save(AppConfig(showMenuBarIcon: false))
        let replacement = store.fileFingerprint()
        #expect(replacement != original)

        for _ in 0..<40 {
            if watcher.configFileFingerprint == replacement { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(watcher.configFileFingerprint == replacement)
    }
}
