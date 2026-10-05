import Foundation
import Testing
@testable import ResticStationCore

/// #156, Codex on #174: a launch made outside `DefaultProcessRunner` (the
/// app's `Foundation.Process` children) must never land inside a spawn's
/// dataless-policy window. `SpawnSerialization.run` holds the lock those
/// spawns take; while it is held, no runner spawn can proceed.
@Suite struct SpawnSerializationTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("a runner spawn waits while a serialized launch holds the spawn lock")
    func runnerSpawnWaitsForSerializedLaunch() async throws {
        let spawned = Flag()
        let finishedWhileHeld = Flag()
        let released = Flag()

        // The holder runs on its own thread so the cooperative pool is free
        // for the spawning task.
        let holder = Thread {
            SpawnSerialization.run {
                Task.detached {
                    _ = try? await DefaultProcessRunner().run(
                        ["/usr/bin/true"], env: [:], currentDirectory: nil,
                        onStdoutLine: nil, onStderrLine: nil, timeout: 30
                    )
                    spawned.set()
                }
                Thread.sleep(forTimeInterval: 0.5)
                if spawned.isSet { finishedWhileHeld.set() }
            }
            released.set()
        }
        holder.start()

        let deadline = ContinuousClock.now + .seconds(20)
        while !(spawned.isSet && released.isSet), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!finishedWhileHeld.isSet, "a runner spawn completed while the serialized launch held the lock")
        #expect(spawned.isSet, "the runner spawn never completed after the lock was released")
    }
}
