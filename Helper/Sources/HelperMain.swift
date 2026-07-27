import ArgumentParser

@main
struct HelperMain: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restic-station-helper",
        abstract: "Restic Station background helper. "
            + "Exit codes (per-subcommand, see each --help): 0 ok, 1 error, 2 busy, 3 offline (probe-repo only).",
        subcommands: [
            Tick.self,
            RunSet.self,
            InitSecondary.self,
            Restore.self,
            ProbeRepo.self,
            FdaCheck.self,
            Version.self,
        ]
    )
}
