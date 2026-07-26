import Foundation
import Testing
@testable import ResticStationCore

/// Real-restic smoke test — the manual verification T04's acceptance
/// criteria call for: `.version` and a real `backup` against a throwaway
/// local repository, driven by the production `DefaultProcessRunner` and a
/// real login-keychain item (so `RESTIC_PASSWORD_COMMAND` is exercised end
/// to end, prompt-free, exactly as a scheduled run would).
///
/// This must NOT run as part of a normal `swift test`: it needs a real
/// restic binary and touches the real keychain. Gated on
/// `RESTIC_STATION_RESTIC_SMOKE=1`:
///
///   RESTIC_STATION_RESTIC_SMOKE=1 \
///     RESTIC_STATION_SMOKE_RESTIC=/opt/homebrew/bin/restic \
///     swift test --package-path Core --filter ResticRunnerSmoke
///
/// The keychain item uses the production service (`restic-station`) with a
/// random throwaway destination UUID as the account, and is deleted in a
/// `defer` even if an assertion fails.
@Suite(
    "ResticRunnerSmoke",
    .enabled(if: ProcessInfo.processInfo.environment["RESTIC_STATION_RESTIC_SMOKE"] == "1")
)
struct ResticRunnerSmokeTests {
    private static var resticPath: String {
        ProcessInfo.processInfo.environment["RESTIC_STATION_SMOKE_RESTIC"] ?? "/opt/homebrew/bin/restic"
    }

    @Test("version, init, backup and snapshots against a throwaway local repo")
    func realResticRoundTrip() async throws {
        let processRunner = DefaultProcessRunner()
        let keychain = KeychainClient(runner: processRunner)

        let destinationId = UUID()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-station-smoke-\(UUID().uuidString)", isDirectory: true)
        let repo = scratch.appendingPathComponent("repo", isDirectory: true)
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("hello restic\n".utf8).write(to: source.appendingPathComponent("file.txt"))

        defer {
            try? FileManager.default.removeItem(at: scratch)
        }
        // Clean up the keychain item no matter how this test ends (same
        // pattern as KeychainSmokeTests: `defer` cannot await).
        defer {
            Task {
                try? await keychain.deletePassword(destId: destinationId)
            }
        }

        try await keychain.setPassword("smoke-\(UUID().uuidString)", destId: destinationId)

        let destination = Destination(
            id: destinationId,
            label: "Smoke",
            repoURL: repo.path,
            isPrimary: true
        )
        let runner = ResticRunner(
            resticPath: Self.resticPath,
            paths: AppPaths(root: scratch.appendingPathComponent("data", isDirectory: true)),
            keychain: keychain,
            runner: processRunner
        )
        let invocation = ResticInvocation(destination: destination)

        // 1. version (no repository, no keychain).
        let version = try await runner.runWithoutRepository(.version, timeout: 30)
        #expect(version.status == .success)
        let versionInfo = try makeResticJSONDecoder().decode(
            VersionInfo.self,
            from: Data(version.rawOutput.utf8)
        )
        #expect(versionInfo.version.hasPrefix("0."))

        // 2. init.
        let initOutcome = try await runner.run(.initRepo(repo: repo.path), for: invocation, timeout: 60)
        #expect(initOutcome.status == .success, "init failed: \(initOutcome.rawOutput)")

        // 3. backup — streams NDJSON and ends with a summary carrying a snapshot id.
        var summarySnapshotId: String?
        let backup = try await runner.run(
            .backup(repo: repo.path, sources: [source.path]),
            for: invocation,
            timeout: 120
        )
        #expect(backup.status == .success, "backup failed: \(backup.rawOutput)")
        for message in backup.messages {
            if case .summary(let summary) = message {
                summarySnapshotId = summary.snapshotId
            }
        }
        #expect(summarySnapshotId != nil)

        // 4. snapshots — exactly one snapshot, matching the backup summary.
        let snapshots = try await runner.run(.snapshots(repo: repo.path), for: invocation, timeout: 60)
        #expect(snapshots.status == .success)
        let decoded = try makeResticJSONDecoder().decode([Snapshot].self, from: Data(snapshots.rawOutput.utf8))
        #expect(decoded.count == 1)
        #expect(decoded.first?.id == summarySnapshotId)

        try await keychain.deletePassword(destId: destinationId)
    }
}
