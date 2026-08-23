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
/// Serialized because it mutates process environment.
@Suite("manual retention containment (CLI)", .serialized)
struct ManualRetentionContainmentCLITests {

    @Test("run-set --kind prune refuses before any context is built")
    func pruneRefusesBeforeContextConstruction() async throws {
        let key = "RESTIC_STATION_DATA_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs-containment-\(UUID().uuidString)", isDirectory: true)
        setenv(key, root.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.path),
            "precondition: the data directory does not exist yet"
        )

        var command = try RunSet.parse([
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
