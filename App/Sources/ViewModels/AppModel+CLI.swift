import Foundation
import ResticStationCore

/// The model half of the Settings → General "Command line" row
/// (`docs/tasks/T28`, issue #30): whether `restic-station` is on `PATH`,
/// where it resolves to, and install/uninstall actions — the GUI
/// counterpart of `cli install` / `cli uninstall` / `cli status`.
///
/// All the interesting logic is `ResticStationCore.CLIInstaller`, already
/// covered by `CLIInstallerTests` in Core; this file only wires it to the
/// running app's own embedded-helper path. It stays this thin on purpose:
/// Core owns and tests the filesystem decisions, while the App target's
/// projection tests pin the wiring that remains here.
@MainActor
extension AppModel {

    /// Where `cli install` (or this row's button) would point the symlink:
    /// the embedded helper's own resolved path — the same binary
    /// `HelperInvoker` spawns for every manual action, and the same one
    /// `SMAppService`/launchd runs. `resolvingSymlinksInPath()` mirrors what
    /// the helper itself reports about its own location
    /// (`FileSecretStore.currentExecutablePath()` resolves via `realpath`),
    /// so a fresh install from the GUI and a fresh install from `cli
    /// install` agree on the target byte-for-byte.
    var cliInstallTarget: String {
        HelperInvoker.helperURL.resolvingSymlinksInPath().path
    }

    /// Where the GUI's install button would put the symlink for a given
    /// prefix choice. Unlike `cli install`'s own default (`.system`,
    /// `/usr/local/bin` — fine from a Homebrew-provisioned shell), a
    /// Settings row is clicked from a Finder-launched, non-shell process:
    /// on a clean or non-Homebrew Mac `/usr/local/bin` is root-owned or
    /// absent, so a button that always targets it fails there every time.
    /// Callers should default to ``CLIInstaller/recommendedGUIPrefix()``
    /// (`.user`, `~/.local/bin` — never needs elevated privileges) and let
    /// the Settings row offer `.system` as an explicit opt-in.
    func cliInstallDirectory(prefix: CLIInstaller.Prefix) -> URL {
        prefix.directory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Read-only snapshot of the symlink's current state for `prefix`.
    /// Recomputed fresh every time it is read (a handful of syscalls)
    /// rather than cached — the same "just re-probe it" approach
    /// `PermissionsPaneModel` and `appFullDiskAccess` take, since the
    /// ground truth lives on disk and can change behind the app's back (a
    /// user deleting the symlink by hand, or moving the app).
    func cliInstallStatus(prefix: CLIInstaller.Prefix) -> CLIInstaller.Status {
        CLIInstaller.status(
            directory: cliInstallDirectory(prefix: prefix),
            currentTarget: cliInstallTarget,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    /// Installs (or repairs) the `restic-station` symlink at
    /// ``cliInstallDirectory(prefix:)``. Mirrors `cli install`'s contract
    /// exactly — never a copy, refuses rather than overwriting a foreign
    /// entry.
    @discardableResult
    func installCLI(prefix: CLIInstaller.Prefix) -> Result<CLIInstaller.InstallOutcome, Error> {
        Result { try CLIInstaller.install(target: cliInstallTarget, directory: cliInstallDirectory(prefix: prefix)) }
    }

    /// Removes the symlink, if it is one of ours. Idempotent; refuses
    /// (without removing anything) if a foreign file is there instead.
    @discardableResult
    func uninstallCLI(prefix: CLIInstaller.Prefix) -> Result<CLIInstaller.UninstallOutcome, Error> {
        Result {
            try CLIInstaller.uninstall(target: cliInstallTarget, directory: cliInstallDirectory(prefix: prefix))
        }
    }
}
