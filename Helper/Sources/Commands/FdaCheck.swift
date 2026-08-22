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
struct FdaCheck: AsyncParsableCommand, JSONRenderable {
    static let configuration = CommandConfiguration(
        commandName: "fda-check",
        abstract: "Probe Full Disk Access and record the result to state/fda-check.json "
            + "(macOS only; a no-op elsewhere). --json for scripting. Always exits 0."
    )

    @Option(name: .long, help: "Which process context ran the probe: \"launchd\" or \"app\".")
    var context: String = "launchd"

    @Flag(name: .long, help: "Emit JSON. Only JSON reaches stdout in this mode.")
    var json = false

    /// `fda-check --json`'s shape — see `docs/cli-json.md`.
    ///
    /// `applicable: false` off macOS is the machine-readable form of the
    /// human "not applicable" line, and mirrors the file-level rule: an
    /// absent `state/fda-check.json` means *unknown*, never *denied*. A
    /// caller must branch on `applicable` before reading `granted`.
    struct Report: Encodable {
        let applicable: Bool
        let granted: Bool?
        let probedPath: String?
        let checkedAt: Date?
        let context: String

        // Explicit `null` for the three that are absent off macOS — see the
        // encoding convention in `docs/data-model.md`. A missing key and a
        // null one must not be two ways of saying "not applicable".
        private enum CodingKeys: String, CodingKey {
            case applicable, granted, probedPath, checkedAt, context
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(applicable, forKey: .applicable)
            try container.encode(granted, forKey: .granted)
            try container.encode(probedPath, forKey: .probedPath)
            try container.encode(checkedAt, forKey: .checkedAt)
            try container.encode(context, forKey: .context)
        }
    }

    func run() async throws {
        let result = Self.probeAndRecord(
            context: context,
            stateStore: StateStore(paths: AppPaths.default())
        )

        guard json else {
            guard let result else {
                print("full disk access: not applicable on this platform (no TCC outside macOS); "
                    + "state/fda-check.json not written.")
                return
            }
            print("full disk access: \(result.hasFullDiskAccess ? "granted" : "not granted") (probed \(result.probedPath), context: \(context))")
            return
        }

        CLIJSON.print(
            Report(
                applicable: result != nil,
                granted: result?.hasFullDiskAccess,
                probedPath: result?.probedPath,
                checkedAt: result?.checkedAt,
                context: context
            )
        )
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
            StandardStream.write(Data("fda-check: could not write state: \(error)\n".utf8), to: .standardError)
        }
        return result
        #else
        _ = context
        _ = stateStore
        return nil
        #endif
    }
}
