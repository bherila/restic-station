import Foundation

/// **Restic Station never schedules anything itself.** It registers with the
/// host's own scheduler and lets that scheduler fire
/// `restic-station-helper tick` on an interval; everything interesting —
/// due-ness, catch-up after downtime, "backup wins over check" — is decided
/// *inside* the tick from `state/schedule-state.json` (`docs/scheduling.md`
/// §Tick algorithm). The scheduler only has to fire often enough.
///
/// There are two such schedulers, and which one a build talks to is a
/// compile-time fact, not a runtime one:
///
/// | platform | scheduler | registered by | vocabulary below |
/// |---|---|---|---|
/// | macOS | launchd (`StartInterval`) | the app, via `SMAppService` (`App/Sources/Support/LaunchdManager.swift`) | `LaunchctlCommand` |
/// | Linux | systemd `--user` timer | the helper, via `timer install` (`Helper/Sources/SystemdTimerManager.swift`) | `SystemdCommand` |
///
/// This file holds the **pure** half of both: argv arrays and unit text, no
/// `Process`, no filesystem. That is why it lives in Core at all — the
/// spelling of a scheduler's command line is a runtime bug no compiler can
/// catch (the two sides only meet across an `execve`), so it is pinned by
/// unit tests instead of eyeballed. The platform-specific driver on each
/// side is then a thin spawn-and-report shell over these values.
///
/// The two halves are conditionally compiled rather than both built
/// everywhere. `LaunchctlCommand` used to be compiled into Core on Linux
/// too — harmless in that nothing called it, but it left the portable layer
/// carrying one platform's vocabulary and no sign that a second platform
/// existed. The `#if`s below are the whole split: Core now says out loud
/// that scheduling is per-platform, and neither platform's vocabulary can
/// drift into code that runs on the other.

#if os(macOS)

// MARK: - launchd (macOS)

/// `launchctl` invocations the app makes. Pure argv construction, kept here
/// so `docs/keychain-and-fda.md` §3's "kickstart argv exactly
/// `gui/<uid>/<label>`, no `-k` by default" rule is unit-tested rather than
/// eyeballed.
public enum LaunchctlCommand {
    public static let executablePath = "/bin/launchctl"

    /// The LaunchAgent's label. MUST equal the embedded plist's filename
    /// minus `.plist` (`docs/scheduling.md` §plist) — see
    /// `App/Resources/net.herila.ResticStation.helper.plist`.
    public static let helperLabel = "net.herila.ResticStation.helper"
    public static let helperPlistName = "net.herila.ResticStation.helper.plist"

    /// `kickstart [-k] gui/<uid>/<label>` — arguments only, excluding
    /// `executablePath`.
    ///
    /// - Parameter restart: `-k` kills a running instance first. **Only**
    ///   for the FDA re-check flow: the default path must never interrupt a
    ///   backup that is already running (on a busy service, plain
    ///   `kickstart` is a no-op).
    public static func kickstartArgv(
        label: String = helperLabel,
        uid: UInt32,
        restart: Bool = false
    ) -> [String] {
        var argv = ["kickstart"]
        if restart {
            argv.append("-k")
        }
        argv.append("gui/\(uid)/\(label)")
        return argv
    }

    /// `print gui/<uid>/<label>` — exits zero only while launchd has the
    /// agent loaded. This is the helper CLI's scheduler-health probe; unlike
    /// `SMAppService.status`, it does not require running inside the app.
    public static func printArgv(
        label: String = helperLabel,
        uid: UInt32
    ) -> [String] {
        ["print", "gui/\(uid)/\(label)"]
    }
}

#endif

#if os(Linux)

// MARK: - systemd (Linux)

/// The systemd `--user` half of the split described at the top of this file:
/// the two unit files `restic-station-helper timer install` writes, and the
/// `systemctl`/`loginctl` argv it runs. Everything here is a pure function
/// of its arguments — `SystemdTimerManager` in the helper does the writing
/// and the spawning.
///
/// **User units, never system units.** The helper reads `$HOME`-scoped state
/// (`AppPaths.default()` resolves under `$XDG_STATE_HOME`) and secrets that
/// are `0600` and owned by one user. A root-run system unit would resolve a
/// different data directory *and* be unable to read the secrets it found —
/// two failure modes for zero benefit, since nothing the tick does needs
/// privilege.
public enum SystemdCommand {

    // MARK: - Unit identity

    public static let serviceUnitName = "restic-station.service"
    public static let timerUnitName = "restic-station.timer"

    /// Matches launchd's `StartInterval` of 120s, so the two platforms fire
    /// the same tick at the same cadence (`docs/scheduling.md` §plist).
    public static let defaultIntervalMinutes = 2

    /// Where user units live. Per the XDG Base Directory Specification and
    /// `systemd.unit(5)`: `$XDG_CONFIG_HOME/systemd/user`, falling back to
    /// `~/.config/systemd/user`. As in `AppPaths.xdgBaseDirectory`, the
    /// variable is honoured only when set, non-empty **and** absolute.
    public static func userUnitDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        let base: URL
        if let value = environment["XDG_CONFIG_HOME"], !value.isEmpty, value.hasPrefix("/") {
            base = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            base = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        return base
            .appendingPathComponent("systemd", isDirectory: true)
            .appendingPathComponent("user", isDirectory: true)
    }

    // MARK: - Unit rendering

    /// The placeholder the shipped template in `packaging/linux/systemd/`
    /// carries in place of a real path. Nothing hard-codes an install
    /// prefix: `timer install` substitutes the helper's own `/proc/self/exe`.
    public static let helperPathPlaceholder = "<HELPER_PATH>"

    /// `restic-station.service` — the unit the timer activates.
    ///
    /// `Type=oneshot` because the tick is a batch job that exits, not a
    /// daemon: systemd then considers the "start" to last until the tick
    /// finishes, which is what makes `OnUnitActiveSec=` measure from the
    /// *start* of the previous tick rather than overlapping ticks.
    ///
    /// There is deliberately **no** `Restart=`. A timer-driven oneshot that
    /// restarts on failure would retry a failing backup every few seconds
    /// forever; the tick's own contract is to exit 0 on everything except a
    /// hard config-load error, and a genuinely failing set is retried at its
    /// next scheduled slot (`docs/scheduling.md` §Due computation), not
    /// immediately.
    ///
    /// There is also no `[Install]` section: the service is activated by the
    /// timer, and enabling it directly would run one tick at every boot and
    /// then never again.
    ///
    /// - Parameter dataDirectory: the **resolved absolute** data directory
    ///   this install is running against — `AppPaths.default().root.path`,
    ///   not whatever `RESTIC_STATION_DATA_DIR` happened to be exported.
    ///
    ///   A `systemd --user` service runs under the per-user *manager's*
    ///   environment, which is whatever the manager started with at
    ///   login/boot; it has no reason to contain a variable a shell profile
    ///   exports for interactive shells. So a unit that leaves the data
    ///   directory to be re-derived at tick time is a unit that resolves a
    ///   *different* directory from the one the person installing it was
    ///   looking at — most easily via `XDG_STATE_HOME`, which
    ///   `AppPaths.default()` honours and which nothing used to forward
    ///   (issue #48). The tick then finds no `config.json`, loads a valid
    ///   empty `AppConfig()`, has nothing to back up and exits 0: backups
    ///   stop, and it is indistinguishable from "nothing was due".
    ///
    ///   Baking the resolved path in unconditionally removes the whole
    ///   class. It also makes the unit self-documenting — `systemctl --user
    ///   cat restic-station.service` says which data directory this timer
    ///   drives, instead of leaving it to be guessed.
    ///
    ///   `nil` is still accepted so the shipped template in
    ///   `packaging/linux/systemd/` can render without one, but
    ///   `timer install` always passes a value.
    ///
    ///   **No secrets are ever written into a unit or an `EnvironmentFile`**
    ///   — restic credentials come from the secret store at run time
    ///   (`docs/keychain-and-fda.md`), and a unit file is world-readable.
    public static func serviceUnit(helperPath: String, dataDirectory: String? = nil) -> String {
        var lines = [
            "# restic-station.service — installed by `restic-station-helper timer install`",
            "# (docs/scheduling.md §Linux: systemd user timer). Re-running the command",
            "# overwrites this file; hand edits survive only until then.",
            "[Unit]",
            "Description=Restic Station scheduling tick",
            "Documentation=https://github.com/bherila/restic-station/blob/main/docs/scheduling.md",
            "",
            "[Service]",
            "Type=oneshot",
            "ExecStart=\(quoteIfNeeded(helperPath)) tick",
        ]
        if let dataDirectory, !dataDirectory.isEmpty {
            lines.append("# The data directory `timer install` resolved, pinned here on purpose: a")
            lines.append("# --user service inherits the systemd user manager's environment, not the")
            lines.append("# shell's, so XDG_STATE_HOME and friends do not reach the tick.")
            // `specifierEscaped` before `quoted`: systemd expands `%h`, `%t`
            // and friends inside unit values *including* inside quotes
            // (`systemd.unit(5)` §Specifiers), so a data directory
            // containing a literal `%` is silently rewritten — `/srv/%home`
            // becomes `/srv/<the user's home dir>ome` — or, for an unknown
            // sequence, makes systemd drop the whole assignment with
            // "Failed to resolve specifiers … ignoring". Either way
            // `timer install` reports success and the timer ticks against
            // the wrong directory, which is the exact silent-stop this
            // pinning exists to prevent (`@codex review` on #51).
            lines.append("Environment=\(quoted(specifierEscaped("RESTIC_STATION_DATA_DIR=\(dataDirectory)")))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `restic-station.timer` — what actually fires the tick.
    ///
    /// `OnBootSec=` + `OnUnitActiveSec=` are *monotonic* triggers: the first
    /// tick lands `interval` after boot, and every later one `interval`
    /// after the previous tick started. That pairing is what gives Linux the
    /// same post-downtime behaviour macOS gets from launchd coalescing
    /// missed `StartInterval` fires into one fire on wake — a machine that
    /// was off for a week ticks once, shortly after it comes back, and the
    /// tick then finds every set overdue from `schedule-state.json`.
    ///
    /// `Persistent=true` is the anacron switch and is kept deliberately, but
    /// see the comment it is rendered with: `systemd.timer(5)` scopes its
    /// effect to `OnCalendar=` timers, so with the monotonic pair above the
    /// catch-up is really `OnBootSec=`'s doing.
    public static func timerUnit(intervalMinutes: Int = defaultIntervalMinutes) -> String {
        let interval = duration(minutes: intervalMinutes)
        return ([
            "# restic-station.timer — installed by `restic-station-helper timer install`",
            "# (docs/scheduling.md §Linux: systemd user timer). Re-running the command",
            "# overwrites this file; hand edits survive only until then.",
            "[Unit]",
            "Description=Restic Station scheduling tick every \(interval)",
            "Documentation=https://github.com/bherila/restic-station/blob/main/docs/scheduling.md",
            "",
            "[Timer]",
            "Unit=\(serviceUnitName)",
            "# First tick shortly after boot, then one every interval measured from",
            "# the previous tick's start. A tick that outlives the interval simply",
            "# delays the next one; it never overlaps (Type=oneshot, plus tick.lock).",
            "OnBootSec=\(interval)",
            "OnUnitActiveSec=\(interval)",
            "# Keep the advertised cadence tight. systemd's 1min default AccuracySec",
            "# may otherwise turn a 2min interval into nearly 3min through coalescing.",
            "AccuracySec=1s",
            "# systemd.timer(5) scopes Persistent= to OnCalendar= timers, so with the",
            "# monotonic pair above the post-downtime catch-up is OnBootSec='s doing,",
            "# not this line's. It is kept because it states the intent (missed runs",
            "# are caught up, never skipped) and is the switch that carries that",
            "# intent unchanged if the interval is ever expressed as a calendar",
            "# expression. Do not remove it as \"dead\" — see docs/scheduling.md §Linux.",
            "Persistent=true",
            "",
            "[Install]",
            "WantedBy=timers.target",
        ] as [String]).joined(separator: "\n") + "\n"
    }

    /// systemd time spans (`systemd.time(7)`) — `2min`, `15min`, `90min`.
    public static func duration(minutes: Int) -> String {
        "\(minutes)min"
    }

    // MARK: - systemctl / loginctl argv

    /// Absolute locations to try before falling back to a `PATH` search.
    /// `/usr/bin` first: on a merged-`/usr` distribution `/bin` is a symlink
    /// to it, and on a split one systemd installs to `/usr/bin` anyway.
    public static let systemctlWellKnownPaths = ["/usr/bin/systemctl", "/bin/systemctl"]
    public static let loginctlWellKnownPaths = ["/usr/bin/loginctl", "/bin/loginctl"]

    /// `sd_booted(3)`'s test: this directory exists iff the running init is
    /// systemd. A container image can perfectly well ship `systemctl` while
    /// PID 1 is something else entirely.
    public static let systemdRunDirectory = "/run/systemd/system"

    /// Where `loginctl enable-linger` records its decision. Read directly as
    /// a fallback when `loginctl` itself is unavailable — it *is* the
    /// mechanism, not a cache of it.
    public static let lingerMarkerDirectory = "/var/lib/systemd/linger"

    public static let daemonReloadArgv = ["--user", "daemon-reload"]
    public static let enableTimerArgv = ["--user", "enable", "--now", SystemdCommand.timerUnitName]
    /// `enable --now` is a no-op for an already-active timer. `timer install`
    /// rewrites both units, so it must restart the timer after daemon-reload
    /// to load the new interval/data directory and reset its monotonic clock.
    public static let restartTimerArgv = ["--user", "restart", SystemdCommand.timerUnitName]
    public static let disableTimerArgv = ["--user", "disable", "--now", SystemdCommand.timerUnitName]
    public static let isEnabledArgv = ["--user", "is-enabled", SystemdCommand.timerUnitName]
    public static let isActiveArgv = ["--user", "is-active", SystemdCommand.timerUnitName]
    /// `--all` so the timer is listed even when it is inactive (otherwise a
    /// disabled timer produces an empty table and `timer status` would have
    /// nothing to explain).
    public static let listTimersArgv = [
        "--user", "list-timers", "--all", "--no-pager", SystemdCommand.timerUnitName,
    ]

    /// `loginctl show-user <user> --property=Linger` → `Linger=yes|no`.
    public static func lingerArgv(user: String) -> [String] {
        ["show-user", user, "--property=Linger"]
    }

    /// The exact command a user must run to fix a disabled linger. Never run
    /// for them: it needs root, and a backup tool that silently escalates
    /// privilege is a worse bug than one that prints a line.
    public static func enableLingerCommandLine(user: String) -> String {
        "sudo loginctl enable-linger \(user)"
    }

    /// The documented cron fallback for hosts with no systemd
    /// (`docs/scheduling.md` §Linux). One crontab line, no tooling.
    ///
    /// Carries the resolved data directory for exactly the reason
    /// `serviceUnit(helperPath:dataDirectory:)` does, and rather more
    /// urgently: cron runs jobs with a famously minimal environment (`HOME`,
    /// `PATH`, `SHELL`, `LOGNAME` and little else — no profile is sourced at
    /// all), so a bare `helper tick` in a crontab resolves the *default* data
    /// directory no matter what the shell that wrote the line had set.
    ///
    /// The assignment is written inline before the command because cron hands
    /// the whole command to `/bin/sh`, where `VAR=value cmd` is ordinary
    /// one-command-scoped assignment. A crontab-level `VAR=value` line would
    /// also work but applies to every job in the file, which is not ours to
    /// change. Percent signs do not require that global escape hatch:
    /// ``cronEscaped(_:)`` encodes the complete command field before cron
    /// passes it to the shell.
    public static func cronFallbackLine(
        helperPath: String,
        intervalMinutes: Int = defaultIntervalMinutes,
        dataDirectory: String? = nil
    ) -> String {
        var command = "\(shellQuoteIfNeeded(helperPath)) tick"
        if let dataDirectory, !dataDirectory.isEmpty {
            command = "RESTIC_STATION_DATA_DIR=\(shellQuoteIfNeeded(dataDirectory)) \(command)"
        }
        return "*/\(intervalMinutes) * * * * \(cronEscaped(command))"
    }

    // MARK: - Quoting

    /// systemd's own quoting rules (`systemd.syntax(7)`): a value containing
    /// whitespace or a quote has to be quoted, and inside quotes `\` and `"`
    /// are escaped with a backslash. Paths with spaces are rare on Linux but
    /// a silently mis-rendered `ExecStart=` is a scheduled backup that never
    /// runs, which is exactly the failure this project exists to prevent.
    static func quoteIfNeeded(_ value: String) -> String {
        let needsQuoting = value.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" || $0 == "\\" })
        return needsQuoting ? quoted(value) : value
    }

    /// `%%` is systemd's escape for a literal percent sign
    /// (`systemd.unit(5)` §Specifiers). Applied *before* `quoted`, since
    /// quoting does not disable specifier expansion.
    static func specifierEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%%")
    }

    static func quoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\\" || character == "\"" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    /// POSIX-shell quoting for the cron line, which cron hands to `/bin/sh`.
    /// The rule is shared with every other command this project prints for a
    /// human to paste — see `ShellQuoting`.
    static func shellQuoteIfNeeded(_ value: String) -> String {
        ShellQuoting.quoteIfNeeded(value)
    }

    /// Encodes a shell command for Vixie cron's command-field scanner.
    ///
    /// The scanner in Vixie cron 3.0pl1's `do_command.c` turns `\\` into `\`,
    /// turns `\%` into `%`, and splits the command at an unescaped `%`. Both
    /// characters therefore need encoding: double every literal backslash
    /// and prefix every literal percent with a backslash. Encoding only `%`
    /// is insufficient when the shell-quoted command already has a backslash
    /// immediately before it: the resulting `\\%` is decoded as one literal
    /// backslash followed by an unescaped delimiter.
    static func cronEscaped(_ command: String) -> String {
        var escaped = ""
        for character in command {
            if character == "\\" || character == "%" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}

#endif
