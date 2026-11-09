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

/// #156, Codex on #174: a launch made outside `DefaultProcessRunner` (the
/// app's `Foundation.Process` children) must never land inside a spawn's
/// dataless-policy window. `SpawnSerialization.run` holds the lock those
/// spawns take; while it is held, no runner spawn can proceed.
///
/// #206: every wait here is on a dedicated thread or a semaphore, never on
/// the Swift cooperative pool. The earlier version spawned through
/// `DefaultProcessRunner.run` from a detached task and polled with
/// `Task.sleep`, so it also needed free pool threads to resume — which the
/// parallel suite on a small hosted macOS runner sometimes did not have for
/// 20 s. The property under test is the *launch*, so the spawner calls the
/// runner's synchronous launch path, `spawnWithRetry`, directly.
@Suite struct SpawnSerializationTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("a runner spawn waits while a serialized launch holds the spawn lock")
    func runnerSpawnWaitsForSerializedLaunch() throws {
        let launched = Flag()
        let launchedWhileHeld = Flag()
        let launchFailed = Flag()
        let launchDone = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)

        let holder = Thread {
            SpawnSerialization.run {
                let spawner = Thread {
                    let signal = TerminationSignal()
                    do {
                        let process = try DefaultProcessRunner.spawnWithRetry(
                            argv: ["/usr/bin/true"], env: [:], datalessFiles: nil,
                            terminationSignal: signal
                        )
                        launched.set()
                        close(process.stdinWrite)
                        close(process.stdoutRead)
                        close(process.stderrRead)
                        // The runner's waiter thread reaps the child and fires
                        // `signal`; wait for that so no child outlives the test.
                        DispatchQueue.global().async {
                            while !signal.hasFired { usleep(10_000) }
                            exited.signal()
                        }
                    } catch {
                        launchFailed.set()
                        exited.signal()
                    }
                    launchDone.signal()
                }
                spawner.start()
                Thread.sleep(forTimeInterval: 0.5)
                if launched.isSet { launchedWhileHeld.set() }
            }
            released.signal()
        }
        holder.start()

        #expect(released.wait(timeout: .now() + 60) == .success, "the serialized launch never released the lock")
        #expect(launchDone.wait(timeout: .now() + 60) == .success, "the runner spawn never returned after the lock was released")
        #expect(!launchFailed.isSet, "the runner spawn failed")
        #expect(!launchedWhileHeld.isSet, "a runner spawn launched while the serialized launch held the lock")
        #expect(launched.isSet)
        #expect(exited.wait(timeout: .now() + 60) == .success, "the spawned child was never reaped")
    }
}
