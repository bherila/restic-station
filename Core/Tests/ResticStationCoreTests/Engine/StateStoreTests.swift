import Foundation
import Testing
@testable import ResticStationCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private final class StateStoreErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ error: Error) {
        lock.lock()
        messages.append(String(describing: error))
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private final class ScheduleStateFaultInjector: @unchecked Sendable {
    enum Point {
        case firstSync
        case secondSync
        case rename
    }

    private let point: Point
    private let lock = NSLock()
    private var syncCount = 0

    init(_ point: Point) {
        self.point = point
    }

    func operations() -> StateStoreFileOperations {
        let live = StateStoreFileOperations.live
        return StateStoreFileOperations(
            openAt: live.openAt,
            read: live.read,
            write: live.write,
            sync: { [self] fd in
                lock.lock()
                syncCount += 1
                let call = syncCount
                lock.unlock()
                if (point == .firstSync && call == 1) || (point == .secondSync && call == 2) {
                    errno = EIO
                    return -1
                }
                return live.sync(fd)
            },
            stat: live.stat,
            setMode: live.setMode,
            renameAt: { [self] oldDirectory, oldName, newDirectory, newName in
                if point == .rename {
                    errno = EIO
                    return -1
                }
                return live.renameAt(oldDirectory, oldName, newDirectory, newName)
            },
            unlinkAt: live.unlinkAt,
            close: live.close
        )
    }
}

private final class ScheduleStateMigrationPause: @unchecked Sendable {
    private let live = StateStoreFileOperations.live
    private let markerPublished = DispatchSemaphore(value: 0)
    private let resumeWriter = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didPause = false

    func operations() -> StateStoreFileOperations {
        StateStoreFileOperations(
            openAt: live.openAt,
            read: live.read,
            write: live.write,
            sync: live.sync,
            stat: live.stat,
            setMode: live.setMode,
            renameAt: { [self] oldDirectory, oldName, newDirectory, newName in
                let result = live.renameAt(oldDirectory, oldName, newDirectory, newName)
                guard result == 0, newName == "schedule-state.version-1" else { return result }
                lock.lock()
                let shouldPause = !didPause
                didPause = true
                lock.unlock()
                if shouldPause {
                    markerPublished.signal()
                    resumeWriter.wait()
                }
                return result
            },
            unlinkAt: live.unlinkAt,
            close: live.close
        )
    }

    func waitUntilMarkerPublished() { markerPublished.wait() }
    func resume() { resumeWriter.signal() }
}

private final class ScheduleStateReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScheduleStateReadResult?

    func record(_ result: ScheduleStateReadResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: ScheduleStateReadResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class RecoveryWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func operations() -> StateStoreFileOperations {
        let live = StateStoreFileOperations.live
        return StateStoreFileOperations(
            openAt: live.openAt,
            read: live.read,
            write: { [self] _, _, _ in
                lock.lock()
                count += 1
                lock.unlock()
                errno = ENOSPC
                return -1
            },
            sync: live.sync,
            stat: live.stat,
            setMode: live.setMode,
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt,
            close: live.close
        )
    }

    var writes: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite("StateStore: typed read/write for the four state/ files")
struct StateStoreTests {
    private func makeStore() -> (store: StateStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-statestore-test-\(UUID().uuidString)")
        return (StateStore(paths: AppPaths(root: root)), root)
    }

    // MARK: - Decoding the documented literal examples (docs/data-model.md)

    // The doc's `"sets"`/`"destId"` examples abbreviate UUIDs with "..." for
    // readability; these tests use the full UUID from the same running
    // example in §config.json (the "Projects" set) so the literal is valid
    // JSON while matching the documented shape/field names/value types
    // exactly.
    private static let exampleSetId = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private static let exampleDestId = UUID(uuidString: "1B2C3D4E-8B86-D011-B42D-00C04FC964FF")!

    @Test("decodes the documented state/schedule-state.json literal")
    func decodesScheduleStateExample() throws {
        let json = """
        {
          "sets": {
            "\(Self.exampleSetId.uuidString)": {
              "lastBackupStart": "2026-07-26T20:57:04Z",
              "lastCheckStart": "2026-07-20T03:00:00Z",
              "checkSliceCursor": 7
            }
          }
        }
        """
        let decoded = try StateStore.makeDecoder().decode(ScheduleState.self, from: Data(json.utf8))
        let entry = try #require(decoded.sets[Self.exampleSetId])
        #expect(entry.checkSliceCursor == 7)
        #expect(entry.lastBackupStart == Self.date("2026-07-26T20:57:04Z"))
        #expect(entry.lastCheckStart == Self.date("2026-07-20T03:00:00Z"))

        // Round-trips through this store's own encoder/decoder.
        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(ScheduleState.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("decodes the documented state/repo-status-<destId>.json literal")
    func decodesRepoStatusExample() throws {
        let json = """
        {
          "destId": "\(Self.exampleDestId.uuidString)",
          "reachable": false,
          "probedAt": "2026-07-26T20:57:10Z",
          "lastSyncedAt": "2026-07-12T02:31:00Z",
          "lastError": null
        }
        """
        let decoded = try StateStore.makeDecoder().decode(RepoStatus.self, from: Data(json.utf8))
        #expect(decoded.destId == Self.exampleDestId)
        #expect(decoded.reachable == false)
        #expect(decoded.probedAt == Self.date("2026-07-26T20:57:10Z"))
        #expect(decoded.lastSyncedAt == Self.date("2026-07-12T02:31:00Z"))
        #expect(decoded.lastError == nil)

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(RepoStatus.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("decodes the documented state/current-run-<setId>.json literal")
    func decodesCurrentRunExample() throws {
        let json = """
        {
          "runId": "20260726T205704Z-backup-6f9619ff",
          "kind": "backup",
          "phase": "backing-up-primary",
          "percentDone": 0.42,
          "bytesDone": 1234567,
          "totalBytes": 987654321,
          "filesDone": 120,
          "totalFiles": 4000,
          "currentFiles": ["/Users/user/proj/big.dat"],
          "heartbeatAt": "2026-07-26T20:57:31Z",
          "heartbeatUptime": 12345.5,
          "updatedAt": "2026-07-26T20:57:30Z"
        }
        """
        let decoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: Data(json.utf8))
        #expect(decoded.runId == "20260726T205704Z-backup-6f9619ff")
        #expect(decoded.kind == .backup)
        #expect(decoded.phase == "backing-up-primary")
        #expect(decoded.percentDone == 0.42)
        #expect(decoded.bytesDone == 1_234_567)
        #expect(decoded.totalBytes == 987_654_321)
        #expect(decoded.filesDone == 120)
        #expect(decoded.totalFiles == 4000)
        #expect(decoded.currentFiles == ["/Users/user/proj/big.dat"])
        #expect(decoded.heartbeatAt == Self.date("2026-07-26T20:57:31Z"))
        #expect(decoded.heartbeatUptime == 12_345.5)
        #expect(decoded.updatedAt == Self.date("2026-07-26T20:57:30Z"))

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("current-run files from before heartbeats remain decodable")
    func decodesLegacyCurrentRunWithoutHeartbeat() throws {
        let json = """
        {
          "runId": "legacy",
          "kind": "check",
          "phase": "checking",
          "percentDone": 0,
          "bytesDone": 0,
          "totalBytes": 0,
          "filesDone": 0,
          "totalFiles": 0,
          "currentFiles": [],
          "updatedAt": "2026-07-26T20:57:30Z"
        }
        """
        let decoded = try StateStore.makeDecoder().decode(CurrentRunState.self, from: Data(json.utf8))
        #expect(decoded.heartbeatAt == nil)
        #expect(decoded.heartbeatUptime == nil)
    }

    @Test("decodes the documented state/fda-check.json literal")
    func decodesFdaCheckExample() throws {
        let json = """
        { "checkedAt": "2026-07-26T20:57:00Z", "hasFullDiskAccess": true, "probedPath": "~/Library/Safari", "context": "launchd" }
        """
        let decoded = try StateStore.makeDecoder().decode(FdaCheckResult.self, from: Data(json.utf8))
        #expect(decoded.checkedAt == Self.date("2026-07-26T20:57:00Z"))
        #expect(decoded.hasFullDiskAccess == true)
        #expect(decoded.probedPath == "~/Library/Safari")
        #expect(decoded.context == "launchd")

        let reEncoded = try StateStore.makeEncoder().encode(decoded)
        let reDecoded = try StateStore.makeDecoder().decode(FdaCheckResult.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    // MARK: - Missing / corrupt files never throw

    /// #110: the 5-second poll is for *contention*. Spending it on a lock
    /// that cannot be opened, and then reporting a timeout, names a peer
    /// process as the cause of a permissions fault and sends whoever reads
    /// it hunting for a helper that was never running.
    ///
    /// The fault is injected at the lock *path* rather than by chmod-ing
    /// `state/`: `ensureDirectories()` deliberately re-asserts `0700` on
    /// that directory on every call, so a mode injected there is undone
    /// before the lock is ever opened.
    @Test("an unusable schedule-state lock throws immediately, not after the timeout")
    func unusableStateLockFailsFast() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-statelock-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        // A directory where the lock file belongs: unopenable as a regular
        // file, and nothing a caller can wait out.
        try FileManager.default.createDirectory(
            at: paths.scheduleStateLockFile,
            withIntermediateDirectories: true
        )

        let store = StateStore(paths: paths)
        let started = Date()
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: UUID()) { $0.lastBackupStart = Date() }
        }
        // The timeout is 5s; a fail-fast refusal is orders of magnitude
        // quicker. Generous bound so a loaded CI runner cannot flake it.
        #expect(Date().timeIntervalSince(started) < 2.0, "a broken lock must not be waited out")
    }

    @Test("a missing schedule state is classified separately from other absent state")
    func missingFilesReturnNil() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(store.readScheduleState() == nil)
        #expect(store.readScheduleStateResult() == .missing)
        #expect(store.readRepoStatus(destId: UUID()) == nil)
        #expect(store.readCurrentRun(setId: UUID()) == nil)
        #expect(store.readFdaCheck() == nil)
    }

    @Test("a corrupt schedule state is preserved and mutations refuse it")
    func corruptFilesReturnNil() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()

        let destId = UUID()
        let setId = UUID()
        let garbage = Data("not valid json at all {{{".utf8)
        try garbage.write(to: store.paths.scheduleStateFile)
        try garbage.write(to: store.paths.repoStatusFile(destId: destId))
        try garbage.write(to: store.paths.currentRunFile(setId: setId))
        try garbage.write(to: store.paths.fdaCheckFile)

        let result = store.readScheduleStateResult()
        guard case .corrupt(let failure) = result else {
            Issue.record("expected corrupt schedule state, got \(result)")
            return
        }
        #expect(failure.reason == .malformedDocument)
        let quarantinePath = try #require(failure.quarantinePath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)) == garbage)

        // A second read reuses the content-addressed recovery copy and does
        // not proliferate files or temp artifacts.
        guard case .corrupt(let repeatedFailure) = store.readScheduleStateResult() else {
            Issue.record("repeated read no longer classified corruption")
            return
        }
        #expect(repeatedFailure.quarantinePath == quarantinePath)
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: store.paths.stateDir.path)
            .filter { $0.hasPrefix("schedule-state.corrupt-") && $0.hasSuffix(".json") }
        #expect(quarantines.count == 1)
        let before = try Data(contentsOf: store.paths.scheduleStateFile)
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: UUID()) { $0.lastBackupStart = Date() }
        }
        #expect(try Data(contentsOf: store.paths.scheduleStateFile) == before)
        #expect(store.readRepoStatus(destId: destId) == nil)
        #expect(store.readCurrentRun(setId: setId) == nil)
        #expect(store.readFdaCheck() == nil)
    }

    @Test("legacy schedule state is accepted and upgraded to a checksummed envelope on mutation")
    func legacyScheduleStateUpgradesOnMutation() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()
        let setId = UUID()
        let legacy = """
        {"sets":{"\(setId.uuidString)":{"checkSliceCursor":4}}}
        """
        try Data(legacy.utf8).write(to: store.paths.scheduleStateFile)

        guard case .valid(let state) = store.readScheduleStateResult() else {
            Issue.record("legacy schedule state was not accepted")
            return
        }
        #expect(state.sets[setId]?.checkSliceCursor == 4)

        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 5 }
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.scheduleStateFile))
                as? [String: Any]
        )
        #expect(object["version"] as? Int == ScheduleState.currentVersion)
        #expect((object["checksum"] as? String)?.count == 64)
        #expect(try Data(contentsOf: store.paths.scheduleStateVersionMarkerFile) == Data("1\n".utf8))
        #expect(store.readScheduleState()?.sets[setId]?.checkSliceCursor == 5)
    }

    @Test("an oversized prospective envelope publishes neither marker nor canonical state")
    func oversizedScheduleStateWriteRefusesBeforeMigrationMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-state-size-\(UUID().uuidString)")
        let paths = AppPaths(root: root)
        let limit: Int64 = 512
        let store = StateStore(
            paths: paths,
            fileOperations: .live,
            maximumScheduleStateBytes: limit
        )
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let setId = UUID()
        let destinationId = UUID()
        var pattern = String(repeating: "x", count: 128)
        func legacyBytes(_ value: String) throws -> Data {
            try StateStore.makeEncoder().encode(ScheduleState(sets: [
                setId: SetScheduleState(appliedPurgeExcludes: [destinationId: [value]])
            ]))
        }
        var legacy = try legacyBytes(pattern)
        let targetSize = Int(limit) - 1
        pattern += String(repeating: "x", count: targetSize - legacy.count)
        legacy = try legacyBytes(pattern)
        #expect(legacy.count == targetSize)
        try legacy.write(to: paths.scheduleStateFile)

        do {
            try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }
            Issue.record("the oversized envelope must be refused before publication")
        } catch let error as StateStoreError {
            guard case .scheduleStateWriteTooLarge(let bytes, let reportedLimit, let path) = error else {
                Issue.record("expected scheduleStateWriteTooLarge, got \(error)")
                return
            }
            #expect(bytes > limit)
            #expect(reportedLimit == limit)
            #expect(path == paths.scheduleStateFile.path)
        }

        #expect(try Data(contentsOf: paths.scheduleStateFile) == legacy)
        #expect(!FileManager.default.fileExists(atPath: paths.scheduleStateVersionMarkerFile.path))
        guard case .valid(let state) = store.readScheduleStateResult() else {
            Issue.record("the unchanged legacy canonical state must remain readable")
            return
        }
        #expect(state.sets[setId]?.appliedPurgeExcludes[destinationId] == [pattern])
    }

    @Test("a reader binds the migration marker and canonical document under the writer lock")
    func migrationReadWaitsForOneStableGeneration() throws {
        let (liveStore, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try liveStore.paths.ensureDirectories()
        let setId = UUID()
        try Data("{\"sets\":{\"\(setId.uuidString)\":{\"checkSliceCursor\":4}}}".utf8)
            .write(to: liveStore.paths.scheduleStateFile)

        let pause = ScheduleStateMigrationPause()
        let writer = StateStore(paths: liveStore.paths, fileOperations: pause.operations())
        let errors = StateStoreErrorRecorder()
        let read = ScheduleStateReadRecorder()
        let readerFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        group.enter()
        let writerThread = Thread {
            defer { group.leave() }
            do {
                try writer.updateScheduleState(setId: setId) { $0.checkSliceCursor = 5 }
            } catch {
                errors.record(error)
            }
        }
        writerThread.start()
        pause.waitUntilMarkerPublished()

        group.enter()
        let readerThread = Thread {
            defer {
                readerFinished.signal()
                group.leave()
            }
            read.record(liveStore.readScheduleStateResult())
        }
        readerThread.start()

        #expect(
            readerFinished.wait(timeout: .now() + 0.2) == .timedOut,
            "the reader must wait instead of quarantining the marker/legacy publication window"
        )
        pause.resume()
        #expect(group.wait(timeout: .now() + 3) == .success)
        #expect(errors.recorded.isEmpty)
        guard case .valid(let state) = read.result else {
            Issue.record("reader did not return the completed migration: \(String(describing: read.result))")
            return
        }
        #expect(state.sets[setId]?.checkSliceCursor == 5)
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: liveStore.paths.stateDir.path)
            .filter { $0.hasPrefix("schedule-state.corrupt-") }
        #expect(quarantines.isEmpty)
    }

    @Test("a migrated schedule state cannot be downgraded by stripping its envelope")
    func strippedVersionedEnvelopeFailsClosed() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let setId = UUID()
        try store.updateScheduleState(setId: setId) { state in
            state.appliedPurgeExcludes[UUID()] = ["private/**"]
        }

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.scheduleStateFile))
                as? [String: Any]
        )
        object.removeValue(forKey: "version")
        object.removeValue(forKey: "checksum")
        let stripped = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try stripped.write(to: store.paths.scheduleStateFile)

        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("a stripped v1 envelope was accepted as legacy state")
            return
        }
        #expect(failure.reason == .versionDowngrade)
        #expect(try Data(contentsOf: store.paths.scheduleStateFile) == stripped)
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }
        }
    }

    @Test("a versioned schedule state without its durable migration marker fails closed")
    func missingVersionMarkerFailsClosed() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }
        try FileManager.default.removeItem(at: store.paths.scheduleStateVersionMarkerFile)

        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("versioned state without its migration marker was accepted")
            return
        }
        #expect(failure.reason == .versionMarkerMissing)
        #expect(failure.recoveryMessage.contains("repair the owner-only marker"))
        #expect(failure.recoveryMessage.contains("mode 0600"))
        #expect(failure.recoveryMessage.contains("Replacing only the canonical JSON cannot repair"))
    }

    @Test("failed recovery-copy writes can be suppressed for the same canonical bytes")
    func failedRecoveryCopyDoesNotFeedItself() throws {
        let (liveStore, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try liveStore.paths.ensureDirectories()
        try Data("corrupt schedule {{{".utf8).write(to: liveStore.paths.scheduleStateFile)
        let counter = RecoveryWriteCounter()
        let store = StateStore(paths: liveStore.paths, fileOperations: counter.operations())

        guard case .corrupt(let first) = store.readScheduleStateResult() else {
            Issue.record("first corrupt read was not classified")
            return
        }
        #expect(first.quarantineWriteFailed)
        let fingerprint = try #require(first.contentFingerprint)
        #expect(counter.writes == 1)

        guard case .corrupt(let second) = store.readScheduleStateResult(
            suppressingRecoveryCopyFor: fingerprint
        ) else {
            Issue.record("suppressed corrupt read was not classified")
            return
        }
        #expect(second.contentFingerprint == fingerprint)
        #expect(second.quarantineWriteFailed)
        #expect(counter.writes == 1, "a self-generated reload must not attempt another recovery write")
    }

    @Test("a recovery copy renamed before an indeterminate directory sync is recognized on reread")
    func indeterminateRecoveryCopyIsRecognizedWithoutRewrite() throws {
        let (liveStore, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try liveStore.paths.ensureDirectories()
        let corrupt = Data("corrupt schedule after rename {{{".utf8)
        try corrupt.write(to: liveStore.paths.scheduleStateFile)
        let injector = ScheduleStateFaultInjector(.secondSync)
        let store = StateStore(paths: liveStore.paths, fileOperations: injector.operations())

        guard case .corrupt(let first) = store.readScheduleStateResult() else {
            Issue.record("first corrupt read was not classified")
            return
        }
        #expect(first.quarantineWriteFailed)
        let fingerprint = try #require(first.contentFingerprint)

        guard case .corrupt(let second) = store.readScheduleStateResult(
            suppressingRecoveryCopyFor: fingerprint
        ) else {
            Issue.record("second corrupt read was not classified")
            return
        }
        #expect(second.quarantineWriteFailed == false)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(second.quarantinePath))) == corrupt)
    }

    @Test("durable schedule-state temps are pinned and verified as owner-only")
    func durableTempsIgnoreRestrictiveCreationModes() throws {
        let (liveStore, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = StateStoreFileOperations.live
        let maskedCreation = StateStoreFileOperations(
            openAt: { directory, name, flags, mode in
                live.openAt(directory, name, flags, flags & O_CREAT == 0 ? mode : 0)
            },
            read: live.read,
            write: live.write,
            sync: live.sync,
            stat: live.stat,
            setMode: live.setMode,
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt,
            close: live.close
        )
        let store = StateStore(paths: liveStore.paths, fileOperations: maskedCreation)
        try store.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }

        for path in [store.paths.scheduleStateVersionMarkerFile.path, store.paths.scheduleStateFile.path] {
            var info = stat()
            #expect(path.withCString { lstat($0, &info) } == 0)
            #expect(info.st_mode & 0o7777 == 0o600)
        }

        let unverifiable = StateStoreFileOperations(
            openAt: { directory, name, flags, mode in
                live.openAt(directory, name, flags, flags & O_CREAT == 0 ? mode : 0)
            },
            read: live.read,
            write: live.write,
            sync: live.sync,
            stat: live.stat,
            setMode: { _, _ in 0 },
            renameAt: live.renameAt,
            unlinkAt: live.unlinkAt,
            close: live.close
        )
        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-mode-verify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let unverifiableStore = StateStore(
            paths: AppPaths(root: otherRoot),
            fileOperations: unverifiable
        )
        #expect(throws: StateStoreError.self) {
            try unverifiableStore.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }
        }
        #expect(!FileManager.default.fileExists(
            atPath: unverifiableStore.paths.scheduleStateVersionMarkerFile.path
        ))
    }

    @Test("a checksum mismatch is quarantined and cannot be overwritten")
    func checksumMismatchFailsClosed() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let setId = UUID()
        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.paths.scheduleStateFile))
                as? [String: Any]
        )
        var sets = try #require(object["sets"] as? [String: Any])
        var entry = try #require(sets[setId.uuidString] as? [String: Any])
        entry["checkSliceCursor"] = 99
        sets[setId.uuidString] = entry
        object["sets"] = sets
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tampered.write(to: store.paths.scheduleStateFile)

        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("tampered envelope was accepted")
            return
        }
        #expect(failure.reason == .checksumMismatch)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(failure.quarantinePath))) == tampered)
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 100 }
        }
        #expect(try Data(contentsOf: store.paths.scheduleStateFile) == tampered)
    }

    @Test("newer versions and malformed UUID keys fail closed")
    func unsupportedAndMalformedScheduleStateFailClosed() throws {
        for document in [
            "{}",
            "{\"version\":null,\"sets\":{}}",
            "{\"checksum\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"sets\":{}}",
            "{\"version\":999,\"checksum\":\"ignored\",\"sets\":{}}",
            "{\"sets\":{\"not-a-uuid\":{\"checkSliceCursor\":1}}}",
            "{\"sets\":{\"\(UUID().uuidString)\":{\"appliedPurgeExcludes\":{\"not-a-uuid\":[\"*.tmp\"]}}}}",
        ] {
            let (store, root) = makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            try store.paths.ensureDirectories()
            try Data(document.utf8).write(to: store.paths.scheduleStateFile)
            guard case .corrupt(let failure) = store.readScheduleStateResult() else {
                Issue.record("unsafe schedule document was accepted: \(document)")
                continue
            }
            #expect(failure.quarantinePath != nil)
        }
    }

    @Test("a symlink at the canonical schedule-state path is never followed")
    func scheduleStateSymlinkFailsClosed() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()
        let target = root.appendingPathComponent("outside-schedule.json")
        let targetBytes = Data("{\"sets\":{}}".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: store.paths.scheduleStateFile,
            withDestinationURL: target
        )

        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("canonical symlink was followed")
            return
        }
        guard case .ioFailure(let operation, _) = failure.reason else {
            Issue.record("symlink refusal was misclassified: \(failure.reason)")
            return
        }
        #expect(operation == "open schedule state")
        #expect(failure.quarantinePath == nil, "unread bytes cannot be claimed as preserved")
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }
        }
        #expect(try Data(contentsOf: target) == targetBytes)
        let values = try store.paths.scheduleStateFile.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
    }

    @Test("FIFO schedule and recovery paths are rejected without blocking")
    func scheduleStateFIFOsDoNotBlock() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()
        try #require(store.paths.scheduleStateFile.path.withCString { mkfifo($0, 0o600) } == 0)

        let started = Date()
        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("FIFO canonical schedule state was accepted")
            return
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(failure.reason == .unsafeFile(reason: "not a regular file"))

        try FileManager.default.removeItem(at: store.paths.scheduleStateFile)
        let corrupt = Data("bad schedule {{{".utf8)
        try corrupt.write(to: store.paths.scheduleStateFile)
        guard case .corrupt(let firstFailure) = store.readScheduleStateResult() else {
            Issue.record("corrupt bytes were not classified")
            return
        }
        let recovery = URL(fileURLWithPath: try #require(firstFailure.quarantinePath))
        try FileManager.default.removeItem(at: recovery)
        try #require(recovery.path.withCString { mkfifo($0, 0o600) } == 0)

        let recoveryStarted = Date()
        guard case .corrupt(let secondFailure) = store.readScheduleStateResult() else {
            Issue.record("corrupt bytes with a FIFO recovery path were not classified")
            return
        }
        #expect(Date().timeIntervalSince(recoveryStarted) < 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(secondFailure.quarantinePath))) == corrupt)
    }

    @Test("an unsafe migration marker fails closed when canonical state is absent")
    func scheduleStateMarkerFIFOWithoutCanonicalFailsClosed() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()
        try #require(
            store.paths.scheduleStateVersionMarkerFile.path.withCString { mkfifo($0, 0o600) } == 0
        )

        let started = Date()
        guard case .corrupt(let failure) = store.readScheduleStateResult() else {
            Issue.record("FIFO migration marker was hidden by the missing canonical state")
            return
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(
            failure.reason == .unsafeFile(
                reason: "schedule state version marker is not a regular file"
            )
        )
        #expect(failure.quarantinePath == nil)
        #expect(!FileManager.default.fileExists(atPath: store.paths.scheduleStateFile.path))
        #expect(throws: StateStoreError.self) {
            try store.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }
        }
        #expect(!FileManager.default.fileExists(atPath: store.paths.scheduleStateFile.path))
    }

    @Test("schedule-state publication reports each durability boundary failure")
    func scheduleStateDurabilityFaults() throws {
        for point in [
            ScheduleStateFaultInjector.Point.firstSync,
            .rename,
            .secondSync,
        ] {
            let (liveStore, root) = makeStore()
            defer { try? FileManager.default.removeItem(at: root) }
            let setId = UUID()
            try liveStore.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }
            let before = try Data(contentsOf: liveStore.paths.scheduleStateFile)
            let fault = ScheduleStateFaultInjector(point)
            let failingStore = StateStore(paths: liveStore.paths, fileOperations: fault.operations())

            #expect(throws: StateStoreError.self) {
                try failingStore.updateScheduleState(setId: setId) { $0.checkSliceCursor = 2 }
            }
            let after = try Data(contentsOf: liveStore.paths.scheduleStateFile)
            if point == .secondSync {
                // rename completed, but absence of directory durability is
                // still reported rather than acknowledged as success.
                #expect(after != before)
            } else {
                #expect(after == before)
            }
        }
    }

    @Test("the monotonic migration marker commits before any v1 envelope")
    func scheduleStateMarkerDurabilityFaults() throws {
        for point in [
            ScheduleStateFaultInjector.Point.firstSync,
            .rename,
            .secondSync,
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("restic-station-marker-fault-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = AppPaths(root: root)
            let injector = ScheduleStateFaultInjector(point)
            let store = StateStore(paths: paths, fileOperations: injector.operations())

            #expect(throws: StateStoreError.self) {
                try store.updateScheduleState(setId: UUID()) { $0.checkSliceCursor = 1 }
            }
            #expect(!FileManager.default.fileExists(atPath: paths.scheduleStateFile.path))
            #expect(StateStore(paths: paths).readScheduleStateResult() == .missing)
        }
    }

    // MARK: - Atomic writes leave no temp files

    @Test("writes leave no .tmp files behind, for all four state files")
    func writesLeaveNoTempFiles() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        let setId = UUID()

        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 3 }
        try store.updateRepoStatus(destId: destId) { $0.reachable = true }
        try store.writeCurrentRun(setId: setId, Self.sampleCurrentRun(setId: setId))
        try store.writeFdaCheck(FdaCheckResult(checkedAt: Date(), hasFullDiskAccess: true, probedPath: "~/Library/Safari", context: "app"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: store.paths.stateDir.path)
        let tempFiles = contents.filter { $0.hasSuffix(".tmp") }
        #expect(tempFiles.isEmpty, "leftover temp files: \(tempFiles)")

        // And the real files are valid, complete JSON.
        for file in [
            store.paths.scheduleStateFile,
            store.paths.repoStatusFile(destId: destId),
            store.paths.currentRunFile(setId: setId),
            store.paths.fdaCheckFile,
        ] {
            let data = try Data(contentsOf: file)
            _ = try JSONSerialization.jsonObject(with: data) // must not throw
        }
    }

    @Test("save overwrites a pre-existing stale/corrupt temp file")
    func overwritesStaleTempFile() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.paths.ensureDirectories()

        let tempFile = store.paths.scheduleStateFile.deletingLastPathComponent()
            .appendingPathComponent(store.paths.scheduleStateFile.lastPathComponent + ".tmp", isDirectory: false)
        try Data("leftover garbage from a crashed write".utf8).write(to: tempFile)

        let setId = UUID()
        try store.updateScheduleState(setId: setId) { $0.checkSliceCursor = 1 }

        #expect(!FileManager.default.fileExists(atPath: tempFile.path))
        #expect(store.readScheduleState()?.sets[setId]?.checkSliceCursor == 1)
    }

    // MARK: - Mutate helpers create-or-update correctly

    @Test("updateScheduleState creates an entry when absent, then updates it in place")
    func updateScheduleStateCreatesThenUpdates() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setId = UUID()
        let start = Self.date("2026-07-26T02:30:00Z")

        try store.updateScheduleState(setId: setId) { entry in
            #expect(entry == SetScheduleState()) // freshly created, all nil
            entry.lastBackupStart = start
            entry.checkSliceCursor = 1
        }
        var loaded = try #require(store.readScheduleState())
        #expect(loaded.sets[setId]?.lastBackupStart == start)
        #expect(loaded.sets[setId]?.checkSliceCursor == 1)
        #expect(loaded.sets.count == 1)

        // A second mutation updates the SAME entry rather than creating a
        // second one, and other fields already set survive untouched.
        try store.updateScheduleState(setId: setId) { entry in
            #expect(entry.lastBackupStart == start)
            entry.checkSliceCursor = 2
        }
        loaded = try #require(store.readScheduleState())
        #expect(loaded.sets.count == 1)
        #expect(loaded.sets[setId]?.lastBackupStart == start)
        #expect(loaded.sets[setId]?.checkSliceCursor == 2)

        // A different set gets its own independent entry.
        let otherSetId = UUID()
        try store.updateScheduleState(setId: otherSetId) { $0.checkSliceCursor = 9 }
        loaded = try #require(store.readScheduleState())
        #expect(loaded.sets.count == 2)
        #expect(loaded.sets[setId]?.checkSliceCursor == 2)
        #expect(loaded.sets[otherSetId]?.checkSliceCursor == 9)
    }

    @Test("updateRepoStatus creates a fresh unreachable record when absent, then updates it")
    func updateRepoStatusCreatesThenUpdates() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        let probedAt = Self.date("2026-07-26T20:57:10Z")

        try store.updateRepoStatus(destId: destId) { status in
            #expect(status.destId == destId)
            #expect(status.reachable == false) // fresh default
            #expect(status.lastSyncedAt == nil)
            status.reachable = true
            status.probedAt = probedAt
            status.lastSyncedAt = probedAt
        }
        var loaded = try #require(store.readRepoStatus(destId: destId))
        #expect(loaded.reachable == true)
        #expect(loaded.probedAt == probedAt)
        #expect(loaded.lastSyncedAt == probedAt)

        // Going offline updates in place; lastSyncedAt (last SUCCESS) is
        // preserved by a caller that doesn't touch it.
        let laterProbe = Self.date("2026-07-26T21:00:00Z")
        try store.updateRepoStatus(destId: destId) { status in
            status.reachable = false
            status.probedAt = laterProbe
            status.lastError = "volume not mounted"
        }
        loaded = try #require(store.readRepoStatus(destId: destId))
        #expect(loaded.reachable == false)
        #expect(loaded.probedAt == laterProbe)
        #expect(loaded.lastSyncedAt == probedAt) // untouched
        #expect(loaded.lastError == "volume not mounted")
    }

    @Test("writeCurrentRun then clearCurrentRun round-trips and then reads nil")
    func writeThenClearCurrentRun() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setId = UUID()
        let state = Self.sampleCurrentRun(setId: setId)
        try store.writeCurrentRun(setId: setId, state)
        #expect(store.readCurrentRun(setId: setId) == state)

        try store.clearCurrentRun(setId: setId)
        #expect(store.readCurrentRun(setId: setId) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.paths.currentRunFile(setId: setId).path))
    }

    @Test("clearCurrentRun on an already-absent file is a harmless no-op")
    func clearCurrentRunWhenAbsent() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // Must not throw even though nothing was ever written.
        try store.clearCurrentRun(setId: UUID())
    }

    // MARK: - currentRunSetIDs (T27 `status`)

    @Test("currentRunSetIDs finds every live current-run file, by filename, ignoring other state files")
    func currentRunSetIDsFindsLiveRuns() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let running1 = UUID()
        let running2 = UUID()
        let finished = UUID()
        try store.writeCurrentRun(setId: running1, Self.sampleCurrentRun(setId: running1))
        try store.writeCurrentRun(setId: running2, Self.sampleCurrentRun(setId: running2))
        // A repo-status file must not be mistaken for a current-run file.
        try store.updateRepoStatus(destId: UUID()) { $0.reachable = true }
        // A run that finished (file deleted) must not still count.
        try store.writeCurrentRun(setId: finished, Self.sampleCurrentRun(setId: finished))
        try store.clearCurrentRun(setId: finished)

        let ids = Set(store.currentRunSetIDs())
        #expect(ids == [running1, running2])
    }

    /// The documented contract this exists for: a set no longer in
    /// `config.json` but with a run still in flight must still be counted —
    /// discovery is by filename, never by cross-referencing the config.
    @Test("a run for a set no longer in config.json is still discovered")
    func currentRunSetIDsDoesNotConsultConfig() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let deletedSetId = UUID()
        try store.writeCurrentRun(setId: deletedSetId, Self.sampleCurrentRun(setId: deletedSetId))

        #expect(store.currentRunSetIDs() == [deletedSetId])
    }

    @Test("an absent state/ directory yields an empty list, not a throw")
    func currentRunSetIDsOnMissingStateDirectory() {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        // `makeStore()` never calls `ensureDirectories()`, so `state/` does
        // not exist yet.
        #expect(store.currentRunSetIDs().isEmpty)
    }

    @Test("writeFdaCheck round-trips")
    func writeFdaCheckRoundTrips() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = FdaCheckResult(
            checkedAt: Self.date("2026-07-26T20:57:00Z"),
            hasFullDiskAccess: false,
            probedPath: "~/Library/Mail",
            context: "app"
        )
        try store.writeFdaCheck(result)
        #expect(store.readFdaCheck() == result)
    }

    // MARK: - Encoding conventions

    @Test("encoded state file uses sortedKeys and prettyPrinted, like ConfigStore")
    func encodedFileUsesSortedKeysAndPrettyPrinted() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let destId = UUID()
        try store.updateRepoStatus(destId: destId) { $0.reachable = true }
        let contents = try String(contentsOf: store.paths.repoStatusFile(destId: destId), encoding: .utf8)
        #expect(contents.contains("\n")) // pretty-printed, not compact
        // .sortedKeys -> "destId" (d) before "lastError" (l) before "reachable" (r).
        let destIdRange = try #require(contents.range(of: "\"destId\""))
        let lastErrorRange = try #require(contents.range(of: "\"lastError\""))
        let reachableRange = try #require(contents.range(of: "\"reachable\""))
        #expect(destIdRange.lowerBound < lastErrorRange.lowerBound)
        #expect(lastErrorRange.lowerBound < reachableRange.lowerBound)
    }

    // MARK: - Helpers

    private static func sampleCurrentRun(setId: UUID) -> CurrentRunState {
        CurrentRunState(
            runId: "20260726T205704Z-backup-\(String(setId.uuidString.prefix(8)).lowercased())",
            kind: .backup,
            phase: "backing-up-primary",
            percentDone: 0.42,
            bytesDone: 1_234_567,
            totalBytes: 987_654_321,
            filesDone: 120,
            totalFiles: 4000,
            currentFiles: ["/Users/user/proj/big.dat"],
            updatedAt: Self.date("2026-07-26T20:57:30Z")
        )
    }

    private static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    /// `schedule-state.json` is one document shared by every set, while the
    /// only other lock is per-set — so two helper processes working on
    /// *different* sets take no common lock and each rewrite the whole file.
    /// Without the companion lock, one reads before the other's write and
    /// writes after it, silently discarding the other's entry. That entry now
    /// carries `appliedPurgeExcludes`, i.e. destructive bookkeeping.
    ///
    /// Interleaved deliberately: each mutation sleeps inside the critical
    /// section, so a read-modify-write that is not held under a lock will
    /// overlap and lose an entry essentially every run.
    @Test("concurrent updates for different sets do not lose one another")
    func concurrentScheduleStateUpdatesDoNotLoseEntries() throws {
        let (store, root) = makeStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let setIds = (0..<8).map { _ in UUID() }
        // Dedicated threads, deliberately not a `TaskGroup` and not the
        // global concurrent queue.
        //
        // `updateScheduleState` blocks — it sleeps between lock attempts —
        // and the writers sleep inside the critical section on purpose to
        // widen the read/write window. Blocking Swift Concurrency's
        // cooperative pool starves it, so the lock holder cannot be scheduled
        // to release and waiters spin to the timeout. Blocking the global
        // dispatch pool is nearly as rude: it is shared with Foundation's own
        // machinery, including `Process`, and this suite spawns subprocesses
        // concurrently. Owning the threads keeps the pressure local to this
        // test.
        let errors = StateStoreErrorRecorder()
        let threads = setIds.enumerated().map { index, setId in
            Thread {
                do {
                    try store.updateScheduleState(setId: setId) { entry in
                        usleep(20_000)
                        entry.checkSliceCursor = index
                    }
                } catch {
                    errors.record(error)
                }
            }
        }
        threads.forEach { $0.start() }
        while threads.contains(where: { !$0.isFinished }) { usleep(2_000) }

        #expect(errors.recorded.isEmpty, "writers failed: \(errors.recorded)")

        let state = try #require(store.readScheduleState())
        for (index, setId) in setIds.enumerated() {
            #expect(state.sets[setId]?.checkSliceCursor == index, "lost the entry for set \(index)")
        }
    }
}
