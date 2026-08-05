import ArgumentParser
import Foundation
import ResticStationCore

/// `fda-check [--context launchd|app]` — the Full Disk Access verification
/// probe from `docs/keychain-and-fda.md` §2: attempt
/// `FileManager.contentsOfDirectory` on `~/Library/Safari` (falling back to
/// `~/Library/Mail` if the Safari directory is absent), and record the
/// result to `state/fda-check.json` so both "App" and "Background agent"
/// badges in onboarding can be shown.
///
/// **macOS-only behaviour, present on every platform.** Full Disk Access is
/// a macOS TCC concept; on Linux ordinary file permissions govern access and
/// there is nothing to probe. The subcommand still exists there — so scripts
/// and docs are uniform — but reports "not applicable" and, crucially, does
/// **not** write `state/fda-check.json`. Writing a fake "granted" record
/// would make the file's meaning platform-dependent; an absent file already
/// means "the probe has never run", which every reader treats as *unknown*,
/// never as *denied* (`HealthDerivation.fullDiskAccessDenied(from:)`).
///
/// Does not go through `HelperContext.make()`: no restic path is needed to
/// probe FDA, and this command must succeed even before restic is
/// configured (it's part of onboarding, which runs before that).
struct FdaCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fda-check",
        abstract: "Probe Full Disk Access and record the result to state/fda-check.json "
            + "(macOS only; a no-op elsewhere). Always exits 0."
    )

    @Option(name: .long, help: "Which process context ran the probe: \"launchd\" or \"app\".")
    var context: String = "launchd"

    func run() async throws {
        guard let result = Self.probeAndRecord(
            context: context,
            stateStore: StateStore(paths: AppPaths.default())
        ) else {
            print("full disk access: not applicable on this platform (no TCC outside macOS); "
                + "state/fda-check.json not written.")
            return
        }
        print("full disk access: \(result.hasFullDiskAccess ? "granted" : "not granted") (probed \(result.probedPath), context: \(context))")
    }

    /// Probes and records in one step. Also called by `tick` on every firing,
    /// so the "Background agent" badge always has fresh launchd-context
    /// evidence (docs/keychain-and-fda.md §2 — the app deliberately never
    /// writes this file itself).
    ///
    /// Returns `nil` on non-macOS platforms, having written nothing.
    @discardableResult
    static func probeAndRecord(context: String, stateStore: StateStore) -> FdaCheckResult? {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let safari = home.appendingPathComponent("Library/Safari", isDirectory: true)
        let mail = home.appendingPathComponent("Library/Mail", isDirectory: true)

        let safariExists = FileManager.default.fileExists(atPath: safari.path)
        let probedURL = safariExists ? safari : mail
        let probedPath = safariExists ? "~/Library/Safari" : "~/Library/Mail"
        let hasAccess = (try? FileManager.default.contentsOfDirectory(atPath: probedURL.path)) != nil

        let result = FdaCheckResult(
            checkedAt: Date(),
            hasFullDiskAccess: hasAccess,
            probedPath: probedPath,
            context: context
        )
        do {
            try stateStore.writeFdaCheck(result)
        } catch {
            FileHandle.standardError.write(Data("fda-check: could not write state: \(error)\n".utf8))
        }
        return result
        #else
        _ = context
        _ = stateStore
        return nil
        #endif
    }
}
