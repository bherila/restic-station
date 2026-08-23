import Foundation

/// Serializes tests that mutate process environment.
///
/// `RESTIC_STATION_DATA_DIR` is process-global, and `AppPaths.default()`
/// reads it — which is how several helper tests point a command at a
/// fixture without a seam of their own. Swift Testing runs tests in
/// parallel by default, and a `.serialized` trait only orders tests *within
/// one suite*, so two suites that each set the variable can interleave and
/// read each other's directory.
///
/// An actor rather than a lock: the critical section spans `await`s, which
/// a lock cannot hold across. Callers in different suites and different
/// files all funnel through the one instance.
actor TestEnvironmentLock {
    static let shared = TestEnvironmentLock()

    /// Runs `body` with `RESTIC_STATION_DATA_DIR` set to `path`, restoring
    /// whatever was there before — including "unset", which is not the same
    /// as empty.
    /// `T: Sendable` and `@Sendable` on `body` are load-bearing, not
    /// decoration: Swift 6.1 (the toolchain the Linux CI container pins)
    /// rejects returning a non-`Sendable` `T` across the actor boundary,
    /// while 6.3 accepts it. Written to the stricter rule so both agree.
    func withDataDirectory<T: Sendable>(
        _ path: String,
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        let key = "RESTIC_STATION_DATA_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return try await body()
    }
}
