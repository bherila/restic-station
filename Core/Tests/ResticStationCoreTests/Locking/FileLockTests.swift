import Foundation
import Testing
@testable import ResticStationCore

@Suite struct FileLockTests {
    private func makeLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-filelock-test-\(UUID().uuidString).lock")
    }

    @Test func secondInstanceCannotAcquireWhileFirstHolds() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Two separate FileLock instances on the same path == two separate
        // open file descriptions, so they genuinely contend even though
        // they live in the same process (flock is per-open-file-description,
        // not per-process).
        let first = FileLock(path: url)
        let second = FileLock(path: url)

        #expect(first.tryAcquire() == true)
        #expect(second.tryAcquire() == false)

        first.release()
        #expect(second.tryAcquire() == true)

        second.release()
    }

    @Test func deinitReleasesTheLock() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var holder: FileLock? = FileLock(path: url)
        #expect(holder?.tryAcquire() == true)

        holder = nil // deinit should release

        let contender = FileLock(path: url)
        #expect(contender.tryAcquire() == true)
        contender.release()
    }

    @Test func lockFileItselfPersistingMeansNothing() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = FileLock(path: url)
        #expect(lock.tryAcquire() == true)
        lock.release()

        // The lock file on disk still exists after release, but a fresh
        // FileLock can acquire it immediately — mere existence of the file
        // means nothing per docs/scheduling.md §Locking.
        #expect(FileManager.default.fileExists(atPath: url.path) == true)
        let fresh = FileLock(path: url)
        #expect(fresh.tryAcquire() == true)
        fresh.release()
    }

    @Test func reacquireBySameInstanceAfterReleaseSucceeds() throws {
        let url = makeLockURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = FileLock(path: url)
        #expect(lock.tryAcquire() == true)
        lock.release()
        #expect(lock.tryAcquire() == true)
        lock.release()
    }
}
