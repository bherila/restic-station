import Foundation
import Testing
@testable import ResticStationCore

// Coverage for `SchedulerCommand.swift` — the pure vocabulary of the two host
// schedulers Restic Station registers with. Conditionally compiled exactly
// like the source it covers: launchd on macOS, systemd on Linux.

#if os(macOS)

// MARK: - launchctl (macOS)

@Suite struct LaunchctlCommandTests {
    /// `Label` MUST equal the plist filename minus `.plist`
    /// (`docs/scheduling.md` §plist), and both must match the shipped
    /// `App/Resources/net.herila.ResticStation.helper.plist`.
    @Test func labelMatchesPlistName() {
        #expect(LaunchctlCommand.helperLabel == "net.herila.ResticStation.helper")
        #expect(LaunchctlCommand.helperPlistName == "net.herila.ResticStation.helper.plist")
        #expect(LaunchctlCommand.helperPlistName == LaunchctlCommand.helperLabel + ".plist")
    }

    /// The default kickstart must NOT carry `-k`: on a busy service plain
    /// `kickstart` is a no-op, whereas `-k` would kill a running backup
    /// (`docs/keychain-and-fda.md` §3).
    @Test func kickstartDefaultDoesNotRestart() {
        let argv = LaunchctlCommand.kickstartArgv(uid: 501)
        #expect(argv == ["kickstart", "gui/501/net.herila.ResticStation.helper"])
        #expect(!argv.contains("-k"))
    }

    /// `-k` is the FDA re-check flow only, and goes *before* the service
    /// target.
    @Test func kickstartRestartAddsDashK() {
        let argv = LaunchctlCommand.kickstartArgv(uid: 501, restart: true)
        #expect(argv == ["kickstart", "-k", "gui/501/net.herila.ResticStation.helper"])
    }

    /// The uid is interpolated, never hard-coded — a machine whose console
    /// user isn't 501 must still target its own GUI domain.
    @Test(arguments: [UInt32(0), UInt32(501), UInt32(502), UInt32(1000)])
    func kickstartUsesCallerUID(uid: UInt32) {
        let argv = LaunchctlCommand.kickstartArgv(uid: uid, restart: false)
        #expect(argv.last == "gui/\(uid)/net.herila.ResticStation.helper")
    }

    @Test func executablePathIsAbsolute() {
        // Absolute so nothing depends on the app's inherited PATH.
        #expect(LaunchctlCommand.executablePath == "/bin/launchctl")
    }
}

#endif

#if os(Linux)

// MARK: - systemd unit rendering (Linux)

@Suite struct SystemdUnitRenderingTests {

    @Test("the helper path is substituted verbatim into ExecStart")
    func servicePathSubstitution() {
        let unit = SystemdCommand.serviceUnit(helperPath: "/opt/restic-station/bin/restic-station-helper")
        #expect(unit.contains("ExecStart=/opt/restic-station/bin/restic-station-helper tick"))
        // The placeholder only exists in the shipped template; a rendered
        // unit that still carries it would produce a timer that can never run.
        #expect(!unit.contains(SystemdCommand.helperPathPlaceholder))
    }

    @Test("the service is a timer-driven oneshot: no Restart=, no [Install]")
    func serviceShape() {
        let unit = SystemdCommand.serviceUnit(helperPath: "/usr/local/bin/restic-station-helper")
        #expect(unit.contains("Type=oneshot"))
        // A Restart= on a timer-driven oneshot would retry a failing backup
        // in a tight loop; the tick retries at its next scheduled slot.
        #expect(!unit.contains("Restart="))
        // Enabling the service directly would tick once per boot and never
        // again — only the timer carries an [Install] section.
        #expect(!unit.contains("[Install]"))
        #expect(unit.hasSuffix("\n"))
    }

    @Test("RESTIC_STATION_DATA_DIR is baked in only when the user overrode it")
    func serviceDataDirectory() {
        let plain = SystemdCommand.serviceUnit(helperPath: "/usr/bin/restic-station-helper")
        #expect(!plain.contains("RESTIC_STATION_DATA_DIR"))

        let overridden = SystemdCommand.serviceUnit(
            helperPath: "/usr/bin/restic-station-helper",
            dataDirectory: "/srv/backups/restic-station"
        )
        #expect(overridden.contains("Environment=\"RESTIC_STATION_DATA_DIR=/srv/backups/restic-station\""))
        // An empty value is an unset value, not an override to an empty path.
        #expect(!SystemdCommand.serviceUnit(helperPath: "/x", dataDirectory: "").contains("Environment="))
    }

    /// Secrets come from the secret store at run time and must never reach a
    /// world-readable unit file (issue #28: "Do not put secrets in an
    /// EnvironmentFile").
    @Test("no unit ever references an EnvironmentFile or a password")
    func unitsCarryNoSecrets() {
        let units = [
            SystemdCommand.serviceUnit(helperPath: "/usr/bin/restic-station-helper", dataDirectory: "/srv/x"),
            SystemdCommand.timerUnit(),
        ]
        for unit in units {
            #expect(!unit.contains("EnvironmentFile"))
            #expect(!unit.lowercased().contains("password"))
            #expect(!unit.contains("RESTIC_PASSWORD"))
        }
    }

    @Test("a path with spaces is quoted rather than silently split")
    func servicePathQuoting() {
        let unit = SystemdCommand.serviceUnit(helperPath: "/opt/restic station/helper")
        #expect(unit.contains("ExecStart=\"/opt/restic station/helper\" tick"))
    }

    @Test("the timer fires at boot and on an interval, and keeps Persistent=true")
    func timerShape() {
        let unit = SystemdCommand.timerUnit()
        #expect(unit.contains("OnBootSec=2min"))
        #expect(unit.contains("OnUnitActiveSec=2min"))
        // Load-bearing per issue #28: the anacron-equivalent that keeps Linux
        // behaviourally equal to macOS after downtime. Do not drop it — see
        // docs/scheduling.md §Linux for what it does and does not do.
        #expect(unit.contains("Persistent=true"))
        #expect(unit.contains("Unit=restic-station.service"))
        #expect(unit.contains("[Install]\nWantedBy=timers.target"))
    }

    @Test("--interval changes both trigger points and the description together",
          arguments: [1, 2, 15, 60, 1440])
    func timerInterval(minutes: Int) {
        let unit = SystemdCommand.timerUnit(intervalMinutes: minutes)
        #expect(unit.contains("OnBootSec=\(minutes)min"))
        #expect(unit.contains("OnUnitActiveSec=\(minutes)min"))
        #expect(unit.contains("Description=Restic Station scheduling tick every \(minutes)min"))
    }

    @Test("the default interval matches the macOS LaunchAgent's StartInterval of 120s")
    func defaultIntervalMatchesMacOS() {
        #expect(SystemdCommand.defaultIntervalMinutes == 2)
    }
}

// MARK: - Shipped templates

@Suite struct SystemdPackagedTemplateTests {

    /// `packaging/linux/systemd/*` are the hand-installable copies of what
    /// `timer install` writes — they exist for distro packaging and for
    /// anyone who would rather drop the files in themselves. They are
    /// exactly the rendered units with `<HELPER_PATH>` left in place, and
    /// this test is what stops the two drifting apart.
    @Test func templatesMatchWhatTimerInstallWrites() throws {
        let packaging = Self.repositoryRoot
            .appendingPathComponent("packaging/linux/systemd", isDirectory: true)

        let service = try String(
            contentsOf: packaging.appendingPathComponent(SystemdCommand.serviceUnitName),
            encoding: .utf8
        )
        #expect(service == SystemdCommand.serviceUnit(helperPath: SystemdCommand.helperPathPlaceholder))

        let timer = try String(
            contentsOf: packaging.appendingPathComponent(SystemdCommand.timerUnitName),
            encoding: .utf8
        )
        #expect(timer == SystemdCommand.timerUnit())
    }

    /// `<repo>/Core/Tests/ResticStationCoreTests/Support/<this file>` — five
    /// levels up. `#filePath` rather than a bundle resource so the test needs
    /// no packaging changes in either SwiftPM or XcodeGen.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // ResticStationCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // <repo>
    }
}

// MARK: - systemctl / loginctl argv

@Suite struct SystemdCommandArgvTests {

    /// Every call is `--user`. A system-wide `systemctl` call would touch
    /// units this tool never installs, and on a non-root user it would just
    /// fail — see `SystemdCommand`'s doc comment for why user units are the
    /// only supported shape.
    @Test func everyInvocationIsUserScoped() {
        let argvs = [
            SystemdCommand.daemonReloadArgv,
            SystemdCommand.enableTimerArgv,
            SystemdCommand.disableTimerArgv,
            SystemdCommand.isEnabledArgv,
            SystemdCommand.isActiveArgv,
            SystemdCommand.listTimersArgv,
        ]
        for argv in argvs {
            #expect(argv.first == "--user")
        }
    }

    @Test func exactArgvSpellings() {
        #expect(SystemdCommand.daemonReloadArgv == ["--user", "daemon-reload"])
        #expect(SystemdCommand.enableTimerArgv == ["--user", "enable", "--now", "restic-station.timer"])
        #expect(SystemdCommand.disableTimerArgv == ["--user", "disable", "--now", "restic-station.timer"])
        #expect(SystemdCommand.isEnabledArgv == ["--user", "is-enabled", "restic-station.timer"])
        #expect(SystemdCommand.isActiveArgv == ["--user", "is-active", "restic-station.timer"])
        // `--all` so an inactive timer is still listed; `--no-pager` because
        // this output is captured, not shown in a terminal.
        #expect(SystemdCommand.listTimersArgv
            == ["--user", "list-timers", "--all", "--no-pager", "restic-station.timer"])
        #expect(SystemdCommand.lingerArgv(user: "ben") == ["show-user", "ben", "--property=Linger"])
    }

    /// Enabling lingering needs root, so the helper only ever *prints* this.
    @Test func lingerFixIsPrintedNotRun() {
        #expect(SystemdCommand.enableLingerCommandLine(user: "ben") == "sudo loginctl enable-linger ben")
    }

    @Test("the documented cron fallback is a single crontab line")
    func cronFallback() {
        #expect(SystemdCommand.cronFallbackLine(helperPath: "/usr/bin/restic-station-helper")
            == "*/2 * * * * /usr/bin/restic-station-helper tick")
        #expect(SystemdCommand.cronFallbackLine(helperPath: "/usr/bin/h", intervalMinutes: 15)
            == "*/15 * * * * /usr/bin/h tick")
    }
}

// MARK: - Unit directory

@Suite struct SystemdUnitDirectoryTests {

    @Test("XDG_CONFIG_HOME wins when it is set and absolute")
    func honoursXDGConfigHome() {
        let directory = SystemdCommand.userUnitDirectory(
            environment: ["XDG_CONFIG_HOME": "/var/lib/ben/config"],
            homeDirectory: URL(fileURLWithPath: "/home/ben", isDirectory: true)
        )
        #expect(directory.path == "/var/lib/ben/config/systemd/user")
    }

    /// Same rule as `AppPaths.xdgBaseDirectory`: unset, empty, or relative
    /// all fall back as if the variable were not there.
    @Test("anything other than an absolute value falls back to ~/.config",
          arguments: [[:], ["XDG_CONFIG_HOME": ""], ["XDG_CONFIG_HOME": "relative/config"]] as [[String: String]])
    func fallsBackToDotConfig(environment: [String: String]) {
        let directory = SystemdCommand.userUnitDirectory(
            environment: environment,
            homeDirectory: URL(fileURLWithPath: "/home/ben", isDirectory: true)
        )
        #expect(directory.path == "/home/ben/.config/systemd/user")
    }
}

#endif
