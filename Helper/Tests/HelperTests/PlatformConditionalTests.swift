import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// T25: the two macOS-specific behaviours the helper used to assume were
/// universal — the Full Disk Access probe and "the app will configure restic
/// for you" — are now platform-conditional. These tests run on both
/// platforms and assert whichever half applies.

// MARK: - fda-check

@Suite struct FdaCheckPlatformTests {

    /// A temp `AppPaths` so the probe (on macOS) writes somewhere disposable
    /// rather than into the developer's real Application Support directory.
    private func makeTempPaths() throws -> (AppPaths, () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fda-check-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(root: root)
        try paths.ensureDirectories()
        return (paths, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("fda-check writes state/fda-check.json on macOS and nothing elsewhere")
    func probeAndRecordIsPlatformConditional() throws {
        let (paths, cleanup) = try makeTempPaths()
        defer { cleanup() }

        let result = FdaCheck.probeAndRecord(context: "unit-test", stateStore: StateStore(paths: paths))
        let fileExists = FileManager.default.fileExists(atPath: paths.fdaCheckFile.path)

        #if os(macOS)
        // Unchanged behaviour: a record is produced and written, whatever the
        // verdict (a test process usually has no FDA, which is fine — the
        // schema and the write are what matter here).
        #expect(result != nil)
        #expect(result?.context == "unit-test")
        #expect(result?.probedPath == "~/Library/Safari" || result?.probedPath == "~/Library/Mail")
        #expect(fileExists)
        // Field-wise, not whole-struct: `checkedAt` round-trips through the
        // documented second-precision ISO-8601 encoding.
        let reread = StateStore(paths: paths).readFdaCheck()
        #expect(reread?.hasFullDiskAccess == result?.hasFullDiskAccess)
        #expect(reread?.probedPath == result?.probedPath)
        #expect(reread?.context == "unit-test")
        #else
        // On Linux there is no TCC. Writing a fake "granted" record would
        // make the file's meaning platform-dependent, so nothing is written
        // at all.
        #expect(result == nil)
        #expect(fileExists == false)
        #endif
    }

    @Test("fda-check stays registered on every platform, so scripts are uniform")
    func fdaCheckIsStillASubcommand() {
        let names: [String?] = HelperMain.configuration.subcommands.map { subcommand in
            subcommand.configuration.commandName
        }
        #expect(names.contains("fda-check"))
    }
}

// MARK: - restic path resolution

@Suite struct ResticPathResolutionTests {

    /// `ProcessRunning` double that reports a usable restic for one specific
    /// path and refuses to launch anything else.
    private final class OneGoodBinary: ProcessRunning, @unchecked Sendable {
        let goodPath: String
        init(goodPath: String) { self.goodPath = goodPath }

        func run(
            _ argv: [String],
            env: [String: String]?,
            currentDirectory: String?,
            onStdoutLine: (@Sendable (String) -> Void)?,
            onStderrLine: (@Sendable (String) -> Void)?,
            timeout: TimeInterval?
        ) async throws -> ProcessResult {
            guard argv.first == goodPath else {
                throw ProcessRunnerError.launchFailed("not restic")
            }
            let json = #"{"version":"0.18.1","go_version":"go1.22.0","go_os":"linux","go_arch":"arm64"}"#
            return ProcessResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data())
        }
    }

    private func makeFakeRestic() throws -> (path: String, cleanup: () -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("restic-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (binary.path, { try? FileManager.default.removeItem(at: dir) })
    }

    /// The resolver takes a `ResolvedConfig` (T24), so every case below goes
    /// through the same machine-resolution step the helper does. `test-host`
    /// has no overrides in any of these configs, so resolution is the
    /// identity on the sets — only `resticPath` is affected.
    private func resolve(config: AppConfig, machine: MachineConfig? = nil) -> ResolvedConfig {
        config.resolved(for: machine ?? MachineConfig(machineId: "test-host"))
    }

    @Test("machine.json's resticPath wins over the deprecated config.json one")
    func machinePathWinsOverConfigPath() async throws {
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(
                config: AppConfig(resticPath: "/opt/homebrew/bin/restic"),
                machine: MachineConfig(machineId: "linux-nas", resticPath: "/usr/bin/restic")
            ),
            log: { _ in Issue.record("nothing should be logged when a path is already configured") }
        )
        #expect(resolved.path == "/usr/bin/restic")
    }

    @Test("an empty machine.json resticPath falls back to the config.json one")
    func emptyMachinePathFallsBackToConfigPath() async throws {
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(
                config: AppConfig(resticPath: "/opt/homebrew/bin/restic"),
                machine: MachineConfig(machineId: "linux-nas", resticPath: "")
            ),
            log: { _ in Issue.record("nothing should be logged when a path is already configured") }
        )
        #expect(resolved.path == "/opt/homebrew/bin/restic")
    }

    @Test("a configured resticPath wins without running discovery at all")
    func configuredPathWins() async throws {
        let fake = try makeFakeRestic()
        defer { fake.cleanup() }

        // Discovery is pointed at a binary that *would* be found, to prove
        // the configured value short-circuits it.
        let discovery = ResticDiscovery(
            wellKnownPaths: [fake.path],
            environment: [:],
            runner: OneGoodBinary(goodPath: fake.path)
        )
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(config: AppConfig(resticPath: "/configured/restic")),
            discovery: discovery,
            log: { _ in Issue.record("nothing should be logged when config already has a path") }
        )
        #expect(resolved.path == "/configured/restic")
    }

    @Test("with nothing configured, a discoverable binary is used and logged once")
    func discoveryFillsInForAnUnconfiguredHost() async throws {
        let fake = try makeFakeRestic()
        defer { fake.cleanup() }

        let discovery = ResticDiscovery(
            wellKnownPaths: [fake.path],
            environment: [:],
            runner: OneGoodBinary(goodPath: fake.path)
        )
        let logged = LogSink()
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(config: AppConfig(resticPath: nil)),
            discovery: discovery,
            log: { logged.append($0) }
        )
        #expect(resolved.path == fake.path)
        #expect(logged.messages.count == 1)
        #expect(logged.messages.first?.contains(fake.path) == true)
    }

    @Test("an empty configured path is treated as unset")
    func emptyConfiguredPathFallsThroughToDiscovery() async throws {
        let fake = try makeFakeRestic()
        defer { fake.cleanup() }

        let discovery = ResticDiscovery(
            wellKnownPaths: [fake.path],
            environment: [:],
            runner: OneGoodBinary(goodPath: fake.path)
        )
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(config: AppConfig(resticPath: "")),
            discovery: discovery,
            log: { _ in }
        )
        #expect(resolved.path == fake.path)
    }

    @Test("nothing configured and nothing discoverable resolves to nil")
    func nothingAnywhereResolvesToNil() async throws {
        let fake = try makeFakeRestic()
        defer { fake.cleanup() }

        // The candidate exists and is +x, but does not run.
        let discovery = ResticDiscovery(
            wellKnownPaths: [fake.path],
            environment: [:],
            runner: OneGoodBinary(goodPath: "/nowhere/restic")
        )
        let resolved = await HelperContext.resolveResticPath(
            resolved: resolve(config: AppConfig(resticPath: nil)),
            discovery: discovery,
            log: { _ in Issue.record("nothing should be logged when nothing was found") }
        )
        #expect(resolved.path == nil)
    }

    // MARK: - The three ways restic can be unusable (issue #50)

    private var testPaths: AppPaths {
        AppPaths(root: URL(fileURLWithPath: "/tmp/restic-station-test", isDirectory: true))
    }

    @Test("nothing found anywhere: say what was searched, and where to get a usable restic")
    func notFoundMessageIsPlatformAppropriate() {
        let paths = testPaths
        let message = HelperContext.resticNotFoundMessage(
            paths: paths,
            result: ResticDiscoveryResult(chosen: nil, rejected: [])
        )

        #if os(macOS)
        // The T10 wording, verbatim — on macOS there really is an app to open,
        // and its Settings pane renders the richer cases itself.
        #expect(message == "restic not configured — open Restic Station")
        #else
        // Headless: name what was searched and how to fix it.
        #expect(message.contains("/usr/bin/restic"))
        #expect(message.contains("/opt/restic/bin/restic"))
        #expect(message.contains("every directory on PATH"))
        #expect(message.contains("Install an official release binary"))
        // machine.json, not config.json: the binary path is per-machine (T24).
        #expect(message.contains(paths.machineFile.path))
        #expect(!message.contains(paths.configFile.path))
        #expect(!message.contains("open Restic Station"))
        #endif
    }

    /// The headline bug. Following `apt install restic` on Ubuntu 24.04 gets
    /// you 0.16.4, below the 0.17.0 floor — so the old message's own remedy
    /// reproduced the old message, with a working restic on `PATH`.
    @Test("a too-old restic is named, with its version and the minimum — on every platform")
    func tooOldMessageNamesTheBinaryAndVersion() {
        let paths = testPaths
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(path: "/usr/bin/restic", outcome: .tooOld(version: "0.16.4"))]
        )
        let message = HelperContext.resticNotFoundMessage(paths: paths, result: result)

        #expect(message.contains("0.16.4"))
        #expect(message.contains("/usr/bin/restic"))
        #expect(message.contains(ResticDiscovery.minimumVersion))
        #expect(message.contains("too old"))
        // "not found" is exactly the wrong description of a binary that was
        // found, ran, and reported its version.
        #expect(!message.contains("not found"))
        // The circular advice, gone. This is the assertion the whole issue
        // is about: a package manager that ships below the floor must not be
        // the recommendation.
        #expect(!message.contains("apt install"))
        #expect(!message.contains("dnf install"))
        #expect(message.contains("github.com/restic/restic/releases"))
    }

    /// `ResticDiscovery`'s own doc comment says unusable candidates are
    /// recorded so that "found something, couldn't run it" is never silent.
    /// It was silent here: the helper collapsed it into "not found".
    @Test("a found-but-unrunnable candidate reports the reason, not 'not found'")
    func unusableMessageCarriesTheReason() {
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [ResticProbe(
                path: "/opt/homebrew/bin/restic",
                outcome: .unusable(reason: "/opt/homebrew/bin/restic exited 72 when asked for its version.")
            )]
        )
        let message = HelperContext.resticNotFoundMessage(paths: testPaths, result: result)

        #expect(message.contains("/opt/homebrew/bin/restic"))
        #expect(message.contains("exited 72"))
        #expect(!message.contains("not found"))
    }

    /// Candidates are probed in preference order, so a too-old binary in a
    /// well-known location is the one the user thinks of as "their" restic —
    /// it must win over an unrelated unusable candidate found later.
    @Test("too-old outranks unusable when both were found")
    func tooOldOutranksUnusable() {
        let result = ResticDiscoveryResult(
            chosen: nil,
            rejected: [
                ResticProbe(path: "/broken/restic", outcome: .unusable(reason: "could not be run.")),
                ResticProbe(path: "/usr/bin/restic", outcome: .tooOld(version: "0.16.4")),
            ]
        )
        let message = HelperContext.resticNotFoundMessage(paths: testPaths, result: result)

        #expect(message.contains("0.16.4"))
        #expect(message.contains("/usr/bin/restic"))
        #expect(!message.contains("/broken/restic"))
    }
}

/// Collects the info-level lines `resolveResticPath` emits.
private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }
}
