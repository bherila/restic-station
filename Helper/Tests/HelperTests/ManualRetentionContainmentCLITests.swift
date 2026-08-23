import ArgumentParser
import Foundation
import ResticStationCore
import Testing

@testable import restic_station_helper

/// The CLI half of Option A containment. Core's refusal is covered by
/// `ManualRetentionContainmentTests`; what only the CLI can get wrong is
/// **where** the refusal sits.
///
/// `run-set --kind prune` must refuse before `HelperContext.make()`, so that
/// containment costs no config load, no data-directory creation, no restic
/// discovery or hashing, no secret read, no lock, and no run record.
///
/// Ordering is asserted by side effect rather than by error code: the data
/// directory is pointed at a path that does not exist, and the refusal must
/// leave it that way. `HelperContext.make()` calls `AppPaths.ensureDirectories`,
/// so a gate that moved even one line later would create the tree and fail
/// this test — which a code-only assertion could not detect, since the
/// context construction would otherwise have *succeeded* here.
///
/// Environment mutation goes through ``TestEnvironmentLock``: a `.serialized`
/// trait would only order tests inside this suite, and `CLIErrorEnvelopeTests`
/// mutates the same variable from another one.
@Suite("manual retention containment (CLI)")
struct ManualRetentionContainmentCLITests {

    @Test("run-set --kind prune refuses before any context is built")
    func pruneRefusesBeforeContextConstruction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-containment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await TestEnvironmentLock.withDataDirectory(root.path) {
            #expect(
                !FileManager.default.fileExists(atPath: root.path),
                "precondition: the data directory does not exist yet"
            )

            let command = try RunSet.parse([
                "--set", "00000000-0000-0000-0000-000000000001", "--kind", "prune",
            ])

            do {
                try await command.run()
                Issue.record("expected a refusal")
            } catch let failure as CLIFailure {
                #expect(failure.code == .operationNotAllowed)
                #expect(failure.message == ManualRetentionApplyAvailability.reason)
            }

            #expect(
                !FileManager.default.fileExists(atPath: root.path),
                """
                the refusal created the data directory, so it ran after \
                HelperContext.make(). The gate must be the first statement in \
                RunSet.run(), before any context is built.
                """
            )
        }
    }
}

/// ``TestEnvironmentLock`` itself. The mechanism is only worth having if it
/// holds across `await`, which is precisely where an `actor` method does
/// not: actors are reentrant at their suspension points, so an earlier
/// version of this type let a second caller overwrite the variable
/// mid-flight and then restore a stale value.
@Suite("TestEnvironmentLock")
struct TestEnvironmentLockTests {

    @Test("concurrent callers each observe their own value across a suspension")
    func serializesAcrossSuspension() async throws {
        let key = "RESTIC_STATION_DATA_DIR"

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let mine = "/tmp/env-lock-probe-\(index)"
                    try await TestEnvironmentLock.withDataDirectory(mine) {
                        // Suspend inside the critical section: an actor
                        // would admit another caller right here.
                        for _ in 0..<4 { await Task.yield() }
                        let seen = ProcessInfo.processInfo.environment[key]
                        #expect(
                            seen == mine,
                            "another caller entered the critical section: expected \(mine), saw \(seen ?? "unset")"
                        )
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test("the previous value is restored, including when it was unset")
    func restoresPreviousValue() async throws {
        let key = "RESTIC_STATION_DATA_DIR"
        // The clearing, the nested set, and the post-assertion all have to
        // sit inside one gate acquisition: doing the `unsetenv` outside it
        // would race whichever test currently owns the variable — the exact
        // failure this file exists to prevent.
        try await TestEnvironmentLock.withExclusiveAccess {
            // Capture and put back whatever the process started with: this
            // test asserts the unset case, and leaking that unset would hand
            // every later test the platform default instead of its fixture.
            let original = ProcessInfo.processInfo.environment[key]
            defer { if let original { setenv(key, original, 1) } }
            unsetenv(key)
            try await TestEnvironmentLock.unsafeWithDataDirectory("/tmp/env-lock-restore") {
                #expect(ProcessInfo.processInfo.environment[key] == "/tmp/env-lock-restore")
            }
            #expect(
                ProcessInfo.processInfo.environment[key] == nil,
                "an unset variable must come back unset, not empty"
            )
        }
    }
}
