import ArgumentParser

@main
struct HelperMain: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restic-station-helper",
        abstract: "Restic Station background helper.",
        subcommands: [
            Version.self
        ]
    )
}
