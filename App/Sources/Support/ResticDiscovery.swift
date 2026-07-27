import Foundation
import ResticStationCore

/// Finds a usable `restic` binary (`docs/architecture.md` §restic discovery,
/// `docs/restic-cli.md` §version): probe the three package-manager locations
/// first, then whatever the app's inherited `PATH` offers, and validate each
/// candidate by actually running `restic version --json` and comparing the
/// reported version against the documented minimum.
///
/// Three rules this type exists to enforce:
///
/// 1. **A candidate is only "found" if it ran.** Existence and the +x bit are
///    a filter, never the answer: a Homebrew shim for an uninstalled formula,
///    an x86 binary on an Apple-silicon Mac with no Rosetta, or a broken
///    symlink all pass `isExecutableFile` and fail to execute. Everything the
///    UI shows comes from a real `version --json` round trip.
/// 2. **Only absolute paths are ever persisted.** `config.resticPath` is
///    consumed by the *helper*, running from launchd with a minimal
///    environment and an unrelated working directory — a relative path from
///    a `PATH` entry like `.` or `bin` would resolve differently (or
///    dangerously) there, so such entries are skipped outright.
/// 3. **No environment is passed to the probe.** `restic version` needs
///    none, and inheriting the app's environment keeps the probe faithful to
///    how a user would run the binary in a shell.
///
/// Deliberately free of SwiftUI/AppKit imports: the type is plain
/// `Foundation` + Core so it can be exercised (and was, during T18) by a
/// throwaway command-line probe compiled against the real Homebrew restic.
struct ResticDiscovery: Sendable {

    // MARK: - Configuration

    /// Package-manager install locations, in preference order: Homebrew on
    /// Apple silicon, Homebrew on Intel, MacPorts.
    static let wellKnownPaths = [
        "/opt/homebrew/bin/restic",
        "/usr/local/bin/restic",
        "/opt/local/bin/restic"
    ]

    /// The minimum restic the docs require — the first version with the
    /// current exit-code contract (`docs/restic-cli.md` §version).
    ///
    /// Spelled out rather than aliased to `AppModel.minimumResticVersion`
    /// because `AppModel` is `@MainActor` and this type must be usable from
    /// any isolation. The two are asserted equal in
    /// `AppModel.discoverResticBinary()`, so a future edit to one without
    /// the other trips in debug builds instead of quietly disagreeing about
    /// which binaries are acceptable.
    static let minimumVersion = "0.17.0"

    /// Per-candidate probe timeout. Short on purpose: this runs while the
    /// user waits on a Settings pane or the onboarding sheet, and a hung
    /// candidate (a binary on an unresponsive network mount) must not stall
    /// the whole search. `DefaultProcessRunner` SIGINTs, then SIGKILLs.
    static let probeTimeout: TimeInterval = 5

    /// Upper bound on how many candidates are executed in one search, so a
    /// pathological `PATH` (hundreds of entries, e.g. a misconfigured shell
    /// profile) cannot turn discovery into a minute-long stall.
    static let maxCandidates = 24

    /// `PATH` as the app inherited it. Injectable so the candidate list can
    /// be reasoned about without depending on the developer's shell.
    private let environment: [String: String]
    private let runner: any ProcessRunning

    /// `FileManager.default` is used directly rather than injected: it is
    /// not `Sendable`, and this type must be, so it can be handed to a
    /// detached probe task from the main actor.
    private var fileManager: FileManager { .default }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any ProcessRunning = DefaultProcessRunner()
    ) {
        self.environment = environment
        self.runner = runner
    }

    // MARK: - Candidates

    /// The ordered, de-duplicated list of paths worth executing: the three
    /// well-known locations first (so a Homebrew restic wins over whatever a
    /// user's shell profile happens to shadow it with), then one
    /// `<dir>/restic` per `PATH` entry.
    ///
    /// Filtering is intentionally conservative — relative `PATH` entries are
    /// dropped (see rule 2), and only regular executable files survive.
    /// Symlinks are followed for de-duplication only: `/opt/homebrew/bin/restic`
    /// and a `~/bin/restic` symlink pointing at it are the same binary, and
    /// probing both would double the wait for no new information. The
    /// *reported* path stays the one the user would recognize.
    func candidatePaths() -> [String] {
        var ordered: [String] = []
        var seenResolved = Set<String>()

        func consider(_ path: String) {
            guard ordered.count < Self.maxCandidates else { return }
            guard path.hasPrefix("/") else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
            guard fileManager.isExecutableFile(atPath: path) else { return }

            // `resolvingSymlinksInPath` is best-effort de-duplication; if it
            // cannot resolve, the raw path still keys the set.
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard !seenResolved.contains(resolved) else { return }
            seenResolved.insert(resolved)
            ordered.append(path)
        }

        for path in Self.wellKnownPaths {
            consider(path)
        }
        for directory in pathEntries() {
            consider(directory + "/restic")
        }
        return ordered
    }

    /// `PATH` split on `:`, with empty entries (a leading/trailing/doubled
    /// colon, which POSIX shells read as "the current directory") and any
    /// other relative entry discarded, and trailing slashes normalized.
    private func pathEntries() -> [String] {
        guard let path = environment["PATH"], !path.isEmpty else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
            .map { entry in
                var trimmed = entry
                while trimmed.count > 1, trimmed.hasSuffix("/") {
                    trimmed.removeLast()
                }
                return trimmed
            }
    }

    // MARK: - Probing

    /// Runs `<path> version --json` and classifies the result. Used both by
    /// `discover()` and by "Locate manually…", so a hand-picked binary is
    /// held to exactly the same standard as a discovered one.
    func probe(path: String) async -> ResticProbe {
        guard path.hasPrefix("/") else {
            return ResticProbe(path: path, outcome: .unusable(
                reason: "Restic Station needs the full path to the restic binary (starting with “/”)."
            ))
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return ResticProbe(path: path, outcome: .unusable(
                reason: "There is no executable file at \(path)."
            ))
        }

        let result: ProcessResult
        do {
            result = try await runner.run(
                [path, "version", "--json"],
                env: nil,
                currentDirectory: nil,
                onStdoutLine: nil,
                onStderrLine: nil,
                timeout: Self.probeTimeout
            )
        } catch ProcessRunnerError.timeout {
            return ResticProbe(path: path, outcome: .unusable(
                reason: "\(path) did not respond to “restic version” within "
                    + "\(Int(Self.probeTimeout)) seconds."
            ))
        } catch {
            return ResticProbe(path: path, outcome: .unusable(
                reason: "\(path) could not be run: \(error.localizedDescription)"
            ))
        }

        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ResticProbe(path: path, outcome: .unusable(
                reason: stderr.isEmpty
                    ? "\(path) exited \(result.exitCode) when asked for its version."
                    : "\(path) exited \(result.exitCode) when asked for its version: \(stderr)"
            ))
        }

        guard let info = try? parseVersion(result.stdout) else {
            // Something ran and exited 0 but is not restic (a wrapper script,
            // a different tool of the same name). Not a version we can trust.
            return ResticProbe(path: path, outcome: .unusable(
                reason: "\(path) does not look like restic — “restic version --json” "
                    + "produced output Restic Station could not read."
            ))
        }

        return ResticProbe(
            path: path,
            outcome: info.meetsMinimum(Self.minimumVersion)
                ? .ok(version: info.version)
                : .tooOld(version: info.version)
        )
    }

    /// Probes candidates in order and stops at the first one that satisfies
    /// the minimum version.
    ///
    /// A too-old binary is *remembered but not returned early*: the user
    /// deserves "0.16.4 found at /usr/local/bin/restic — 0.17.0+ required"
    /// rather than a bare "not found", and a newer restic further down `PATH`
    /// should still win. Same for unusable candidates, which are reported so
    /// the "found something, couldn't run it" case is never silent.
    func discover() async -> ResticDiscoveryResult {
        var rejected: [ResticProbe] = []
        for path in candidatePaths() {
            let probe = await probe(path: path)
            switch probe.outcome {
            case .ok:
                return ResticDiscoveryResult(chosen: probe, rejected: rejected)
            case .tooOld, .unusable:
                rejected.append(probe)
            }
        }
        return ResticDiscoveryResult(chosen: nil, rejected: rejected)
    }
}

// MARK: - ResticProbe

/// One candidate binary and what running it proved.
struct ResticProbe: Equatable, Sendable {
    let path: String
    let outcome: Outcome

    enum Outcome: Equatable, Sendable {
        /// Ran, reported a version, and meets the minimum.
        case ok(version: String)
        /// Ran and reported a version below `ResticDiscovery.minimumVersion`.
        case tooOld(version: String)
        /// Did not run, or did not produce a version we could parse.
        case unusable(reason: String)
    }

    var version: String? {
        switch outcome {
        case .ok(let version), .tooOld(let version): return version
        case .unusable: return nil
        }
    }

    var isUsable: Bool {
        if case .ok = outcome { return true }
        return false
    }

    /// Maps a probe onto the status vocabulary the Settings chip and the
    /// menu-bar health derivation already speak (`AppModel.resticStatus`).
    var status: ResticStatus {
        switch outcome {
        case .ok(let version):
            return .ok(path: path, version: version)
        case .tooOld(let version):
            return .tooOld(path: path, version: version, minimum: ResticDiscovery.minimumVersion)
        case .unusable(let reason):
            return .unavailable(path: path, reason: reason)
        }
    }
}

// MARK: - ResticDiscoveryResult

struct ResticDiscoveryResult: Equatable, Sendable {
    /// The first candidate that ran and met the minimum version, if any.
    let chosen: ResticProbe?
    /// Candidates that were found and executed but rejected, in probe order
    /// — the raw material for "0.16.4 found, 0.17.0+ required".
    let rejected: [ResticProbe]

    /// The best thing we can say about this search, in the vocabulary of the
    /// Settings chip: a working binary, else the first too-old one we found
    /// (candidates are probed in preference order, so this is the binary the
    /// user is most likely to think of as "their" restic), else the first
    /// unusable candidate, else "nothing on this Mac".
    var status: ResticStatus {
        if let chosen {
            return chosen.status
        }
        let firstTooOld = rejected.first {
            if case .tooOld = $0.outcome { return true }
            return false
        }
        if let firstTooOld {
            return firstTooOld.status
        }
        if let firstUnusable = rejected.first {
            return firstUnusable.status
        }
        return .notConfigured
    }
}
