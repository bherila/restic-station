import Foundation

/// Finds a usable `restic` binary (`docs/architecture.md` §restic discovery,
/// `docs/restic-cli.md` §version): probe the package-manager locations for
/// this platform first, then whatever `PATH` offers, and validate each
/// candidate by actually running `restic version --json` and comparing the
/// reported version against the documented minimum.
///
/// Lives in Core (moved out of `App/` in T25) because the *helper* needs it
/// too: on a headless Linux host there is no app to open, so
/// `HelperContext.make()` discovers restic itself rather than telling the
/// user to launch a GUI that isn't there.
///
/// Three rules this type exists to enforce:
///
/// 1. **A candidate is only "found" if it ran.** Existence and the +x bit are
///    a filter, never the answer: a Homebrew shim for an uninstalled formula,
///    an x86 binary on an Apple-silicon Mac with no Rosetta, a distro
///    wrapper script for an uninstalled package, or a broken symlink all pass
///    `isExecutableFile` and fail to execute. Everything the UI shows — and
///    everything the helper acts on — comes from a real `version --json`
///    round trip.
/// 2. **Only absolute paths are ever persisted.** A resolved path is consumed
///    by the *helper*, running from launchd/systemd with a minimal
///    environment and an unrelated working directory — a relative path from
///    a `PATH` entry like `.` or `bin` would resolve differently (or
///    dangerously) there, so such entries are skipped outright.
/// 3. **No environment is passed to the probe.** `restic version` needs
///    none, and inheriting the caller's environment keeps the probe faithful
///    to how a user would run the binary in a shell.
///
/// Deliberately free of SwiftUI/AppKit imports: the type is plain
/// `Foundation` + Core so it can be exercised (and was, during T18) by a
/// throwaway command-line probe compiled against the real Homebrew restic.
public struct ResticDiscovery: Sendable {

    // MARK: - Configuration

    /// Package-manager install locations on macOS, in preference order:
    /// Homebrew on Apple silicon, Homebrew on Intel, MacPorts.
    public static let macOSWellKnownPaths = [
        "/opt/homebrew/bin/restic",
        "/usr/local/bin/restic",
        "/opt/local/bin/restic"
    ]

    /// Package-manager install locations on Linux, in preference order:
    /// distro package (`apt`/`dnf`/`pacman` all land in `/usr/bin`), a
    /// locally installed release tarball, and the `/opt` convention some
    /// images use for hand-placed tooling.
    public static let linuxWellKnownPaths = [
        "/usr/bin/restic",
        "/usr/local/bin/restic",
        "/opt/restic/bin/restic"
    ]

    /// The well-known list for the platform this binary was built for.
    /// `PATH` scanning happens on both platforms and is not affected.
    public static var wellKnownPaths: [String] {
        #if os(macOS)
        return macOSWellKnownPaths
        #else
        return linuxWellKnownPaths
        #endif
    }

    /// The minimum restic the docs require — the first version with the
    /// current exit-code contract (`docs/restic-cli.md` §version).
    ///
    /// Spelled out rather than aliased to `AppModel.minimumResticVersion`
    /// because `AppModel` is `@MainActor` and this type must be usable from
    /// any isolation. The two are asserted equal in
    /// `AppModel.discoverResticBinary()`, so a future edit to one without
    /// the other trips in debug builds instead of quietly disagreeing about
    /// which binaries are acceptable.
    public static let minimumVersion = "0.17.0"

    /// Per-candidate probe timeout. Short on purpose: this runs while the
    /// user waits on a Settings pane or the onboarding sheet, and a hung
    /// candidate (a binary on an unresponsive network mount) must not stall
    /// the whole search. `DefaultProcessRunner` SIGINTs, then SIGKILLs.
    public static let probeTimeout: TimeInterval = 5

    /// Upper bound on how many candidates are executed in one search, so a
    /// pathological `PATH` (hundreds of entries, e.g. a misconfigured shell
    /// profile) cannot turn discovery into a minute-long stall.
    public static let maxCandidates = 24

    /// The well-known locations searched ahead of `PATH`. Injectable so the
    /// candidate list can be reasoned about in tests without depending on
    /// what happens to be installed on the machine running them.
    private let wellKnownPaths: [String]

    /// `PATH` as the process inherited it. Injectable so the candidate list
    /// can be reasoned about without depending on the developer's shell.
    private let environment: [String: String]
    private let runner: any ProcessRunning

    /// `FileManager.default` is used directly rather than injected: it is
    /// not `Sendable`, and this type must be, so it can be handed to a
    /// detached probe task from the main actor.
    private var fileManager: FileManager { .default }

    public init(
        wellKnownPaths: [String] = ResticDiscovery.wellKnownPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any ProcessRunning = DefaultProcessRunner()
    ) {
        self.wellKnownPaths = wellKnownPaths
        self.environment = environment
        self.runner = runner
    }

    /// A human-readable list of what a failed search looked at, for the
    /// "restic not found" message the helper prints on a headless host.
    public var searchedDescription: String {
        wellKnownPaths.joined(separator: ", ") + ", and every directory on PATH"
    }

    // MARK: - Candidates

    /// The ordered, de-duplicated list of paths worth executing: the
    /// well-known locations first (so a package-manager restic wins over
    /// whatever a user's shell profile happens to shadow it with), then one
    /// `<dir>/restic` per `PATH` entry.
    ///
    /// Filtering is intentionally conservative — relative `PATH` entries are
    /// dropped (see rule 2), and only regular executable files survive.
    /// Symlinks are followed for de-duplication only: `/opt/homebrew/bin/restic`
    /// and a `~/bin/restic` symlink pointing at it are the same binary, and
    /// probing both would double the wait for no new information. The
    /// *reported* path stays the one the user would recognize.
    public func candidatePaths() -> [String] {
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

        for path in wellKnownPaths {
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
    public func probe(path: String) async -> ResticProbe {
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
            let stderr = Self.summarize(failureOutput: result.stderr)
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

    /// How much of a failed candidate's stderr may appear in a `reason`.
    ///
    /// Bounded because `reason` is *published*: the helper prints it to
    /// stdout from `tick` (journald / launchd logs, permanently, on every
    /// tick) and to stderr from every strict subcommand, and the macOS
    /// Settings pane renders it verbatim. Everything upstream of that is
    /// untrusted output from a binary that is, by definition, not the restic
    /// we were looking for.
    ///
    /// Two separate hazards, both closed by the same cap:
    ///
    /// - **Secrets.** The probe deliberately inherits this process's
    ///   environment (rule 3 above — it keeps the probe faithful to how a
    ///   user would run the binary in a shell, and `ProcessRunning` replaces
    ///   the environment only when `env` is non-nil). A wrapper script that
    ///   dumps its environment on failure would therefore hand us the
    ///   caller's variables — and `docs/linux.md` §Destinations tells users
    ///   to `export AWS_SECRET_ACCESS_KEY=…` in the very shell they then run
    ///   helper commands from. The fix belongs here rather than on the
    ///   probe's environment: rule 3 is about *execution* fidelity, and
    ///   sanitizing the environment would change which binaries run at all.
    /// - **Volume.** `readPipeToCompletion` accumulates stderr without a
    ///   limit, so a chatty candidate could otherwise write megabytes into
    ///   journald every tick.
    ///
    /// One line is enough for every real diagnostic this case produces —
    /// `Exec format error`, `cannot execute binary file`, a missing-loader
    /// message — all of which are short and single-line.
    public static let maxReasonOutputLength = 200

    /// The first line of a failed candidate's stderr, capped at
    /// `maxReasonOutputLength` and marked when anything was dropped, so a
    /// truncated diagnostic is never mistaken for the whole story.
    static func summarize(failureOutput: Data) -> String {
        let all = String(decoding: failureOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !all.isEmpty else { return "" }

        // `all` is already trimmed, so it cannot *start* with a newline: a
        // shorter first line always means there were further lines to drop.
        let firstLine = all.prefix { !$0.isNewline }
        let hasMoreLines = firstLine.count != all.count
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count > maxReasonOutputLength {
            return String(trimmed.prefix(maxReasonOutputLength)) + "… (truncated)"
        }
        return hasMoreLines ? trimmed + "… (truncated)" : trimmed
    }

    /// Probes candidates in order and stops at the first one that satisfies
    /// the minimum version.
    ///
    /// A too-old binary is *remembered but not returned early*: the user
    /// deserves "0.16.4 found at /usr/local/bin/restic — 0.17.0+ required"
    /// rather than a bare "not found", and a newer restic further down `PATH`
    /// should still win. Same for unusable candidates, which are reported so
    /// the "found something, couldn't run it" case is never silent.
    public func discover() async -> ResticDiscoveryResult {
        var rejected: [ResticProbe] = []
        for path in candidatePaths() {
            let probe = await probe(path: path)
            switch probe.outcome {
            case .ok:
                return ResticDiscoveryResult(
                    chosen: probe,
                    rejected: rejected,
                    searchedDescription: searchedDescription
                )
            case .tooOld, .unusable:
                rejected.append(probe)
            }
        }
        return ResticDiscoveryResult(
            chosen: nil,
            rejected: rejected,
            searchedDescription: searchedDescription
        )
    }
}

// MARK: - ResticProbe

/// One candidate binary and what running it proved.
public struct ResticProbe: Equatable, Sendable {
    public let path: String
    public let outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        /// Ran, reported a version, and meets the minimum.
        case ok(version: String)
        /// Ran and reported a version below `ResticDiscovery.minimumVersion`.
        case tooOld(version: String)
        /// Did not run, or did not produce a version we could parse.
        case unusable(reason: String)
    }

    public init(path: String, outcome: Outcome) {
        self.path = path
        self.outcome = outcome
    }

    public var version: String? {
        switch outcome {
        case .ok(let version), .tooOld(let version): return version
        case .unusable: return nil
        }
    }

    public var isUsable: Bool {
        if case .ok = outcome { return true }
        return false
    }
}

// MARK: - ResticDiscoveryResult

public struct ResticDiscoveryResult: Equatable, Sendable {
    /// The first candidate that ran and met the minimum version, if any.
    public let chosen: ResticProbe?
    /// Candidates that were found and executed but rejected, in probe order
    /// — the raw material for "0.16.4 found, 0.17.0+ required".
    public let rejected: [ResticProbe]
    /// The locations configured on the discovery instance that produced this
    /// result. Keeping the description with the result prevents diagnostics
    /// from substituting the platform defaults after a customized search.
    public let searchedDescription: String

    public init(chosen: ResticProbe?, rejected: [ResticProbe], searchedDescription: String) {
        self.chosen = chosen
        self.rejected = rejected
        self.searchedDescription = searchedDescription
    }

    /// The first rejected candidate that at least *ran* but was too old —
    /// candidates are probed in preference order, so this is the binary the
    /// user is most likely to think of as "their" restic.
    public var firstTooOld: ResticProbe? {
        rejected.first {
            if case .tooOld = $0.outcome { return true }
            return false
        }
    }
}
