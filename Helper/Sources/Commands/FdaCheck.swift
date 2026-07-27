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
/// Does not go through `HelperContext.make()`: no restic path is needed to
/// probe FDA, and this command must succeed even before restic is
/// configured (it's part of onboarding, which runs before that).
struct FdaCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fda-check",
        abstract: "Probe Full Disk Access and record the result to state/fda-check.json. Always exits 0."
    )

    @Option(name: .long, help: "Which process context ran the probe: \"launchd\" or \"app\".")
    var context: String = "launchd"

    func run() async throws {
        let paths = AppPaths.default()
        let stateStore = StateStore(paths: paths)

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

        print("full disk access: \(hasAccess ? "granted" : "not granted") (probed \(probedPath), context: \(context))")
    }
}
