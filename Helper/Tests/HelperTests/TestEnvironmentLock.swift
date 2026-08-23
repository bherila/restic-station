import Foundation

/// Serializes tests that mutate process environment.
///
/// `RESTIC_STATION_DATA_DIR` is process-global, and `AppPaths.default()`
/// reads it — which is how several helper tests point a command at a
/// fixture without a seam of their own. Swift Testing runs tests in
/// parallel by default, and a `.serialized` trait only orders tests *within
/// one suite*, so two suites that each set the variable can interleave.
///
/// ## Why not simply an actor
///
/// Actor isolation is **not** a mutex across `await`. An actor method that
/// awaits inside its body suspends, and the actor is free to admit another
/// call at that suspension point — so wrapping the critical section in an
/// `actor` method and awaiting the caller's work inside it lets a second
/// test overwrite the variable mid-flight and then restore a stale value
/// on the way out. Exactly the race the type exists to prevent.
///
/// So ownership is explicit: ``AsyncGate`` holds a boolean and a queue of
/// waiters, the caller's work runs *outside* the gate's isolation, and the
/// gate is released only after the environment has been restored.
private actor AsyncGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // Ownership passes straight to the next waiter; `isHeld` stays
            // true so a newly arriving caller cannot jump the queue.
            waiters.removeFirst().resume()
        }
    }
}

enum TestEnvironmentLock {
    private static let gate = AsyncGate()

    /// Runs `body` with `RESTIC_STATION_DATA_DIR` set to `path`, restoring
    /// whatever was there before — including "unset", which is not the same
    /// as empty.
    ///
    /// `T: Sendable` and `@Sendable` on `body` are load-bearing, not
    /// decoration: Swift 6.1 (the toolchain the Linux CI container pins)
    /// rejects sending a non-`Sendable` `T` across the isolation boundary
    /// while 6.3 accepts it. Written to the stricter rule so both agree.
    ///
    /// `throws` rather than `rethrows`: the release has to happen on both
    /// paths, and `defer` cannot `await`.
    static func withDataDirectory<T: Sendable>(
        _ path: String,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusiveAccess {
            try await unsafeWithDataDirectory(path, body)
        }
    }

    /// Holds the gate for the duration of `body` without touching the
    /// environment itself. For a caller that needs to set, clear, *and*
    /// assert the variable in one uninterrupted window — which the ordinary
    /// entry point cannot express, since it owns the set and the restore.
    static func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await gate.acquire()
        do {
            let result = try await body()
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Set-and-restore with **no** synchronization. Only valid inside
    /// ``withExclusiveAccess(_:)``; calling it anywhere else reintroduces
    /// the cross-suite race this file exists to close.
    static func unsafeWithDataDirectory<T: Sendable>(
        _ path: String,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let key = "RESTIC_STATION_DATA_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, path, 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        return try await body()
    }
}
