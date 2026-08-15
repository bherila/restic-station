#if os(Linux)

import Foundation
import Testing

import ResticStationCore
@testable import restic_station_helper

/// T26 — the systemd `--user` timer that fires `tick` on Linux.
///
/// Everything a live systemd would otherwise be needed for is reachable here:
/// `SystemdTimerManager` takes its unit directory, its `systemctl`/`loginctl`
/// paths and its `ProcessRunning` as plain injected values, so these tests
/// drive the real install/uninstall/status code against a temp directory and
/// a scripted runner. What is *not* covered here — and cannot be, from a
/// test process — is systemd actually firing the timer; that needs a live
/// host (see the PR for #28).

// MARK: - Test doubles

/// The Helper target's twin of Core's `FakeProcessRunner`. Duplicated rather
/// than shared because SwiftPM test targets cannot import each other's
/// sources, and moving the double into a product would ship test scaffolding
/// in the helper binary.
///
/// Records every argv in order and answers through `respond`, so a test can
/// both assert the exact `systemctl` sequence and script what each call
/// reported.
final class ScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [[String]] = []
    private let respond: @Sendable ([String]) -> ProcessResult

    init(respond: @escaping @Sendable ([String]) -> ProcessResult = { _ in .ok() }) {
        self.respond = respond
    }

    var invocations: [[String]] {
        withLock { _invocations }
    }

    /// The invocations with the executable path stripped, which is what the
    /// argv assertions actually care about.
    var arguments: [[String]] {
        invocations.map { Array($0.dropFirst()) }
    }

    func run(
        _ argv: [String],
        env: [String: String]?,
        currentDirectory: String?,
        onStdoutLine: (@Sendable (String) -> Void)?,
        onStderrLine: (@Sendable (String) -> Void)?,
        timeout: TimeInterval?
    ) async throws -> ProcessResult {
        withLock { _invocations.append(argv) }
        return respond(argv)
    }

    /// `NSLock.lock()` is unavailable from an async context; keeping the
    /// critical section inside a synchronous closure is how Core's
    /// `FakeProcessRunner` does the same thing.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension ProcessResult {
    static func ok(_ stdout: String = "") -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
    }

    static func failing(_ exitCode: Int32, stdout: String = "", stderr: String = "") -> ProcessResult {
        ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }
}

/// Collects the lines a manager operation prints.
final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        _lines.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - Fixtures

private let systemctl = "/usr/bin/systemctl"
private let loginctl = "/usr/bin/loginctl"
private let helperPath = "/opt/restic-station/bin/restic-station-helper"

private func makeTempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A manager pointed at a scratch unit directory. `lingerMarkerDirectory`
/// defaults to a path that does not exist, i.e. "cannot tell" — tests that
/// care about lingering set it or script `loginctl` explicitly.
private func makeManager(
    unitDirectory: URL,
    runner: ProcessRunning,
    systemctlPath: String? = systemctl,
    loginctlPath: String? = loginctl,
    lingerMarkerDirectory: URL = URL(fileURLWithPath: "/nonexistent/linger", isDirectory: true)
) -> SystemdTimerManager {
    SystemdTimerManager(
        unitDirectory: unitDirectory,
        runner: runner,
        systemctlPath: systemctlPath,
        loginctlPath: loginctlPath,
        userName: "ben",
        lingerMarkerDirectory: lingerMarkerDirectory
    )
}

private func lingerResponder(_ value: String) -> @Sendable ([String]) -> ProcessResult {
    { argv in
        argv.first == loginctl ? .ok("Linger=\(value)\n") : .ok()
    }
}

// MARK: - install

@Suite struct SystemdTimerInstallTests {

    @Test("install writes both units and enables the timer, in that order")
    func installHappyPath() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: lingerResponder("yes"))
        let log = LineSink()

        try await makeManager(unitDirectory: unitDirectory, runner: runner).install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: nil,
            log: { log.append($0) }
        )

        // Exact sequence. daemon-reload must precede enable, and restart
        // must follow it: `enable --now` does not refresh an active timer.
        #expect(runner.invocations == [
            [systemctl, "--user", "daemon-reload"],
            [systemctl, "--user", "enable", "--now", "restic-station.timer"],
            [systemctl, "--user", "restart", "restic-station.timer"],
            [loginctl, "show-user", "ben", "--property=Linger"],
        ])

        let service = try String(
            contentsOf: unitDirectory.appendingPathComponent("restic-station.service"),
            encoding: .utf8
        )
        let timer = try String(
            contentsOf: unitDirectory.appendingPathComponent("restic-station.timer"),
            encoding: .utf8
        )
        #expect(service.contains("ExecStart=\(helperPath) tick"))
        #expect(timer.contains("OnUnitActiveSec=2min"))
        #expect(timer.contains("Persistent=true"))
        #expect(log.text.contains("enabled restic-station.timer"))
    }

    @Test("unit files are written 0644 — a unit is not a secret and must not look like one")
    func unitPermissions() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }

        try await makeManager(unitDirectory: unitDirectory, runner: ScriptedProcessRunner()).install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: nil,
            log: { _ in }
        )

        for name in ["restic-station.service", "restic-station.timer"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: unitDirectory.appendingPathComponent(name).path
            )
            #expect(attributes[.posixPermissions] as? NSNumber == 0o644)
        }
    }

    @Test("install creates the unit directory when it does not exist yet")
    func createsUnitDirectory() async throws {
        let parent = try makeTempDirectory("xdg")
        defer { try? FileManager.default.removeItem(at: parent) }
        let unitDirectory = parent
            .appendingPathComponent("systemd", isDirectory: true)
            .appendingPathComponent("user", isDirectory: true)

        try await makeManager(unitDirectory: unitDirectory, runner: ScriptedProcessRunner()).install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: nil,
            log: { _ in }
        )
        #expect(FileManager.default.fileExists(atPath: unitDirectory.appendingPathComponent("restic-station.timer").path))
    }

    /// The acceptance criterion "`timer install` is idempotent": re-running
    /// updates in place. Nothing accumulates, and the second run is the same
    /// four calls, not a different repair path. Restarting every time is
    /// essential: `enable --now` leaves an already-active timer untouched.
    @Test("re-running updates the units in place and duplicates nothing")
    func installIsIdempotent() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: lingerResponder("yes"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)

        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })
        try await manager.install(helperPath: helperPath, intervalMinutes: 15, dataDirectory: nil, log: { _ in })

        let expectedOnce: [[String]] = [
            ["--user", "daemon-reload"],
            ["--user", "enable", "--now", "restic-station.timer"],
            ["--user", "restart", "restic-station.timer"],
            ["show-user", "ben", "--property=Linger"],
        ]
        #expect(runner.arguments == expectedOnce + expectedOnce)

        // Exactly two files, and the second run's interval won.
        let contents = try FileManager.default.contentsOfDirectory(atPath: unitDirectory.path).sorted()
        #expect(contents == ["restic-station.service", "restic-station.timer"])
        let timer = try String(
            contentsOf: unitDirectory.appendingPathComponent("restic-station.timer"),
            encoding: .utf8
        )
        #expect(timer.contains("OnUnitActiveSec=15min"))
        #expect(!timer.contains("OnUnitActiveSec=2min"))
    }

    @Test("RESTIC_STATION_DATA_DIR is carried into the unit when the caller overrode it")
    func dataDirectoryIsBakedIn() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }

        try await makeManager(unitDirectory: unitDirectory, runner: ScriptedProcessRunner()).install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: "/srv/restic-station",
            log: { _ in }
        )
        let service = try String(
            contentsOf: unitDirectory.appendingPathComponent("restic-station.service"),
            encoding: .utf8
        )
        #expect(service.contains("Environment=\"RESTIC_STATION_DATA_DIR=/srv/restic-station\""))
    }

    /// "Detect its absence and fail with a clear message pointing at the cron
    /// fallback, rather than emitting a confusing `systemctl: command not
    /// found`."
    @Test("no systemd: an actionable error naming the cron fallback, and nothing written")
    func systemdAbsent() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner()

        await #expect(throws: SystemdTimerError.self) {
            try await makeManager(unitDirectory: unitDirectory, runner: runner, systemctlPath: nil).install(
                helperPath: helperPath,
                intervalMinutes: 2,
                dataDirectory: nil,
                log: { _ in }
            )
        }

        do {
            try await makeManager(unitDirectory: unitDirectory, runner: runner, systemctlPath: nil).install(
                helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in }
            )
            Issue.record("expected the install to fail without systemd")
        } catch let error as SystemdTimerError {
            let message = error.description
            #expect(message.contains("systemd is not available"))
            #expect(message.contains("*/2 * * * * \(helperPath) tick"))
            #expect(message.contains("crontab -e"))
            // The one behavioural difference the docs promise to name.
            #expect(message.contains("schedule-state.json"))
            #expect(!message.contains("command not found"))
        }

        // No orphan units on a host that will never act on them, and nothing
        // was spawned.
        #expect(try FileManager.default.contentsOfDirectory(atPath: unitDirectory.path).isEmpty)
        #expect(runner.invocations.isEmpty)
    }

    @Test("a failing systemctl surfaces the command, its exit code and its stderr")
    func systemctlFailureIsReported() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner { argv in
            argv.contains("daemon-reload")
                ? .failing(1, stderr: "Failed to connect to bus: No medium found")
                : .ok()
        }

        do {
            try await makeManager(unitDirectory: unitDirectory, runner: runner).install(
                helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in }
            )
            Issue.record("expected a commandFailed error")
        } catch let error as SystemdTimerError {
            let message = error.description
            #expect(message.contains("daemon-reload"))
            #expect(message.contains("exit 1"))
            // "Failed to connect to bus" explains nothing on its own; the
            // sudo/su cause is by far the most common and is spelled out.
            #expect(message.contains("systemd user manager"))
            #expect(message.contains("machinectl shell"))
        }
    }
}

// MARK: - Lingering

@Suite struct SystemdTimerLingerTests {

    @Test("linger disabled: a prominent warning with the exact fix, never run for the user")
    func warnsWhenLingerDisabled() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: lingerResponder("no"))
        let log = LineSink()

        try await makeManager(unitDirectory: unitDirectory, runner: runner).install(
            helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { log.append($0) }
        )

        #expect(log.text.contains("WARNING: lingering is disabled for ben"))
        #expect(log.text.contains("sudo loginctl enable-linger ben"))
        // The whole point: it is printed, not executed. `enable-linger`
        // needs root and must never be run behind the user's back.
        #expect(!runner.arguments.contains { $0.contains("enable-linger") })
    }

    @Test("linger enabled: no warning at all")
    func silentWhenLingerEnabled() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let log = LineSink()

        try await makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: lingerResponder("yes"))
        ).install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { log.append($0) })

        #expect(!log.text.contains("WARNING"))
        #expect(!log.text.contains("enable-linger"))
    }

    /// `loginctl show-user` fails outright for a user with no current
    /// session — exactly the headless case the warning exists for — so the
    /// marker file `enable-linger` actually creates is the fallback.
    @Test("loginctl unavailable: the /var/lib/systemd/linger marker decides")
    func lingerMarkerFallback() async throws {
        let unitDirectory = try makeTempDirectory("units")
        let markerDirectory = try makeTempDirectory("linger")
        defer {
            try? FileManager.default.removeItem(at: unitDirectory)
            try? FileManager.default.removeItem(at: markerDirectory)
        }

        let disabled = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(),
            loginctlPath: nil,
            lingerMarkerDirectory: markerDirectory
        )
        #expect(await disabled.lingerState() == .disabled)

        try Data().write(to: markerDirectory.appendingPathComponent("ben"))
        #expect(await disabled.lingerState() == .enabled)
    }

    @Test("neither loginctl nor a readable marker directory: unknown, not a false all-clear")
    func lingerUnknown() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner { _ in .failing(1, stderr: "Failed to get user") },
            loginctlPath: nil
        )
        #expect(await manager.lingerState() == .unknown)
    }
}

// MARK: - uninstall

@Suite struct SystemdTimerUninstallTests {

    @Test("nothing installed: exit 0, say so, and run no systemctl at all")
    func uninstallWhenNothingInstalled() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner()
        let log = LineSink()

        try await makeManager(unitDirectory: unitDirectory, runner: runner)
            .uninstall(log: { log.append($0) })

        #expect(runner.invocations.isEmpty)
        #expect(log.text.contains("nothing to uninstall"))
    }

    @Test("installed: disable --now, remove both units, then daemon-reload")
    func uninstallRemovesEverything() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: lingerResponder("yes"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        try await manager.uninstall(log: { log.append($0) })

        // Disable happens while the unit files still exist — `systemctl
        // disable` reads the unit to find the symlinks it must remove.
        #expect(runner.arguments.suffix(2) == [
            ["--user", "disable", "--now", "restic-station.timer"],
            ["--user", "daemon-reload"],
        ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: unitDirectory.path).isEmpty)
        #expect(log.text.contains("no longer scheduled"))
    }

    /// A masked/already-disabled unit makes `systemctl disable` exit
    /// non-zero. Leaving the files behind because of that would leave the
    /// host still ticking, which is the opposite of what was asked for.
    @Test("a failing disable is reported but still removes the units")
    func uninstallToleratesDisableFailure() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner { argv in
            argv.contains("disable") ? .failing(1, stderr: "Unit restic-station.timer does not exist") : .ok()
        }
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        try await manager.uninstall(log: { log.append($0) })

        #expect(log.text.contains("warning:"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: unitDirectory.path).isEmpty)
    }

    @Test("uninstall is idempotent: a second run is a clean no-op")
    func uninstallTwice() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: lingerResponder("yes"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        try await manager.uninstall(log: { _ in })
        let countAfterFirst = runner.invocations.count
        try await manager.uninstall(log: { _ in })
        #expect(runner.invocations.count == countAfterFirst)
    }
}

// MARK: - status

@Suite struct SystemdTimerStatusTests {

    private func statusResponder(
        enabled: String,
        active: String,
        linger: String = "yes"
    ) -> @Sendable ([String]) -> ProcessResult {
        { argv in
            if argv.first == loginctl { return .ok("Linger=\(linger)\n") }
            if argv.contains("is-enabled") { return .ok(enabled + "\n") }
            if argv.contains("is-active") { return .ok(active + "\n") }
            if argv.contains("list-timers") {
                return .ok("""
                    NEXT                        LEFT     LAST                        PASSED  UNIT                  ACTIVATES
                    Wed 2026-08-05 12:34:00 UTC 1min 3s  Wed 2026-08-05 12:32:00 UTC 57s ago restic-station.timer  restic-station.service
                    """)
            }
            return .ok()
        }
    }

    @Test("a healthy timer reports enabled/active/next firing and exits truthy")
    func healthyStatus() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(
            activity: TimerActivity(lines: ["\"Docs\": backup just now"]),
            log: { log.append($0) }
        )

        #expect(health.isHealthy)
        #expect(health.exitCode == 0)
        let text = log.text
        #expect(text.contains("units       installed in \(unitDirectory.path)"))
        // Read back from the installed file, not assumed from this build's
        // default — status must report what is actually scheduled.
        #expect(text.contains("interval    every 2min"))
        #expect(text.contains("enabled     enabled"))
        #expect(text.contains("active      active"))
        #expect(text.contains("linger      enabled"))
        #expect(text.contains("next firing"))
        #expect(text.contains("restic-station.timer  restic-station.service"))
        #expect(text.contains("\"Docs\": backup just now"))
    }

    @Test("status reports the interval that is installed, not this build's default")
    func statusReportsInstalledInterval() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 30, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        _ = await manager.status(activity: TimerActivity(lines: []), log: { log.append($0) })
        #expect(log.text.contains("interval    every 30min"))
    }

    @Test("a disabled timer is not healthy, and the linger fix is on screen")
    func disabledStatus() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(
                respond: statusResponder(enabled: "disabled", active: "inactive", linger: "no")
            )
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(!health.isHealthy)
        #expect(health.problems == [.notEnabled, .notActive, .lingerDisabled])
        #expect(log.text.contains("linger      DISABLED"))
        #expect(log.text.contains("sudo loginctl enable-linger ben"))
    }

    @Test("nothing installed: not healthy, and it says how to install")
    func notInstalledStatus() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let log = LineSink()

        let health = await makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "disabled", active: "inactive"))
        ).status(activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(!health.isHealthy)
        #expect(health.problems.contains(.unitsMissing))
        #expect(log.text.contains("not installed"))
        #expect(log.text.contains("restic-station-helper timer install"))
    }

    /// A half-deleted install is not something `timer install` can produce,
    /// and systemd will refuse to start the timer. Reporting "installed"
    /// would be the most misleading possible answer.
    @Test("one unit deleted by hand is reported as INCOMPLETE, not as installed")
    func incompleteStatus() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })
        try FileManager.default.removeItem(at: unitDirectory.appendingPathComponent("restic-station.service"))

        let log = LineSink()
        let health = await manager.status(activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(!health.isHealthy)
        #expect(health.problems.contains(.unitsIncomplete))
        #expect(log.text.contains("INCOMPLETE"))
        #expect(log.text.contains("restic-station.service: MISSING"))
    }

    @Test("no systemd: status explains the cron fallback instead of pretending")
    func statusWithoutSystemd() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner()
        let log = LineSink()

        let health = await makeManager(unitDirectory: unitDirectory, runner: runner, systemctlPath: nil)
            .status(helperPath: helperPath, activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(!health.isHealthy)
        #expect(health.problems == [.systemdUnavailable])
        #expect(log.text.contains("systemd     not available"))
        // The real binary path, so the line can be pasted straight into
        // `crontab -e` rather than edited first.
        #expect(log.text.contains("*/2 * * * * \(helperPath) tick"))
        #expect(log.text.contains("crontab -e"))
        #expect(runner.invocations.isEmpty)
    }

    // MARK: Reasons a green timer is not actually green (issue #46)

    /// The headline fix. A host whose units are installed, enabled and active
    /// looks perfect — right up until the SSH session that installed them
    /// ends, at which point systemd stops every one of that user's units and
    /// backups stop with nothing in any log. `timer status` used to exit 0 on
    /// exactly that host, and `docs/linux.md` had to ship a caveat telling
    /// readers not to trust its exit code.
    @Test("an enabled+active timer with lingering disabled is NOT healthy")
    func lingerDisabledFailsTheHealthCheck() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(
                respond: statusResponder(enabled: "enabled", active: "active", linger: "no")
            )
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(health.problems == [.lingerDisabled])
        #expect(health.exitCode == 1)
        // The verdict block is what makes the exit code legible to a human
        // who ran this by hand rather than from a monitoring script.
        #expect(log.text.contains("VERDICT     scheduled backups will NOT happen"))
        #expect(log.text.contains("lingering is disabled"))
    }

    /// The deliberate exception, and the reason it is one: `.unknown` means
    /// the question could not be asked (no `loginctl`, unreadable marker
    /// directory) — typically a container with no logind, which nobody logs
    /// out of. Failing there would make this check permanently red with no
    /// reachable fix.
    @Test("an unknown linger state does not fail the health check")
    func unknownLingerDoesNotFailTheHealthCheck() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let missingMarkerDirectory = unitDirectory.appendingPathComponent("no-linger-dir", isDirectory: true)
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active")),
            loginctlPath: nil,
            lingerMarkerDirectory: missingMarkerDirectory
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(activity: TimerActivity(lines: []), log: { log.append($0) })

        #expect(health.isHealthy)
        #expect(health.exitCode == 0)
        #expect(log.text.contains("linger      unknown"))
        #expect(log.text.contains("VERDICT     scheduled backups will happen"))
    }

    /// A config the tick cannot load means every tick exits 1. Reporting the
    /// timer green because the *unit* is fine is technically true and
    /// practically a lie.
    @Test("a problem found while reading the tick's state fails the health check")
    func activityProblemsFailTheHealthCheck() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(
            activity: TimerActivity(lines: ["could not load /x/config.json"], problems: [.configUnreadable]),
            log: { log.append($0) }
        )

        #expect(health.problems == [.configUnreadable])
        #expect(health.exitCode == 1)
        #expect(log.text.contains("every tick will fail"))
    }

    // MARK: The timer is global; the data directory is not (@codex review on #51)

    /// A `systemd --user` timer is one unit per user. Ask `status` about
    /// /srv/b while the installed timer ticks /srv/a and the unit is
    /// genuinely enabled and active — so "healthy" is true of the unit and
    /// false of the question that was asked.
    @Test("a timer installed for another data directory is not healthy for this one")
    func dataDirectoryMismatchIsNotHealthy() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: "/srv/a/restic-station",
            log: { _ in }
        )

        let log = LineSink()
        let health = await manager.status(
            dataDirectory: "/srv/b/restic-station",
            activity: TimerActivity(lines: []),
            log: { log.append($0) }
        )

        #expect(health.problems == [.dataDirectoryMismatch])
        #expect(log.text.contains("data dir    MISMATCH"))
        #expect(log.text.contains("/srv/a/restic-station"))
        #expect(log.text.contains("/srv/b/restic-station"))
    }

    @Test("the same data directory is healthy, and says which one is pinned")
    func matchingDataDirectoryIsHealthy() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: "/srv/a/restic-station",
            log: { _ in }
        )

        let log = LineSink()
        let health = await manager.status(
            dataDirectory: "/srv/a/restic-station",
            activity: TimerActivity(lines: []),
            log: { log.append($0) }
        )

        #expect(health.isHealthy)
        #expect(log.text.contains("data dir    /srv/a/restic-station (pinned in the unit)"))
    }

    /// A unit written by a build from before the data directory was pinned.
    /// It will re-derive the path from the user manager's environment, which
    /// is exactly the silent-stop issue #48 is about — so it is a finding,
    /// not a shrug.
    @Test("a unit that pins no data directory at all is reported, not assumed fine")
    func unpinnedDataDirectoryIsAProblem() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let log = LineSink()
        let health = await manager.status(
            dataDirectory: "/srv/a/restic-station",
            activity: TimerActivity(lines: []),
            log: { log.append($0) }
        )

        #expect(health.problems == [.dataDirectoryUnpinned])
        #expect(log.text.contains("the unit pins none"))
    }

    /// The escaping round-trips: `serviceUnit` writes `%%` for a literal `%`
    /// so systemd does not expand it, and reading the unit back has to undo
    /// that or every such host reports a permanent false mismatch.
    @Test("a percent sign survives the write/read round trip without a false mismatch")
    func percentInDataDirectoryRoundTrips() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let manager = makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        )
        try await manager.install(
            helperPath: helperPath,
            intervalMinutes: 2,
            dataDirectory: "/srv/100%full/state",
            log: { _ in }
        )

        #expect(SystemdTimerManager.installedDataDirectory(
            serviceUnitURL: unitDirectory.appendingPathComponent("restic-station.service")
        ) == "/srv/100%full/state")

        let health = await manager.status(
            dataDirectory: "/srv/100%full/state",
            activity: TimerActivity(lines: []),
            log: { _ in }
        )
        #expect(health.isHealthy)
    }

    /// `status --json` discards this method's log entirely, so `list-timers`
    /// — the slowest call and pure narrative — is waste there, and a wedged
    /// D-Bus turns waste into a stall in a command documented as cheap.
    @Test("verdictOnly skips the narrative list-timers call")
    func verdictOnlySkipsListTimers() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let before = runner.invocations.count
        let health = await manager.status(
            activity: TimerActivity(lines: []),
            verdictOnly: true,
            log: { _ in }
        )
        let issued = runner.invocations.dropFirst(before)

        #expect(!issued.contains { $0.contains("list-timers") })
        // The verdict itself is unaffected — the calls that decide it still run.
        #expect(issued.contains { $0.contains("is-enabled") })
        #expect(issued.contains { $0.contains("is-active") })
        // No `dataDirectory` was asked about, so the pinning check does not
        // apply and this host is simply healthy — skipping `list-timers`
        // must not change the verdict.
        #expect(health.isHealthy)
    }

    @Test("the full report still runs list-timers")
    func fullReportRunsListTimers() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let runner = ScriptedProcessRunner(respond: statusResponder(enabled: "enabled", active: "active"))
        let manager = makeManager(unitDirectory: unitDirectory, runner: runner)
        try await manager.install(helperPath: helperPath, intervalMinutes: 2, dataDirectory: nil, log: { _ in })

        let before = runner.invocations.count
        _ = await manager.status(activity: TimerActivity(lines: []), log: { _ in })
        #expect(runner.invocations.dropFirst(before).contains { $0.contains("list-timers") })
    }

    @Test("every reason is reported, not just the first")
    func allProblemsAreReported() async throws {
        let unitDirectory = try makeTempDirectory("units")
        defer { try? FileManager.default.removeItem(at: unitDirectory) }
        let log = LineSink()

        let health = await makeManager(
            unitDirectory: unitDirectory,
            runner: ScriptedProcessRunner(
                respond: statusResponder(enabled: "disabled", active: "inactive", linger: "no")
            )
        ).status(
            activity: TimerActivity(lines: [], problems: [.configUnreadable]),
            log: { log.append($0) }
        )

        // Fixing one of these would still leave the host not backing up; a
        // health check that stops at the first finding sends the reader round
        // the loop once per problem.
        #expect(health.problems == [.unitsMissing, .notEnabled, .notActive, .lingerDisabled, .configUnreadable])
        for problem in health.problems {
            #expect(log.text.contains(problem.summary))
        }
    }
}

// MARK: - timer status's view of the tick's own state

@Suite struct TimerStatusActivityTests {

    private func makePaths() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("restic-station-timer-activity-\(UUID().uuidString)"))
    }

    @Test("a host with nothing configured yet is not a broken host")
    func absentConfigIsNotAProblem() throws {
        let paths = makePaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // `timer install` before `config import` is the documented order in
        // docs/linux.md, so this state has to stay exit 0.
        let activity = TimerCommand.Status.activity(paths: paths)
        #expect(activity.problems.isEmpty)
        #expect(activity.lines.contains("no backup sets configured — the tick runs and exits immediately"))
    }

    /// The bug: `(try? load()) ?? AppConfig()` turned an unparseable
    /// `config.json` into a valid empty one, so `timer status` printed the
    /// same cheerful "no backup sets configured" as a fresh host and exited
    /// 0 — on a machine where every single tick was exiting 1 on that file.
    @Test("a config that will not load is reported, not silently read as an empty one")
    func unreadableConfigIsAProblem() throws {
        let paths = makePaths()
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try Data("{ this is not json".utf8).write(to: paths.configFile)

        let activity = TimerCommand.Status.activity(paths: paths)
        #expect(activity.problems == [.configUnreadable])
        // And it must not describe a stand-in empty config as if it were
        // this host's actual set list.
        #expect(activity.lines.count == 1)
        #expect(activity.lines[0].contains(paths.configFile.path))
        #expect(!activity.lines.contains("no backup sets configured — the tick runs and exits immediately"))
    }
}

// MARK: - Host detection

@Suite struct SystemdEnvironmentTests {

    @Test("well-known absolute paths beat anything found on PATH")
    func absolutePathsWin() throws {
        let directory = try makeTempDirectory("bin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shadow = directory.appendingPathComponent("systemctl")
        try Data("#!/bin/sh\n".utf8).write(to: shadow)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shadow.path)

        let found = SystemdEnvironment.findExecutable(
            named: "systemctl",
            wellKnownPaths: ["/usr/bin/systemctl", "/bin/systemctl"],
            environment: ["PATH": directory.path]
        )
        // On a systemd host the absolute path wins; on a container without
        // one, the PATH copy is the only candidate. Either way it never
        // returns nil here, and it never prefers PATH over /usr/bin.
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/systemctl") {
            #expect(found == "/usr/bin/systemctl")
        } else {
            #expect(found == shadow.path)
        }
    }

    @Test("PATH is searched when the well-known locations are empty")
    func pathSearch() throws {
        let directory = try makeTempDirectory("bin")
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("loginctl")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        #expect(SystemdEnvironment.findExecutable(
            named: "loginctl",
            wellKnownPaths: ["/nonexistent/loginctl"],
            environment: ["PATH": "/nonexistent:\(directory.path)"]
        ) == binary.path)
    }

    @Test("nothing anywhere resolves to nil rather than a bare command name")
    func nothingFound() {
        #expect(SystemdEnvironment.findExecutable(
            named: "systemctl",
            wellKnownPaths: ["/nonexistent/systemctl"],
            environment: ["PATH": "/nonexistent"]
        ) == nil)
    }

    /// A container can ship `systemctl` while PID 1 is something else, in
    /// which case every call fails confusingly. `sd_booted(3)`'s own test —
    /// does `/run/systemd/system` exist — is what decides.
    @Test("systemctl is only usable when systemd is also the running init")
    func requiresSystemdInit() {
        let notBooted = SystemdEnvironment(
            systemctlPath: "/usr/bin/systemctl",
            loginctlPath: "/usr/bin/loginctl",
            bootedWithSystemd: false
        )
        #expect(notBooted.usableSystemctlPath == nil)

        let booted = SystemdEnvironment(
            systemctlPath: "/usr/bin/systemctl",
            loginctlPath: nil,
            bootedWithSystemd: true
        )
        #expect(booted.usableSystemctlPath == "/usr/bin/systemctl")
    }
}

// MARK: - /proc/self/exe

@Suite struct HelperSelfPathTests {

    /// The only test here that needs a real Linux kernel, and it gets one:
    /// resolving `/proc/self/exe` inside the test process must produce this
    /// very binary's absolute path. `argv[0]` — a bare name found on PATH, a
    /// relative `./helper`, or an outright lie via `execve` — would not.
    @Test func resolvesTheRunningBinary() throws {
        let resolved = try HelperSelfPath.resolve()
        #expect(resolved.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
        #expect(!resolved.hasSuffix(" (deleted)"))
    }
}

// MARK: - status activity rendering

@Suite struct SystemdTimerActivityTests {

    private func makeSet(name: String, id: UUID = UUID()) -> BackupSet {
        BackupSet(
            id: id,
            name: name,
            sources: ["/home/ben"],
            schedule: .everyMinutes(30),
            destinations: [
                Destination(id: UUID(), label: "Primary", repoURL: "/srv/repo", isPrimary: true)
            ]
        )
    }

    @Test("a never-run set says so rather than showing an empty column")
    func neverRun() {
        let set = makeSet(name: "Documents")
        let lines = SystemdTimerActivity.lines(
            config: AppConfig(sets: [set]),
            scheduleState: nil,
            recentRuns: [],
            now: Date()
        )
        #expect(lines == ["\"Documents\": backup never"])
    }

    @Test("last backup and check are both shown, with an absolute timestamp alongside")
    func lastStarts() {
        let set = makeSet(name: "Documents")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ScheduleState(sets: [
            set.id: SetScheduleState(
                lastBackupStart: now.addingTimeInterval(-120),
                lastCheckStart: now.addingTimeInterval(-3 * 86400)
            )
        ])

        let lines = SystemdTimerActivity.lines(
            config: AppConfig(sets: [set]),
            scheduleState: state,
            recentRuns: [],
            now: now
        )
        #expect(lines.count == 1)
        #expect(lines[0].contains("backup 2 minutes ago"))
        #expect(lines[0].contains("check 3 days ago"))
        // Relative alone is ambiguous over ssh; the ISO timestamp is there too.
        #expect(lines[0].contains("Z)"))
    }

    @Test("an unconfigured host gets a straight answer, not an empty report")
    func noSets() {
        let lines = SystemdTimerActivity.lines(
            config: AppConfig(),
            scheduleState: nil,
            recentRuns: [],
            now: Date()
        )
        #expect(lines == ["no backup sets configured — the tick runs and exits immediately"])
    }

    @Test("the most recent run's outcome is summarised, error and all")
    func lastRunSummary() {
        let set = makeSet(name: "Documents")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = RunIndexEntry(
            runId: "20260805T120000Z-abc",
            kind: .backup,
            setId: set.id,
            destId: UUID(),
            groupId: "20260805T120000Z-abc",
            status: .failed,
            start: now.addingTimeInterval(-7200),
            end: now.addingTimeInterval(-7100),
            trigger: .scheduled,
            snapshotId: nil,
            filesNew: nil,
            filesChanged: nil,
            dataAdded: nil,
            errorSummary: "repository not reachable"
        )

        let lines = SystemdTimerActivity.lines(
            config: AppConfig(sets: [set]),
            scheduleState: nil,
            recentRuns: [entry],
            now: now
        )
        #expect(lines.contains { $0.contains("last run: backup failed") && $0.contains("1 hour ago") })
        #expect(lines.contains { $0.contains("repository not reachable") })
    }

    /// Hand-rolled rather than `RelativeDateTimeFormatter` precisely so this
    /// is stable regardless of the host's locale.
    @Test("ages are locale-independent and singular/plural correct")
    func ageFormatting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SystemdTimerActivity.age(now.addingTimeInterval(-5), now: now).hasPrefix("just now"))
        #expect(SystemdTimerActivity.age(now.addingTimeInterval(-60), now: now).hasPrefix("1 minute ago"))
        #expect(SystemdTimerActivity.age(now.addingTimeInterval(-3600), now: now).hasPrefix("1 hour ago"))
        #expect(SystemdTimerActivity.age(now.addingTimeInterval(-2 * 86400), now: now).hasPrefix("2 days ago"))
        // Clock skew must not render as a nonsensical negative age.
        #expect(SystemdTimerActivity.age(now.addingTimeInterval(600), now: now).hasPrefix("in the future"))
    }
}

#endif
