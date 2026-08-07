#if os(Linux)

import Foundation
import ResticStationCore

/// Installs, removes and reports on the systemd `--user` timer that fires
/// `restic-station-helper tick` on Linux (T26, `docs/scheduling.md` §Linux).
///
/// This is the Linux twin of `App/Sources/Support/LaunchdManager.swift`: the
/// *pure* half — unit text and `systemctl`/`loginctl` argv — lives in Core as
/// `SystemdCommand`, and everything here is the I/O around it. Every
/// subprocess goes through `ProcessRunning`, and every path this type touches
/// is injected, so the whole thing is exercised by `SystemdTimerTests`
/// against a scripted runner and a temporary directory — no systemd required
/// to test it, which matters because the project's development machine is a
/// Mac.
///
/// Nothing here is privileged. User units under `~/.config/systemd/user` are
/// the only supported install: see `SystemdCommand`'s doc comment for why a
/// system unit would break both `AppPaths` resolution and secrets ownership.
struct SystemdTimerManager {

    /// `~/.config/systemd/user` (or its `$XDG_CONFIG_HOME` equivalent).
    let unitDirectory: URL
    let runner: ProcessRunning
    /// The absolute `systemctl`, or `nil` when this host has no usable
    /// systemd — see `SystemdEnvironment.availability`.
    let systemctlPath: String?
    let loginctlPath: String?
    /// The user whose units these are; only used to talk about lingering.
    let userName: String
    /// `/var/lib/systemd/linger` in production; a temp directory in tests.
    let lingerMarkerDirectory: URL

    /// `systemctl --user` talks to a per-user manager over D-Bus; 30s is far
    /// more than a `daemon-reload`/`enable` needs and still bounded, so a
    /// wedged bus surfaces as a timeout instead of hanging `timer install`
    /// forever.
    private static let commandTimeout: TimeInterval = 30

    /// The per-command bound in `verdictOnly` mode. `status` is documented
    /// as a cheap check safe to run as often as a monitoring system likes,
    /// and a monitoring system that runs it every minute must not be able to
    /// accumulate overlapping helper processes against a wedged user bus.
    /// Three calls at 5s is a worst case a per-minute check survives.
    static let verdictOnlyTimeout: TimeInterval = 5

    var serviceUnitURL: URL {
        unitDirectory.appendingPathComponent(SystemdCommand.serviceUnitName, isDirectory: false)
    }

    var timerUnitURL: URL {
        unitDirectory.appendingPathComponent(SystemdCommand.timerUnitName, isDirectory: false)
    }

    var isInstalled: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: serviceUnitURL.path)
            || fileManager.fileExists(atPath: timerUnitURL.path)
    }

    // MARK: - install

    /// Writes both units and enables the timer.
    ///
    /// **Idempotent by construction**: the unit files are overwritten rather
    /// than appended to, and both `daemon-reload` and `enable --now` are
    /// no-ops the second time (systemd's enable is a symlink it will happily
    /// re-create). Re-running with a different `--interval` therefore just
    /// updates the timer in place.
    ///
    /// Order matters: units are on disk *before* `daemon-reload`, and the
    /// reload happens before `enable --now`, otherwise systemd enables the
    /// version of the unit it last read.
    func install(
        helperPath: String,
        intervalMinutes: Int,
        dataDirectory: String?,
        log: (String) -> Void
    ) async throws {
        guard let systemctl = systemctlPath else {
            throw SystemdTimerError.systemdUnavailable(
                Self.noSystemdMessage(
                    helperPath: helperPath,
                    intervalMinutes: intervalMinutes,
                    dataDirectory: dataDirectory
                )
            )
        }

        // Nothing is written before this point: a host without systemd must
        // not be left with orphan unit files it will never act on.
        try writeUnits(
            helperPath: helperPath,
            intervalMinutes: intervalMinutes,
            dataDirectory: dataDirectory
        )
        log("wrote \(serviceUnitURL.path)")
        log("wrote \(timerUnitURL.path)")
        if let dataDirectory, !dataDirectory.isEmpty {
            log("  RESTIC_STATION_DATA_DIR=\(dataDirectory)")
            log("    (the data directory this command resolved, pinned into the unit — a")
            log("     --user service does not inherit your shell's XDG_STATE_HOME)")
        }

        try await runChecked(systemctl, SystemdCommand.daemonReloadArgv)
        try await runChecked(systemctl, SystemdCommand.enableTimerArgv)
        log("enabled \(SystemdCommand.timerUnitName) — ticking every \(SystemdCommand.duration(minutes: intervalMinutes))")
        log("  \(helperPath) tick")

        await warnIfLingerDisabled(log: log)
    }

    /// Renders and writes both units, creating the unit directory if needed.
    private func writeUnits(helperPath: String, intervalMinutes: Int, dataDirectory: String?) throws {
        let service = SystemdCommand.serviceUnit(helperPath: helperPath, dataDirectory: dataDirectory)
        let timer = SystemdCommand.timerUnit(intervalMinutes: intervalMinutes)
        do {
            try FileManager.default.createDirectory(at: unitDirectory, withIntermediateDirectories: true)
            try write(service, to: serviceUnitURL)
            try write(timer, to: timerUnitURL)
        } catch let error as SystemdTimerError {
            throw error
        } catch {
            throw SystemdTimerError.unitWriteFailed(path: unitDirectory.path, underlying: String(describing: error))
        }
    }

    /// 0644, not 0600: a unit file carries no secrets (that is a hard rule —
    /// see `SystemdCommand.serviceUnit`), and the conventional mode is what
    /// anyone debugging with `systemd-analyze cat-config` will expect.
    private func write(_ text: String, to url: URL) throws {
        do {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            throw SystemdTimerError.unitWriteFailed(path: url.path, underlying: String(describing: error))
        }
    }

    // MARK: - uninstall

    /// Disables the timer and removes both units. Exits quietly (and runs no
    /// `systemctl` at all) when nothing is installed, so `timer uninstall` is
    /// safe to put in a teardown script.
    func uninstall(log: (String) -> Void) async throws {
        guard isInstalled else {
            log("no Restic Station units in \(unitDirectory.path) — nothing to uninstall")
            return
        }

        if let systemctl = systemctlPath {
            // Disable *before* deleting: `systemctl disable` removes the
            // `timers.target.wants/` symlink by reading the unit, and cannot
            // do that once the unit file is gone. Failure here is reported,
            // not fatal — the units still have to come off disk, otherwise a
            // half-uninstalled host keeps ticking.
            let result = try? await run(systemctl, SystemdCommand.disableTimerArgv)
            if let result, result.exitCode != 0 {
                log("warning: `systemctl \(SystemdCommand.disableTimerArgv.joined(separator: " "))` "
                    + "exited \(result.exitCode): \(Self.trimmed(result.stderr))")
            }
        } else {
            log("warning: systemctl not found; removing the unit files only")
        }

        let fileManager = FileManager.default
        for url in [timerUnitURL, serviceUnitURL] where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                log("removed \(url.path)")
            } catch {
                throw SystemdTimerError.unitWriteFailed(path: url.path, underlying: String(describing: error))
            }
        }

        if let systemctl = systemctlPath {
            try await runChecked(systemctl, SystemdCommand.daemonReloadArgv)
        }
        log("Restic Station is no longer scheduled on this host.")
    }

    // MARK: - status

    /// Prints the headless equivalent of glancing at the menu bar icon.
    ///
    /// - Parameters:
    ///   - helperPath: this binary's own path, used only to print a
    ///     copy-pasteable cron line when there is no systemd. Optional
    ///     because status must still report on a host where
    ///     `/proc/self/exe` could not be read.
    ///   - dataDirectory: the resolved data directory, for the same cron
    ///     line — see `SystemdCommand.cronFallbackLine`.
    ///   - activity: what the tick has been doing, plus anything the caller
    ///     found wrong while reading it (a config it could not load).
    /// - Returns: every reason scheduled backups will not happen on this
    ///   host, empty when there are none. `timer status` maps that onto its
    ///   exit code so a monitoring script can use it.
    ///   - verdictOnly: skip everything that only produces prose. `status`
    ///     (the monitoring command) discards this method's log output
    ///     entirely and wants the verdict; running `list-timers` for it —
    ///     the slowest call here, and pure narrative — is waste that a
    ///     wedged D-Bus turns into a stall. Also shortens the per-command
    ///     timeout, so the whole probe is bounded by
    ///     `verdictOnlyTimeout × 3` rather than `commandTimeout × 4` plus
    ///     termination grace (`@codex review` on #51).
    func status(
        helperPath: String? = nil,
        dataDirectory: String? = nil,
        activity: TimerActivity,
        verdictOnly: Bool = false,
        log: (String) -> Void
    ) async -> TimerHealth {
        log("Restic Station — systemd --user timer")
        log("")

        guard let systemctl = systemctlPath else {
            log("  systemd     not available on this host")
            log("")
            let advice = Self.cronFallbackAdvice(
                helperPath: helperPath,
                intervalMinutes: SystemdCommand.defaultIntervalMinutes,
                dataDirectory: dataDirectory
            )
            for line in advice {
                log(line.isEmpty ? "" : "  \(line)")
            }
            let health = TimerHealth(problems: [.systemdUnavailable] + activity.problems)
            Self.logVerdict(health, log: log)
            return health
        }

        var problems: [TimerProblem] = []
        let fileManager = FileManager.default
        let hasService = fileManager.fileExists(atPath: serviceUnitURL.path)
        let hasTimer = fileManager.fileExists(atPath: timerUnitURL.path)
        if hasService && hasTimer {
            log("  units       installed in \(unitDirectory.path)")
            log("                \(SystemdCommand.serviceUnitName)")
            log("                \(SystemdCommand.timerUnitName)")
        } else if hasService || hasTimer {
            // One half present is not a state `timer install` can produce; it
            // means someone deleted a file by hand, and systemd will refuse
            // to start the timer. Say so rather than reporting "installed".
            log("  units       INCOMPLETE in \(unitDirectory.path)")
            log("                \(SystemdCommand.serviceUnitName): \(hasService ? "present" : "MISSING")")
            log("                \(SystemdCommand.timerUnitName): \(hasTimer ? "present" : "MISSING")")
            log("                fix: restic-station-helper timer install")
            problems.append(.unitsIncomplete)
        } else {
            log("  units       not installed (looked in \(unitDirectory.path))")
            log("                fix: restic-station-helper timer install")
            problems.append(.unitsMissing)
        }

        if let interval = Self.installedInterval(timerUnitURL: timerUnitURL) {
            log("  interval    every \(interval) (OnUnitActiveSec)")
        }

        // The unit is global to this user; the data directory is not. A
        // timer installed for /srv/a is enabled and active while `status`
        // asks about /srv/b — and answering "healthy" there says scheduled
        // backups will happen for a directory nothing ticks. Compare what
        // the unit actually pins against what this invocation resolved
        // (`@codex review` on #51).
        if hasService, let dataDirectory, !dataDirectory.isEmpty {
            let installed = Self.installedDataDirectory(serviceUnitURL: serviceUnitURL)
            if let installed, installed != dataDirectory {
                log("  data dir    MISMATCH")
                log("                this command:  \(dataDirectory)")
                log("                the timer's:   \(installed)")
                log("                fix: restic-station-helper timer install (from this environment)")
                problems.append(.dataDirectoryMismatch)
            } else if installed == nil {
                log("  data dir    the unit pins none — the tick will re-derive it from the")
                log("                systemd user manager's environment, not this one")
                log("                fix: restic-station-helper timer install (from this environment)")
                problems.append(.dataDirectoryUnpinned)
            } else {
                log("  data dir    \(dataDirectory) (pinned in the unit)")
            }
        }

        let timeout = verdictOnly ? Self.verdictOnlyTimeout : Self.commandTimeout
        let enabled = await word(systemctl, SystemdCommand.isEnabledArgv, timeout: timeout)
        let active = await word(systemctl, SystemdCommand.isActiveArgv, timeout: timeout)
        log("  enabled     \(enabled ?? "unknown")")
        log("  active      \(active ?? "unknown")")
        if enabled != "enabled" { problems.append(.notEnabled) }
        if active != "active" { problems.append(.notActive) }

        let linger = await lingerState(timeout: timeout)
        switch linger {
        case .enabled:
            log("  linger      enabled — user units keep running after logout")
        case .disabled:
            log("  linger      DISABLED — scheduled backups stop when \(userName) logs out")
            log("                fix: \(SystemdCommand.enableLingerCommandLine(user: userName))")
            problems.append(.lingerDisabled)
        case .unknown:
            log("  linger      unknown — could not ask loginctl or read \(lingerMarkerDirectory.path)")
            log("                if backups stop after logout: \(SystemdCommand.enableLingerCommandLine(user: userName))")
            // Deliberately *not* a problem. `.unknown` means neither
            // `loginctl` nor `/var/lib/systemd/linger` could be consulted,
            // which on a container without logind is not a broken host but a
            // host where the question does not arise (nobody logs out of it).
            // Failing here would make `timer status` red on every such host
            // forever, and a health check that is always red is a health
            // check nobody reads. Only a confirmed `Linger=no` — a host that
            // has logind and told us the answer — fails.
        }

        // Narrative only, and the slowest call here — skipped for a caller
        // that discards the log.
        if hasTimer, !verdictOnly {
            log("")
            log("  next firing")
            let timers = try? await run(systemctl, SystemdCommand.listTimersArgv)
            let output = Self.trimmed(timers?.stdout ?? Data())
            if output.isEmpty {
                log("    (systemctl list-timers reported nothing)")
            } else {
                for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                    log("    \(line)")
                }
            }
        }

        if !activity.lines.isEmpty {
            log("")
            log("  last tick activity (from state/ and runs/)")
            for line in activity.lines {
                log("    \(line)")
            }
        }

        let health = TimerHealth(problems: problems + activity.problems)
        Self.logVerdict(health, log: log)
        return health
    }

    /// The last thing `timer status` prints, and the only line a human has to
    /// read. Everything above it is evidence; this is the finding, spelled
    /// out — including the exit code, so the connection between "what this
    /// says" and "what a monitoring script sees" is never inferred.
    private static func logVerdict(_ health: TimerHealth, log: (String) -> Void) {
        log("")
        guard !health.isHealthy else {
            log("  VERDICT     scheduled backups will happen on this host (exit 0)")
            return
        }
        log("  VERDICT     scheduled backups will NOT happen on this host (exit 1)")
        for problem in health.problems {
            log("                - \(problem.summary)")
        }
    }

    /// The `RESTIC_STATION_DATA_DIR` the installed service unit pins, or
    /// `nil` when it pins none. Reads the unit rather than asking systemd:
    /// the file is the thing `timer install` wrote and the thing the tick
    /// will run from.
    ///
    /// Undoes `SystemdCommand`'s two escaping layers in the reverse order
    /// they were applied — systemd quoting, then `%%` specifier escaping —
    /// so the comparison is against the real path.
    static func installedDataDirectory(serviceUnitURL: URL) -> String? {
        guard let text = try? String(contentsOf: serviceUnitURL, encoding: .utf8) else { return nil }
        let prefix = "Environment="
        for line in text.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix(prefix) else { continue }
            var value = String(trimmedLine.dropFirst(prefix.count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            let assignment = "RESTIC_STATION_DATA_DIR="
            guard value.hasPrefix(assignment) else { continue }
            return String(value.dropFirst(assignment.count))
                .replacingOccurrences(of: "%%", with: "%")
        }
        return nil
    }

    /// `OnUnitActiveSec=` as actually installed, so status reports the truth
    /// rather than the default this build would have written.
    static func installedInterval(timerUnitURL: URL) -> String? {
        guard let text = try? String(contentsOf: timerUnitURL, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("OnUnitActiveSec=") else { continue }
            return String(trimmedLine.dropFirst("OnUnitActiveSec=".count))
        }
        return nil
    }

    // MARK: - Lingering

    enum LingerState: Equatable {
        case enabled
        case disabled
        case unknown
    }

    /// `loginctl show-user <user> --property=Linger`, falling back to the
    /// marker file `loginctl enable-linger` actually creates. The fallback
    /// exists because `loginctl show-user` fails outright for a user with no
    /// current session — precisely the headless case this warning is for.
    func lingerState(timeout: TimeInterval = SystemdTimerManager.commandTimeout) async -> LingerState {
        if let loginctl = loginctlPath,
           let result = try? await run(loginctl, SystemdCommand.lingerArgv(user: userName), timeout: timeout),
           result.exitCode == 0 {
            let output = String(decoding: result.stdout, as: UTF8.self)
            if output.contains("Linger=yes") { return .enabled }
            if output.contains("Linger=no") { return .disabled }
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: lingerMarkerDirectory.path) else { return .unknown }
        let marker = lingerMarkerDirectory.appendingPathComponent(userName, isDirectory: false)
        return fileManager.fileExists(atPath: marker.path) ? .enabled : .disabled
    }

    /// Prominent because this is the single most likely way a Linux install
    /// silently stops backing up: everything reports healthy right up until
    /// the user logs out, and then nothing runs and nothing complains.
    private func warnIfLingerDisabled(log: (String) -> Void) async {
        switch await lingerState() {
        case .enabled:
            return
        case .disabled:
            log("")
            log("WARNING: lingering is disabled for \(userName).")
            log("  systemd stops this user's units when \(userName) logs out, so scheduled")
            log("  backups will silently stop on a headless machine. Enable it with:")
            log("")
            log("      \(SystemdCommand.enableLingerCommandLine(user: userName))")
            log("")
            log("  (not run automatically: it needs root, and a backup tool that")
            log("   escalates privilege behind your back is a worse bug than this warning)")
        case .unknown:
            log("")
            log("NOTE: could not determine whether lingering is enabled for \(userName).")
            log("  If scheduled backups stop after you log out, run:")
            log("      \(SystemdCommand.enableLingerCommandLine(user: userName))")
        }
    }

    // MARK: - Messages

    /// What `timer install` says on a host with no systemd. Names the cron
    /// one-liner rather than letting the user meet `systemctl: command not
    /// found` and file a bug.
    static func noSystemdMessage(
        helperPath: String,
        intervalMinutes: Int,
        dataDirectory: String? = nil
    ) -> String {
        (["systemd is not available on this host, so there is no user timer to install."]
            + cronFallbackAdvice(
                helperPath: helperPath,
                intervalMinutes: intervalMinutes,
                dataDirectory: dataDirectory
            ))
            .joined(separator: "\n")
    }

    static func cronFallbackAdvice(
        helperPath: String?,
        intervalMinutes: Int,
        dataDirectory: String? = nil
    ) -> [String] {
        let path = helperPath ?? "/path/to/restic-station-helper"
        return [
            "Use cron instead — one line, no tooling needed (`crontab -e`):",
            "",
            "    \(SystemdCommand.cronFallbackLine(helperPath: path, intervalMinutes: intervalMinutes, dataDirectory: dataDirectory))",
            "",
            "One behavioural difference: cron has no equivalent of the timer's",
            "boot-time catch-up, so a tick missed while the machine was off is not",
            "replayed at boot — the next scheduled tick picks it up instead. That",
            "delays catch-up by up to one interval and loses nothing, because",
            "due-ness comes from state/schedule-state.json, not from cron slots.",
        ]
    }

    // MARK: - Running

    /// Runs `executable` with `argv` and throws when it exits non-zero.
    private func runChecked(_ executable: String, _ argv: [String]) async throws {
        let result: ProcessResult
        do {
            result = try await run(executable, argv)
        } catch {
            throw SystemdTimerError.commandFailed(
                argv: [executable] + argv,
                exitCode: nil,
                stderr: String(describing: error)
            )
        }
        guard result.exitCode == 0 else {
            throw SystemdTimerError.commandFailed(
                argv: [executable] + argv,
                exitCode: result.exitCode,
                stderr: Self.trimmed(result.stderr)
            )
        }
    }

    private func run(
        _ executable: String,
        _ argv: [String],
        timeout: TimeInterval = SystemdTimerManager.commandTimeout
    ) async throws -> ProcessResult {
        // `env: nil` inherits this process's environment on purpose:
        // `systemctl --user` finds its per-user manager through
        // `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS`, and replacing the
        // environment would break every call.
        try await runner.run(
            [executable] + argv,
            env: nil,
            currentDirectory: nil,
            onStdoutLine: nil,
            onStderrLine: nil,
            timeout: timeout
        )
    }

    /// The single trimmed stdout word `is-enabled`/`is-active` print. Both
    /// exit non-zero to *report* ("disabled" exits 1), so the exit code is
    /// deliberately ignored here and only the word is used.
    private func word(
        _ executable: String,
        _ argv: [String],
        timeout: TimeInterval = SystemdTimerManager.commandTimeout
    ) async -> String? {
        guard let result = try? await run(executable, argv, timeout: timeout) else { return nil }
        let output = Self.trimmed(result.stdout)
        return output.isEmpty ? nil : output.split(separator: "\n").first.map(String.init)
    }

    static func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TimerHealth

/// One reason scheduled backups will not happen on this host.
///
/// The `rawValue`s are a documented interface: they appear in `status
/// --json`'s `scheduler.problems` array (`docs/data-model.md`), so a
/// monitoring script can branch on the *kind* of breakage rather than
/// grepping prose. Adding a case is additive; renaming one is not.
enum TimerProblem: String, Equatable, Sendable, CaseIterable {
    case systemdUnavailable
    case unitsMissing
    case unitsIncomplete
    case notEnabled
    case notActive
    case lingerDisabled
    case configUnreadable
    case dataDirectoryMismatch
    case dataDirectoryUnpinned

    /// One line, no leading capital, safe to print after a dash.
    var summary: String {
        switch self {
        case .systemdUnavailable:
            return "systemd is not available on this host, so nothing is scheduling the tick"
        case .unitsMissing:
            return "the units are not installed — run `restic-station-helper timer install`"
        case .unitsIncomplete:
            return "one of the two units is missing; systemd will refuse to start the timer"
        case .notEnabled:
            return "the timer is not enabled, so it will not come back after a reboot"
        case .notActive:
            return "the timer is not active, so it is not firing now"
        case .lingerDisabled:
            return "lingering is disabled — the timer stops at logout "
                + "(`sudo loginctl enable-linger <user>`)"
        case .configUnreadable:
            return "the configuration could not be loaded, so every tick will fail"
        case .dataDirectoryMismatch:
            return "the installed timer ticks a different data directory than this command reads"
        case .dataDirectoryUnpinned:
            return "the installed timer pins no data directory, so the tick may resolve a "
                + "different one — reinstall it with `timer install`"
        }
    }
}

/// The verdict `timer status` exits on: every reason found, in the order
/// found, or empty for a healthy host.
struct TimerHealth: Equatable, Sendable {
    var problems: [TimerProblem]

    var isHealthy: Bool { problems.isEmpty }

    /// `timer status`'s exit code, and the one place the mapping is written
    /// down. Documented in `docs/scheduling.md` §`timer status`.
    var exitCode: Int32 { isHealthy ? 0 : 1 }
}

/// What the tick has been doing, plus anything that went wrong while finding
/// out.
///
/// The two travel together because a failure to *read* the state is itself a
/// scheduling problem — a `config.json` that will not parse means every tick
/// exits 1 — and reporting the activity lines without it is how `timer
/// status` used to print a cheerful "no backup sets configured" for a host
/// whose config was corrupt.
struct TimerActivity: Equatable, Sendable {
    var lines: [String]
    var problems: [TimerProblem]

    init(lines: [String], problems: [TimerProblem] = []) {
        self.lines = lines
        self.problems = problems
    }
}

// MARK: - SystemdTimerError

enum SystemdTimerError: Error, CustomStringConvertible {
    /// No systemd on this host at all. Carries the full cron-fallback advice.
    case systemdUnavailable(String)
    /// `/proc/self/exe` could not be read, so we do not know what path to
    /// bake into `ExecStart=`.
    case helperPathUnresolved(String)
    case commandFailed(argv: [String], exitCode: Int32?, stderr: String)
    case unitWriteFailed(path: String, underlying: String)

    var description: String {
        switch self {
        case .systemdUnavailable(let message):
            return message
        case .helperPathUnresolved(let message):
            return message
        case .commandFailed(let argv, let exitCode, let stderr):
            let rendered = argv.joined(separator: " ")
            var message = exitCode.map { "`\(rendered)` failed (exit \($0))" }
                ?? "`\(rendered)` could not be run"
            if !stderr.isEmpty {
                message += ": \(stderr)"
            }
            // The single most common way `systemctl --user` fails on a
            // headless box, and the message it prints ("Failed to connect to
            // bus: No medium found") explains nothing to a first-time user.
            if stderr.contains("Failed to connect to bus") {
                message += "\n\nThis usually means there is no systemd user manager for this "
                    + "session — typically because the command was run over sudo/su rather than "
                    + "as the user who owns the backups. Log in as that user (or use "
                    + "`machinectl shell <user>@`) and try again."
            }
            return message
        case .unitWriteFailed(let path, let underlying):
            return "could not write \(path): \(underlying)"
        }
    }
}

// MARK: - SystemdEnvironment

/// What this host offers, resolved once at startup and handed to
/// `SystemdTimerManager`. Split out so the manager itself takes plain
/// injected values and never probes the machine it is running on.
struct SystemdEnvironment {
    let systemctlPath: String?
    let loginctlPath: String?
    /// `/run/systemd/system` exists, i.e. PID 1 really is systemd. A
    /// container image can ship `systemctl` while running some other init,
    /// in which case every `systemctl` call fails confusingly.
    let bootedWithSystemd: Bool

    /// `systemctl` is only reported when systemd is also the running init:
    /// `SystemdTimerManager` treats a `nil` `systemctlPath` as "no systemd
    /// here", which is exactly the right answer in both cases.
    var usableSystemctlPath: String? {
        bootedWithSystemd ? systemctlPath : nil
    }

    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> SystemdEnvironment {
        SystemdEnvironment(
            systemctlPath: findExecutable(
                named: "systemctl",
                wellKnownPaths: SystemdCommand.systemctlWellKnownPaths,
                environment: environment,
                fileManager: fileManager
            ),
            loginctlPath: findExecutable(
                named: "loginctl",
                wellKnownPaths: SystemdCommand.loginctlWellKnownPaths,
                environment: environment,
                fileManager: fileManager
            ),
            bootedWithSystemd: fileManager.fileExists(atPath: SystemdCommand.systemdRunDirectory)
        )
    }

    /// Well-known absolute paths first, then `PATH`. Absolute paths win so a
    /// user's shadowed `systemctl` earlier on `PATH` cannot redirect what is
    /// effectively a privileged-adjacent operation.
    static func findExecutable(
        named name: String,
        wellKnownPaths: [String],
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        for path in wellKnownPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}

// MARK: - Self path

/// Resolving the helper's *own* absolute path, for `ExecStart=`.
enum HelperSelfPath {

    /// `/proc/self/exe`, never `argv[0]`.
    ///
    /// `argv[0]` is whatever the caller chose to put there: a bare
    /// `restic-station-helper` found on `PATH`, a relative `./helper`, or —
    /// with `execve` — an outright lie. Baking any of those into a unit file
    /// produces a timer that works until the user's shell, `PATH` or working
    /// directory changes and then fails at 3am. The kernel's
    /// `/proc/self/exe` symlink is the one answer that is always the real,
    /// absolute, resolved path of the running binary.
    static func resolve(fileManager: FileManager = .default) throws -> String {
        let link = "/proc/self/exe"
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link) else {
            throw SystemdTimerError.helperPathUnresolved(
                "could not read \(link) to find this helper's own path — is /proc mounted?"
            )
        }
        // The kernel appends " (deleted)" when the binary has been replaced
        // or removed since it started (a mid-upgrade `timer install`).
        // Installing that literal path would produce a unit that can never
        // start, so refuse instead.
        guard !target.hasSuffix(" (deleted)"), fileManager.isExecutableFile(atPath: target) else {
            throw SystemdTimerError.helperPathUnresolved(
                "\(link) points at \"\(target)\", which is not an executable file right now "
                    + "(the helper was moved, deleted or replaced while running). "
                    + "Re-run `timer install` from the installed binary."
            )
        }
        return target
    }
}

// MARK: - Recent activity

/// The "what has the tick actually been doing" half of `timer status`.
///
/// Pure — it takes the already-loaded state and returns lines — so the
/// formatting is unit-tested without a data directory. Kept deliberately
/// small: `timer status` answers "is it scheduled and is it running", and
/// the Runs screen (or `runs/index.jsonl`) is where run detail lives.
enum SystemdTimerActivity {

    static func lines(
        config: AppConfig,
        scheduleState: ScheduleState?,
        recentRuns: [RunIndexEntry],
        now: Date
    ) -> [String] {
        var result: [String] = []

        if config.sets.isEmpty {
            result.append("no backup sets configured — the tick runs and exits immediately")
        }

        for set in config.sets {
            let state = scheduleState?.sets[set.id]
            var parts: [String] = []
            parts.append("backup " + (state?.lastBackupStart.map { age($0, now: now) } ?? "never"))
            if state?.lastCheckStart != nil {
                parts.append("check " + age(state!.lastCheckStart!, now: now))
            }
            result.append("\"\(set.name)\": \(parts.joined(separator: ", "))")
        }

        if let last = recentRuns.first {
            let ended = last.end.map { age($0, now: now) } ?? "still running"
            result.append("last run: \(last.kind.rawValue) \(last.status.rawValue) (\(ended))")
            if let error = last.errorSummary, !error.isEmpty {
                result.append("  \(error)")
            }
        }

        return result
    }

    /// Deliberately hand-rolled rather than `RelativeDateTimeFormatter`:
    /// this string is asserted in tests and read over ssh, so it must not
    /// vary with the host's locale.
    static func age(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 {
            return "in the future (\(iso(date)))"
        }
        let rendered: String
        switch seconds {
        case ..<60:
            rendered = "just now"
        case ..<3600:
            rendered = plural(Int(seconds / 60), "minute") + " ago"
        case ..<86400:
            rendered = plural(Int(seconds / 3600), "hour") + " ago"
        default:
            rendered = plural(Int(seconds / 86400), "day") + " ago"
        }
        return "\(rendered) (\(iso(date)))"
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

#endif
