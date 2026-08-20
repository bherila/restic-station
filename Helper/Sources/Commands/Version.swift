import ArgumentParser
import Foundation

/// `version [--json]` — the helper's own version.
///
/// The one command with no configuration, no state and no restic: an agent
/// calls it first to find out what it is talking to, so it must work on a
/// host where nothing else does.
struct Version: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the helper's version and exit. --json for scripting."
    )

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// The single source of truth for the printed version. The human line
    /// is built from this rather than the other way round, so the two can
    /// never disagree.
    static let name = "restic-station-helper"
    static let version = "0.1.0"

    /// `version --json`'s shape — see `docs/cli-json.md`.
    struct Report: Encodable {
        let name: String
        let version: String
        /// The OS this binary was built for. An agent choosing between
        /// `launchctl` and `systemctl` advice, or deciding whether
        /// `fda-check` means anything here, needs it — and it is otherwise
        /// only inferable from prose.
        let platform: String
    }

    func run() async throws {
        guard json else {
            print("\(Self.name) \(Self.version)")
            return
        }
        CLIJSON.print(
            Report(name: Self.name, version: Self.version, platform: Self.platform)
        )
    }

    static var platform: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown"
        #endif
    }
}
