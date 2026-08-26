#if os(Linux)

import ArgumentParser
import Foundation
import ResticStationCore

/// `timer install|uninstall|status` — the Linux half of `docs/scheduling.md`.
///
/// On macOS the app registers a LaunchAgent with `SMAppService` and there is
/// nothing for a CLI to do; on Linux there is no app, so scheduling has to be
/// installable from the helper itself. The whole subcommand is therefore
/// compiled only on Linux and does not appear in `--help` on macOS — an
/// option that exists but always errors is worse than one that is honestly
/// absent.
///
/// Spelled `TimerCommand` rather than `Timer`: `Foundation.Timer` exists on
/// both platforms, and a module-level `Timer` would shadow it for every other
/// file in this target.
struct TimerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timer",
        abstract: "Manage the systemd --user timer that runs `tick` on a schedule (Linux only).",
        discussion: """
            Restic Station does not run a daemon. On Linux a per-user systemd \
            timer fires `restic-station-helper tick` every couple of minutes, \
            and the tick decides what is actually due from \
            state/schedule-state.json. `timer install` sets that up; nothing \
            else needs to run in the background.

            User units under ~/.config/systemd/user only — never system units. \
            The helper's state and secrets are $HOME-scoped and owned by one \
            user, and a root-run unit would find neither.
            """,
        subcommands: [Install.self, Uninstall.self, Status.self]
    )
}

// MARK: - Shared wiring

extension TimerCommand {

    /// Builds a `SystemdTimerManager` for the invoking user, resolving every
    /// host fact (systemctl, loginctl, unit directory, user name) once.
    static func makeManager() -> SystemdTimerManager {
        let environment = ProcessInfo.processInfo.environment
        let systemd = SystemdEnvironment.detect(environment: environment)
        return SystemdTimerManager(
            unitDirectory: SystemdCommand.userUnitDirectory(
                environment: environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            runner: DefaultProcessRunner(),
            systemctlPath: systemd.usableSystemctlPath,
            loginctlPath: systemd.loginctlPath,
            userName: currentUserName(environment: environment),
            lingerMarkerDirectory: URL(fileURLWithPath: SystemdCommand.lingerMarkerDirectory, isDirectory: true)
        )
    }

    /// `NSUserName()` is the login name of the user this process runs as,
    /// which is what `loginctl` keys on. `$USER` is only a fallback for the
    /// odd environment where the passwd lookup returns nothing.
    static func currentUserName(environment: [String: String]) -> String {
        let name = NSUserName()
        if !name.isEmpty { return name }
        return environment["USER"] ?? environment["LOGNAME"] ?? "$(whoami)"
    }
}

// MARK: - timer install

extension TimerCommand {

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Write ~/.config/systemd/user/restic-station.{service,timer} and enable the timer. "
                + "Idempotent. Exit 0 ok, 1 error.",
            discussion: """
                Re-running updates the units in place — change the interval by \
                re-running with a different --interval. Nothing is duplicated \
                and no state is lost.

                The data directory this command resolved is pinned into the \
                service unit, so the timer always uses the same one you do — \
                a systemd --user service inherits the user manager's \
                environment, not your shell's, so XDG_STATE_HOME and \
                RESTIC_STATION_DATA_DIR would otherwise not reach the tick. \
                No secrets are ever written into a unit file or an \
                EnvironmentFile.
                """
        )

        @Option(
            name: .long,
            help: "Minutes between ticks (default 2, matching the macOS LaunchAgent's StartInterval)."
        )
        var interval: Int = SystemdCommand.defaultIntervalMinutes

        func validate() throws {
            // A sub-minute interval is not expressible here and would be
            // pointless anyway (the tick's own due computation is what
            // decides whether anything runs); a day is a generous ceiling
            // that still catches a typo like `--interval 20000`.
            guard (1...1440).contains(interval) else {
                throw ValidationError("--interval must be between 1 and 1440 minutes; got \(interval)")
            }
        }

        func run() async throws {
            let helperPath: String
            do {
                helperPath = try HelperSelfPath.resolve()
            } catch {
                HelperExit.fail("\(error)")
            }

            // The *resolved* root, not `RESTIC_STATION_DATA_DIR` as found in
            // the environment. `AppPaths.default()` is the whole override
            // chain — the env var, then `$XDG_STATE_HOME/restic-station`,
            // then `~/.local/state/restic-station` — and it is what every
            // other command in this binary reads. Forwarding only the env var
            // (issue #48) meant a host with a custom XDG_STATE_HOME installed
            // a timer pointing at a data directory that has no config in it,
            // and then backed nothing up without ever failing.
            let dataDirectory = AppPaths.default().root.path
            do {
                try await TimerCommand.makeManager().install(
                    helperPath: helperPath,
                    intervalMinutes: interval,
                    dataDirectory: dataDirectory,
                    log: { print($0) }
                )
            } catch {
                HelperExit.fail("\(error)")
            }
            HelperExit.code(0)
        }
    }
}

// MARK: - timer uninstall

extension TimerCommand {

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Disable the timer and remove both units. Idempotent — exits 0 when "
                + "nothing is installed. Exit 0 ok, 1 error."
        )

        func run() async throws {
            do {
                try await TimerCommand.makeManager().uninstall(log: { print($0) })
            } catch {
                HelperExit.fail("\(error)")
            }
            HelperExit.code(0)
        }
    }
}

// MARK: - timer status

extension TimerCommand {

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report whether the timer is installed, enabled, active and when it next fires, "
                + "plus what the tick has been doing. Exit 0 when scheduled backups will happen, "
                + "1 otherwise (so it can be used as a health check).",
            discussion: """
                Exit 1 covers every way this host can stop backing up on a \
                schedule, not just a missing unit: no systemd, units missing \
                or half-deleted, the timer not enabled or not active, \
                lingering disabled (the timer dies at logout), or a \
                config.json that will not load (every tick would fail on it). \
                The VERDICT block at the end of the output lists exactly \
                which of those applied.

                One deliberate exception: a linger state of "unknown" — \
                loginctl is absent and /var/lib/systemd/linger cannot be \
                read, as inside a container with no logind — does not fail. \
                Nothing logs out of such a host, so failing would make this \
                check permanently red for no reachable fix.
                """
        )

        func run() async throws {
            let paths = AppPaths.default()
            // Best-effort on `helperPath`: it is only used to print a
            // copy-pasteable cron line on a host with no systemd, so an
            // unresolvable path degrades to a placeholder rather than
            // failing the whole report.
            let health = await TimerCommand.makeManager().status(
                helperPath: try? HelperSelfPath.resolve(),
                dataDirectory: paths.root.path,
                activity: Self.activity(paths: paths),
                log: { print($0) }
            )
            HelperExit.code(health.exitCode)
        }

        /// Reads `state/` and `runs/`. `timer status` must still answer the
        /// scheduling question on a host where nothing has been configured
        /// yet — so an *absent* config is fine and reports no lines — but a
        /// config that is present and will not load is a different animal
        /// and comes back as a `.configUnreadable` problem.
        ///
        /// The distinction is the whole point. `(try? load()) ?? AppConfig()`
        /// turned an unparseable `config.json` into a valid empty one, and
        /// `timer status` printed "no backup sets configured — the tick runs
        /// and exits immediately" and exited 0, on a host where every single
        /// tick was exiting 1 on that same file.
        static func activity(paths: AppPaths) -> TimerActivity {
            var problems: [TimerProblem] = []
            var config = AppConfig()
            do {
                config = try ConfigStore(paths: paths).load()
            } catch {
                problems.append(.configUnreadable)
            }

            let scheduleState: ScheduleState?
            var scheduleStateFailure: ScheduleStateReadFailure?
            switch StateStore(paths: paths).readScheduleStateResult() {
            case .missing:
                scheduleState = nil
            case .valid(let state):
                scheduleState = state
            case .corrupt(let failure):
                scheduleState = nil
                scheduleStateFailure = failure
                problems.append(.scheduleStateUnreadable)
            }

            let recentRuns = (try? RunStore(paths: paths).recentRuns(limit: 1)) ?? []
            var lines = SystemdTimerActivity.lines(
                config: config,
                scheduleState: scheduleState,
                recentRuns: recentRuns,
                now: Date()
            )
            if problems.contains(.configUnreadable) {
                // Replace rather than append: the lines above were derived
                // from an empty stand-in config and describing them as this
                // host's backup sets would be worse than saying nothing.
                lines = ["could not load \(paths.configFile.path) — every tick will fail on it"]
            }
            if let scheduleStateFailure {
                if problems.contains(.configUnreadable) {
                    lines.append(scheduleStateFailure.recoveryMessage)
                } else {
                    // A nil schedule passed to the ordinary renderer means
                    // "never run". Here it means the opposite: an existing
                    // canonical file was rejected, so no derived activity
                    // line is trustworthy enough to keep.
                    lines = [scheduleStateFailure.recoveryMessage]
                }
            }
            return TimerActivity(lines: lines, problems: problems)
        }
    }
}

#endif
