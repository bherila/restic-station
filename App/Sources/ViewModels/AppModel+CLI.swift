import Foundation
import ResticStationCore

/// The model half of the Settings → General "Command line" row
/// (`docs/tasks/T28`, issue #30): whether `restic-station` is on `PATH`,
/// where it resolves to, and install/uninstall actions — the GUI
/// counterpart of `cli install` / `cli uninstall` / `cli status`.
///
/// All the interesting logic is `ResticStationCore.CLIInstaller`, already
/// covered by `CLIInstallerTests` in Core; this file only wires it to the
/// running app's own embedded-helper path. It stays this thin on purpose —
/// the App target has no test target of its own (issue #40), so any real
/// decision belongs in Core, not here.
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

    /// The default, no-privileges-required location — `/usr/local/bin`,
    /// matching `cli install`'s own default (user-writable on a default
    /// macOS install; there is no sandboxing concern here that would make
    /// `--user`'s `~/.local/bin` preferable as the GUI's default).
    var cliInstallDirectory: URL {
        CLIInstaller.Prefix.system.directory(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Read-only snapshot of the symlink's current state. Recomputed fresh
    /// every time it is read (a handful of syscalls) rather than cached —
    /// the same "just re-probe it" approach `PermissionsPaneModel` and
    /// `appFullDiskAccess` take, since the ground truth lives on disk and
    /// can change behind the app's back (a user deleting the symlink by
    /// hand, or moving the app).
    var cliInstallStatus: CLIInstaller.Status {
        CLIInstaller.status(
            directory: cliInstallDirectory,
            currentTarget: cliInstallTarget,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        )
    }

    /// Installs (or repairs) the `restic-station` symlink at
    /// ``cliInstallDirectory``. Mirrors `cli install`'s contract exactly —
    /// never a copy, refuses rather than overwriting a foreign entry.
    @discardableResult
    func installCLI() -> Result<CLIInstaller.InstallOutcome, Error> {
        Result { try CLIInstaller.install(target: cliInstallTarget, directory: cliInstallDirectory) }
    }

    /// Removes the symlink, if it is one of ours. Idempotent; refuses
    /// (without removing anything) if a foreign file is there instead.
    @discardableResult
    func uninstallCLI() -> Result<CLIInstaller.UninstallOutcome, Error> {
        Result { try CLIInstaller.uninstall(directory: cliInstallDirectory) }
    }
}
