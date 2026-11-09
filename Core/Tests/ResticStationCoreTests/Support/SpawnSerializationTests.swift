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
/// #206: nothing here waits on the Swift cooperative pool or on a GCD global
/// queue. The earlier version spawned through `DefaultProcessRunner.run`
/// from a detached task and polled with `Task.sleep`, so it needed free pool
/// threads to finish, and the parallel suite on a small hosted macOS runner
/// sometimes left none for 20 s. On macOS both pools draw on one thread
/// budget, so a test that parks either kind of thread starves the rest of
/// the suite as well. Every wait is on a dedicated `Thread`; the test's task
/// only receives the outcome. The property under test is the *launch*, so
/// the spawner calls the runner's synchronous launch path, `spawnWithRetry`.
@Suite struct SpawnSerializationTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct Outcome: Sendable {
        var released = false
        var launchReturned = false
        var reaped = false
    }

    /// Runs `body` on its own thread; the awaiting task holds no thread
    /// meanwhile and is resumed once with the result.
    private static func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    @Test("a runner spawn waits while a serialized launch holds the spawn lock")
    func runnerSpawnWaitsForSerializedLaunch() async throws {
        let launched = Flag()
        let launchedWhileHeld = Flag()
        let launchFailed = Flag()
        let released = DispatchSemaphore(value: 0)
        let launchDone = DispatchSemaphore(value: 0)
        let reaped = DispatchSemaphore(value: 0)

        let spawn: @Sendable () -> Void = {
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
                launchDone.signal()
                // The runner's waiter thread reaps the child and fires
                // `signal`; wait here so no child outlives the test.
                let deadline = ContinuousClock.now + .seconds(60)
                while !signal.hasFired, ContinuousClock.now < deadline { usleep(10_000) }
                if signal.hasFired { reaped.signal() }
            } catch {
                launchFailed.set()
                launchDone.signal()
            }
        }
        let holder = Thread {
            SpawnSerialization.run {
                Thread(block: spawn).start()
                Thread.sleep(forTimeInterval: 0.5)
                if launched.isSet { launchedWhileHeld.set() }
            }
            released.signal()
        }
        holder.start()

        let outcome = await Self.onOwnThread {
            var outcome = Outcome()
            outcome.released = released.wait(timeout: .now() + 60) == .success
            outcome.launchReturned = launchDone.wait(timeout: .now() + 60) == .success
            outcome.reaped = reaped.wait(timeout: .now() + 60) == .success
            return outcome
        }
        #expect(outcome.released, "the serialized launch never released the lock")
        #expect(outcome.launchReturned, "the runner spawn never returned after the lock was released")
        #expect(!launchFailed.isSet, "the runner spawn failed")
        #expect(!launchedWhileHeld.isSet, "a runner spawn launched while the serialized launch held the lock")
        #expect(launched.isSet)
        #expect(outcome.reaped || launchFailed.isSet, "the spawned child was never reaped")
    }
}
