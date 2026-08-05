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

                If RESTIC_STATION_DATA_DIR is set in the shell you run this \
                from, it is baked into the service unit so the timer uses the \
                same data directory you do. No secrets are ever written into a \
                unit file or an EnvironmentFile.
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

            let dataDirectory = ProcessInfo.processInfo.environment["RESTIC_STATION_DATA_DIR"]
            do {
                try await TimerCommand.makeManager().install(
                    helperPath: helperPath,
                    intervalMinutes: interval,
                    dataDirectory: dataDirectory?.isEmpty == false ? dataDirectory : nil,
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
                + "1 otherwise (so it can be used as a health check)."
        )

        func run() async throws {
            // Best-effort: only used to print a copy-pasteable cron line on a
            // host with no systemd, so an unresolvable path degrades to a
            // placeholder rather than failing the whole report.
            let healthy = await TimerCommand.makeManager().status(
                helperPath: try? HelperSelfPath.resolve(),
                activity: Self.activityLines(),
                log: { print($0) }
            )
            HelperExit.code(healthy ? 0 : 1)
        }

        /// Reads `state/` and `runs/` best-effort: `timer status` must still
        /// answer the scheduling question on a host where nothing has been
        /// configured yet, so every read here degrades to "no lines" rather
        /// than to an error.
        static func activityLines() -> [String] {
            let paths = AppPaths.default()
            let config = (try? ConfigStore(paths: paths).load()) ?? AppConfig()
            let recentRuns = (try? RunStore(paths: paths).recentRuns(limit: 1)) ?? []
            return SystemdTimerActivity.lines(
                config: config,
                scheduleState: StateStore(paths: paths).readScheduleState(),
                recentRuns: recentRuns,
                now: Date()
            )
        }
    }
}

#endif
