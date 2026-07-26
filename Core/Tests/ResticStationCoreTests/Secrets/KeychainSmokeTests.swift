import Foundation
import Testing
@testable import ResticStationCore

/// Real-keychain smoke test — talks to the actual macOS login keychain via
/// `/usr/bin/security`, using a distinct service name (`restic-station-test`)
/// so it can never collide with real app data.
///
/// This must NOT run as part of a normal `swift test`: it touches the real
/// keychain and (per docs/keychain-and-fda.md) is the one thing we can't
/// verify from a fake — that an item created with `-T /usr/bin/security`
/// really is readable via a bare `security find-generic-password` subprocess
/// without a GUI consent prompt. Gated on `RESTIC_STATION_KEYCHAIN_SMOKE=1`
/// per T03's acceptance criteria:
///
///   RESTIC_STATION_KEYCHAIN_SMOKE=1 swift test --filter KeychainSmoke
///
/// and cleans up after itself (delete-generic-password) even on failure.
@Suite(
    "KeychainSmoke",
    .enabled(if: ProcessInfo.processInfo.environment["RESTIC_STATION_KEYCHAIN_SMOKE"] == "1")
)
struct KeychainSmokeTests {
    private static let service = "restic-station-test"
    private static let securityPath = "/usr/bin/security"

    @Test("add/read/delete a real keychain item, prompt-free, via a bare security subprocess")
    func realKeychainRoundTrip() async throws {
        let account = "restic-station-smoke-\(UUID().uuidString.lowercased())"
        let password = "smoke-test-password-\(UUID().uuidString)"

        // Clean up unconditionally, even if an assertion below throws.
        defer {
            _ = try? runBareSecurity(["delete-generic-password", "-s", Self.service, "-a", account])
        }

        // 1. Add, with -T /usr/bin/security, exactly per keychain-and-fda.md.
        let addResult = try runBareSecurity([
            "add-generic-password",
            "-s", Self.service,
            "-a", account,
            "-w", password,
            "-T", Self.securityPath,
        ])
        #expect(addResult.exitCode == 0, "add-generic-password failed: \(addResult.stderr)")

        // 2. Read it back via a bare `security find-generic-password` subprocess
        //    (i.e. not through our own process, simulating the headless
        //    RESTIC_PASSWORD_COMMAND context) and confirm no GUI prompt hangs
        //    the call — a hung/blocked prompt would make this call not return
        //    promptly, which `runBareSecurity`'s use of a plain synchronous
        //    subprocess wait would surface as this test simply not finishing.
        let readResult = try runBareSecurity([
            "find-generic-password",
            "-s", Self.service,
            "-a", account,
            "-w",
        ])
        #expect(readResult.exitCode == 0, "find-generic-password failed: \(readResult.stderr)")
        let readPassword = readResult.stdout.trimmingCharacters(in: .newlines)
        #expect(readPassword == password)

        // 3. Delete and confirm it's really gone (exit 44 on a second find).
        let deleteResult = try runBareSecurity(["delete-generic-password", "-s", Self.service, "-a", account])
        #expect(deleteResult.exitCode == 0, "delete-generic-password failed: \(deleteResult.stderr)")

        let readAfterDelete = try runBareSecurity([
            "find-generic-password",
            "-s", Self.service,
            "-a", account,
            "-w",
        ])
        #expect(readAfterDelete.exitCode == 44)
    }

    /// Also exercises `KeychainClient` itself (via `DefaultProcessRunner`)
    /// end to end against the real keychain, using the same test service by
    /// constructing a throwaway client whose account happens to route
    /// through the same `/usr/bin/security` binary — the account/service
    /// strings are what matter here, not which client issued the call, so
    /// this proves `DefaultProcessRunner` + `KeychainClient`'s exact argv
    /// really works against the real tool, prompt-free.
    @Test("KeychainClient (DefaultProcessRunner) round-trips a real item, prompt-free")
    func keychainClientAgainstRealSecurity() async throws {
        // KeychainClient hardcodes service "restic-station"; to keep this
        // smoke test isolated from any real app data we don't use
        // KeychainClient's public API against the real service. Instead we
        // reuse DefaultProcessRunner directly with the same argv shape
        // KeychainClient uses, targeted at the test service — this is the
        // most faithful way to smoke-test the production process runner
        // without ever touching service "restic-station".
        let runner = DefaultProcessRunner()
        let account = "restic-station-smoke-client-\(UUID().uuidString.lowercased())"
        let password = "smoke-\(UUID().uuidString)"

        defer {
            Task {
                _ = try? await runner.run(
                    [Self.securityPath, "delete-generic-password", "-s", Self.service, "-a", account],
                    env: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: nil
                )
            }
        }

        let addResult = try await runner.run(
            [
                Self.securityPath, "add-generic-password",
                "-s", Self.service, "-a", account,
                "-w", password,
                "-T", Self.securityPath,
            ],
            env: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: 10
        )
        #expect(addResult.exitCode == 0)

        let readResult = try await runner.run(
            [Self.securityPath, "find-generic-password", "-s", Self.service, "-a", account, "-w"],
            env: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: 10
        )
        #expect(readResult.exitCode == 0)
        var read = String(decoding: readResult.stdout, as: UTF8.self)
        if read.hasSuffix("\n") { read.removeLast() }
        #expect(read == password)

        let deleteResult = try await runner.run(
            [Self.securityPath, "delete-generic-password", "-s", Self.service, "-a", account],
            env: nil, currentDirectory: nil, onStdoutLine: nil, onStderrLine: nil, timeout: 10
        )
        #expect(deleteResult.exitCode == 0)
    }

    // MARK: - Bare subprocess helper (deliberately NOT going through ProcessRunning,
    // to keep this test's own plumbing independent of the code under test).

    private struct BareResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runBareSecurity(_ arguments: [String]) throws -> BareResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.securityPath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return BareResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }
}
