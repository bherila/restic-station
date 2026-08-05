import ArgumentParser

@main
struct HelperMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restic-station-helper",
        abstract: "Restic Station background helper. "
            + "Exit codes (per-subcommand, see each --help): 0 ok, 1 error, 2 busy, 3 offline (probe-repo only).",
        subcommands: subcommandList
    )

    /// Every subcommand, in the order `--help` lists them.
    ///
    /// `timer` is the one platform-conditional entry: scheduling is
    /// registered by the app on macOS (`SMAppService`) and by the helper
    /// itself on Linux (a systemd `--user` timer), so on macOS the
    /// subcommand is not merely inert — it is absent. A command that exists
    /// and always errors is a worse `--help` than one that is honestly not
    /// there. `fda-check` goes the other way for the opposite reason: it
    /// exists everywhere so scripts stay uniform, and reports "not
    /// applicable" off-macOS.
    private static var subcommandList: [any ParsableCommand.Type] {
        var subcommands: [any ParsableCommand.Type] = [
            Tick.self,
            RunSet.self,
            InitSecondary.self,
            Restore.self,
            ProbeRepo.self,
            Unlock.self,
            FdaCheck.self,
            Secret.self,
            // Hidden from --help (`shouldDisplay: false`): it exists for
            // RESTIC_PASSWORD_COMMAND, not for people.
            PrintPassword.self,
        ]
        #if os(Linux)
        subcommands.append(TimerCommand.self)
        #endif
        subcommands.append(Version.self)
        return subcommands
    }
}
