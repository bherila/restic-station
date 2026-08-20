import Foundation
import ResticStationCore

/// Spawns the embedded `restic-station-helper` for **manual** actions —
/// "Back Up Now", prune, check, init a secondary, probe a repo, restore,
/// and the app-spawned FDA probe (`docs/tasks/T11-launchd.md`).
///
/// Three rules this type exists to enforce:
///
/// 1. **argv comes from Core.** Every invocation is a `HelperCommand`,
///    whose `argv` is pinned by `HelperCommandTests`. Nothing here builds
///    flag strings.
/// 2. **Nothing blocks the UI.** All methods are `async` and non-isolated,
///    so a `Task { await invoker.backUpNow(...) }` from a `@MainActor` view
///    runs the wait off the main actor. A backup can take hours; there is
///    deliberately **no timeout** (the user cancels by other means, and the
///    helper's own locks prevent pile-ups).
/// 3. **Progress does not come from here.** Only the helper's short final
///    result line is captured. Live progress reaches the UI through
///    `state/` + `runs/`, watched by `StateWatcher` — see
///    `docs/architecture.md` §Process model.
///
/// Direct `Process` use is fine in the App target (Core's
/// `ProcessRunning`-injection rule exists for testability of Core); it is
/// confined to this one file.
public struct HelperInvoker: Sendable {
    /// `Restic Station.app/Contents/MacOS/restic-station-helper` — the
    /// helper is embedded next to the app binary (see `project.yml`:
    /// `copy: destination: executables`), which is also what the
    /// LaunchAgent plist's `BundleProgram` points at.
    public static var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("restic-station-helper", isDirectory: false)
    }

    private let helperURL: URL

    public init(helperURL: URL = HelperInvoker.helperURL) {
        self.helperURL = helperURL
    }

    // MARK: - Actions

    /// `run-set --set <id> --kind backup`. Exit 2 (`.busy`) means another
    /// operation for this set is already running — surface "already
    /// running", not an error.
    public func backUpNow(setId: UUID) async -> HelperResult {
        await run(.backUpNow(setId: setId))
    }

    public func prune(setId: UUID) async -> HelperResult {
        await run(.prune(setId: setId))
    }

    /// Reclaims unused packs without applying retention. The helper owns the
    /// lock, mirror-freshness guard, reachability probe, and run record.
    public func pruneRepository(
        setId: UUID,
        destId: UUID?,
        dryRun: Bool,
        expectedDestination: String? = nil
    ) async -> HelperResult {
        await run(.maintenancePrune(
            setId: setId,
            destId: destId,
            expectedDestination: expectedDestination,
            dryRun: dryRun
        ))
    }

    /// Runs the non-mutating reclaim preview and decodes the opaque binding
    /// that only the helper can construct from the effective destination and
    /// its secret environment. Confirmation returns that binding to the
    /// helper, which revalidates it after reloading configuration.
    func previewReclaimSpace(setId: UUID, destId: UUID) async -> ReclaimPreviewResult {
        let result = await run(.maintenancePrune(
            setId: setId,
            destId: destId,
            expectedDestination: nil,
            dryRun: true,
            json: true
        ))
        guard case .ok(let output) = result else {
            return ReclaimPreviewResult(result: Self.humanResult(result), confirmationBinding: nil)
        }
        guard let decoded = try? JSONDecoder().decode(ReclaimPreviewEnvelope.self, from: Data(output.utf8)),
              decoded.ok,
              let binding = decoded.data.confirmationBinding,
              !binding.isEmpty else {
            return ReclaimPreviewResult(
                result: .failed(output: "The reclaim preview did not return a confirmation binding. Run a new preview before reclaiming space."),
                confirmationBinding: nil
            )
        }
        return ReclaimPreviewResult(result: .ok(output: decoded.data.summary), confirmationBinding: binding)
    }

    public func check(setId: UUID) async -> HelperResult {
        await run(.check(setId: setId))
    }

    /// `restic init --from-repo` against a freshly added secondary.
    public func initSecondary(setId: UUID, destId: UUID) async -> HelperResult {
        await run(.initSecondary(setId: setId, destId: destId))
    }

    /// On-demand reachability probe. `.offline` here is a normal,
    /// non-error outcome (unplugged drive, network down); the helper has
    /// already written `state/repo-status-<destId>.json`, so the UI's own
    /// refresh comes through `StateWatcher`.
    public func probeRepo(setId: UUID, destId: UUID) async -> HelperResult {
        await run(.probeRepo(setId: setId, destId: destId))
    }

    public func restore(_ request: HelperRestoreArgs) async -> HelperResult {
        await run(.restore(request))
    }

    /// The **app-spawned** Full Disk Access probe. Distinct from both the
    /// in-process app probe and the launchd-context probe (which is
    /// triggered with `LaunchdManager.kickstartTick(restart: true)`), so
    /// the `context` label recorded in `state/fda-check.json` says which
    /// one wrote it — a helper spawned by the app inherits the app's TCC
    /// responsibility, which is exactly the thing that can differ from the
    /// launchd case (`docs/keychain-and-fda.md` §2).
    public func fdaCheck(context: String = "app-spawned") async -> HelperResult {
        await run(.fdaCheck(context: context))
    }

    public func version() async -> HelperResult {
        await run(.version)
    }

    // MARK: - Spawn

    /// Runs one `HelperCommand` to completion and maps its exit status
    /// through the T10 contract. Never throws: every failure mode becomes
    /// a `HelperResult` the UI can render.
    func run(_ command: HelperCommand) async -> HelperResult {
        let executable = helperURL
        return await withCheckedContinuation { (continuation: CheckedContinuation<HelperResult, Never>) in
            // The whole spawn + drain + wait happens on a utility queue:
            // `waitUntilExit()` blocks its thread, so it must never run on
            // a Swift-concurrency cooperative thread (or the main one).
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(executable: executable, command: command))
            }
        }
    }

    private static func runBlocking(executable: URL, command: HelperCommand) -> HelperResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failed(output: "The Restic Station helper is missing from this copy of the app "
                + "(expected at \(executable.path)). Reinstall Restic Station.")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = command.argv
        // Environment is inherited on purpose: it carries the developer's
        // `RESTIC_STATION_DATA_DIR` override (see `AppPaths.default()`) so
        // an app run against a scratch data dir spawns a helper against the
        // same one. Nothing secret is passed this way — repo passwords come
        // from the keychain, inside the helper.

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failed(output: "Could not start the helper: \(error.localizedDescription)")
        }

        // Both pipes are drained concurrently: a helper that writes enough
        // to fill one pipe's buffer while we serially read the other would
        // deadlock. Output is small by design (one result line) — this is
        // belt-and-braces, and costs one extra queue hop.
        let group = DispatchGroup()
        let collector = OutputCollector()
        for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
            let box = PipeBox(pipe: pipe)
            DispatchQueue.global(qos: .utility).async(group: group) {
                let data = box.pipe.fileHandleForReading.readDataToEndOfFile()
                collector.store(data, isStdout: isStdout)
            }
        }
        group.wait()
        process.waitUntilExit()

        let output = collector.combinedText()

        // A signalled process reports the *signal number* in
        // `terminationStatus` on Darwin — without this check a helper
        // killed by SIGINT (2) would be misread as the contract's exit 2
        // ("busy"), and SIGQUIT (3) as "offline".
        if process.terminationReason == .uncaughtSignal {
            let detail = output.isEmpty ? "" : "\n\(output)"
            return .failed(output: "The helper was terminated by signal \(process.terminationStatus).\(detail)")
        }

        switch HelperExitCode.interpret(process.terminationStatus) {
        case .ok:
            return .ok(output: output)
        case .busy:
            return .busy
        case .offline:
            return .offline(output: output)
        case .failed:
            return .failed(output: output.isEmpty
                ? "The helper failed (exit \(process.terminationStatus))."
                : output)
        }
    }
}

struct ReclaimPreviewResult: Sendable {
    let result: HelperResult
    let confirmationBinding: String?
}

private extension HelperInvoker {
    struct ReclaimPreviewEnvelope: Decodable {
        let ok: Bool
        let data: Data

        struct Data: Decodable {
            let label: String
            let dryRun: Bool
            let status: RunStatus
            let confirmationBinding: String?

            var summary: String {
                let qualifier = dryRun ? "dry run " : ""
                return "\"\(label)\": prune \(qualifier)\(status.rawValue)"
            }
        }
    }

    struct JSONFailureEnvelope: Decodable {
        let error: Error

        struct Error: Decodable {
            let message: String
        }
    }

    static func humanResult(_ result: HelperResult) -> HelperResult {
        func message(_ output: String) -> String {
            (try? JSONDecoder().decode(JSONFailureEnvelope.self, from: Data(output.utf8)))?.error.message ?? output
        }
        return switch result {
        case .ok: result
        case .busy: result
        case .offline(let output): .offline(output: message(output))
        case .failed(let output): .failed(output: message(output))
        }
    }
}

// MARK: - HelperResult

/// The App-facing outcome of a helper invocation: the T10 exit-code
/// contract plus whatever the helper printed as its final line.
///
/// `.offline` extends the three cases sketched in `T11-launchd.md`
/// (ok/busy/failed) because the merged helper's contract has a fourth exit
/// code — `probe-repo`'s exit 3. Folding it into `.failed` would make an
/// unplugged external drive (an expected, non-error state that the UI shows
/// as a grey/"offline" badge) indistinguishable from a real probe error.
public enum HelperResult: Equatable, Sendable {
    /// Exit 0. `output` is the helper's final human-readable line.
    case ok(output: String)
    /// Exit 2 — another operation for this set is already running.
    case busy
    /// Exit 3 — `probe-repo` found the destination unreachable.
    case offline(output: String)
    /// Exit 1, any off-contract exit code, a signal, or a launch failure.
    case failed(output: String)

    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }

    /// A single line suitable for a status label. `.busy` has no helper
    /// output of its own (the message lives on stderr with exit 2, but the
    /// phrasing belongs to the UI), so it gets a fixed string.
    public var message: String {
        switch self {
        case .ok(let output): return output
        case .busy: return "Another operation for this backup set is already running."
        case .offline(let output): return output
        case .failed(let output): return output
        }
    }
}

// MARK: - Plumbing

/// `Pipe` is not `Sendable`, but each one is handed to exactly one queue
/// and read there and nowhere else (same reasoning as
/// `DefaultProcessRunner`'s `PipeBox` in Core).
private struct PipeBox: @unchecked Sendable {
    let pipe: Pipe
}

/// Accumulates the two pipe reads from their respective queues.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func store(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout {
            stdout.append(data)
        } else {
            stderr.append(data)
        }
    }

    /// stdout then stderr, trimmed. Both matter: subcommands print their
    /// success line to stdout, while `HelperExit.fail` writes the failure
    /// reason to stderr.
    func combinedText() -> String {
        lock.lock()
        defer { lock.unlock() }
        let parts = [stdout, stderr]
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }
}
