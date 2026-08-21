import ArgumentParser
import Foundation
import ResticStationCore

// MARK: - cli

/// `cli install|uninstall|status` — manages the `restic-station` symlink
/// that makes this embedded helper reachable from an ordinary shell
/// (`docs/tasks/T28`, issue #30).
///
/// On macOS this binary ships at
/// `/Applications/Restic Station.app/Contents/MacOS/restic-station-helper`
/// — nobody types that. `cli install` puts a `restic-station` symlink on
/// `PATH` pointing at it. **Always a symlink, never a copy**: `project.yml`
/// embeds and code-signs the helper into the app bundle, and both
/// `SMAppService` registration and Full Disk Access attribution bind to
/// that on-disk path — moving or copying the binary out from under them
/// would break both. A symlink is transparent to both, because the kernel
/// resolves it before anything executes; the running process is the bundle
/// binary itself.
///
/// All the interesting logic is `ResticStationCore.CLIInstaller`, pure
/// filesystem code with no process spawning; this file only wires it to
/// argv and formats the result. The GUI's Settings row
/// (`App/Sources/ViewModels/AppModel+CLI.swift`) calls the same Core type,
/// so the two surfaces cannot drift apart on what "installed" means.
struct Cli: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cli",
        abstract: "Install, remove, or inspect the restic-station PATH symlink for this helper. "
            + "Exit 0 ok, 1 error.",
        subcommands: [
            CliInstall.self,
            CliUninstall.self,
            CliStatus.self,
        ]
    )
}

/// Shared `--user` flag and prefix-directory resolution for all three `cli`
/// subcommands.
struct CliPrefixOptions: ParsableArguments {
    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Install into ~/.local/bin instead of /usr/local/bin. On a clean or Apple Silicon Mac, "
                + "/usr/local/bin is root-owned or doesn't exist at all, so writing there needs sudo — "
                + "a Homebrew-provisioned Intel Mac is the exception, since Homebrew itself owns /usr/local "
                + "there. ~/.local/bin never needs elevated privileges on any Mac, which is why it's also "
                + "the Settings \"Command line\" button's default. Without --user, cli install may need sudo."
        )
    )
    var user = false

    init() {}

    var prefix: CLIInstaller.Prefix { user ? .user : .system }

    var directory: URL {
        prefix.directory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}

// MARK: - cli install

struct CliInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Create (or repair) the restic-station symlink pointing at this binary's current, "
            + "in-bundle location. Never copies, and never overwrites anything that is not one of our "
            + "own symlinks — refuses instead. Exit 0 ok, 1 error."
    )

    @OptionGroup var options: CliPrefixOptions

    func run() async throws {
        let directory = options.directory
        let target = FileSecretStore.currentExecutablePath()
        do {
            let outcome = try CLIInstaller.install(target: target, directory: directory)
            switch outcome {
            case .created(let linkPath):
                print("installed \(linkPath) -> \(target)")
            case .alreadyInstalled(let linkPath):
                print("already installed: \(linkPath) -> \(target)")
            case .repaired(let linkPath, let previousTarget):
                print("repaired \(linkPath): was -> \(previousTarget), now -> \(target)")
            }
        } catch {
            HelperExit.fail("\(error)")
        }
        CliPathWarning.printIfNeeded(directory: directory)
        HelperExit.code(0)
    }
}

// MARK: - cli uninstall

struct CliUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the restic-station symlink, if it is one of ours. Idempotent — removing an "
            + "already-absent symlink succeeds. Refuses (without removing anything) if a foreign file is "
            + "there instead. Exit 0 ok, 1 error."
    )

    @OptionGroup var options: CliPrefixOptions

    func run() async throws {
        let directory = options.directory
        let target = FileSecretStore.currentExecutablePath()
        do {
            let outcome = try CLIInstaller.uninstall(target: target, directory: directory)
            switch outcome {
            case .removed(let linkPath):
                print("removed \(linkPath)")
            case .notInstalled(let linkPath):
                print("not installed: \(linkPath)")
            }
        } catch {
            HelperExit.fail("\(error)")
        }
        HelperExit.code(0)
    }
}

// MARK: - cli status

struct CliStatus: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the restic-station symlink is installed, where it resolves to, and "
            + "whether the install directory is on PATH. --json for scripting. Exit 0 ok."
    )

    @OptionGroup var options: CliPrefixOptions

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    func run() async throws {
        let directory = options.directory
        let target = FileSecretStore.currentExecutablePath()
        let status = CLIInstaller.status(
            directory: directory,
            currentTarget: target,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        )

        if json {
            // `CLIInstaller.Status` is already the model the human renderer
            // reads; emitting it directly is what keeps the two from
            // drifting, rather than re-deriving the same booleans here.
            CLIJSON.print(status)
            HelperExit.code(0)
        }

        if status.installed {
            let staleness = status.upToDate
                ? ""
                : " (stale — points at \(status.resolvedTarget ?? "?"), not this binary; run `cli install` to repair)"
            print("installed: \(status.linkPath) -> \(status.resolvedTarget ?? "?")\(staleness)")
        } else if status.foreignEntryPresent {
            print("not installed: \(status.linkPath) exists but is not a restic-station symlink")
        } else {
            print("not installed: \(status.linkPath)")
        }
        CliPathWarning.printIfNeeded(directory: directory)
        HelperExit.code(0)
    }
}

// MARK: - PATH warning

/// Shared by `install` and `status`: a symlink nobody's shell can find is
/// half of a fix. Printed to stderr so it does not corrupt `--json`-free
/// stdout output that a script might parse.
enum CliPathWarning {
    static func printIfNeeded(directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !CLIInstaller.isDirectoryOnPath(directory, pathEnvironment: environment["PATH"]) else {
            return
        }
        StandardStream.writeToStandardError(Data(
            ("warning: \(directory.path) is not on PATH — add it to your shell profile, e.g. "
                + "`export PATH=\"\(directory.path):$PATH\"`, so restic-station is found.\n").utf8
        ))
    }
}
