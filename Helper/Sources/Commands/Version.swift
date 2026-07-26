import ArgumentParser

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the helper's version and exit."
    )

    func run() throws {
        print("restic-station-helper 0.1.0")
    }
}
