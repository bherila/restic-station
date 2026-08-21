import Foundation
import ResticStationCore

/// How the helper decides *which* restic binary to run (T25).
///
/// Kept out of `HelperContext.swift` so the wiring there stays a single
/// `await resolveResticPath(resolved:)` line.
extension HelperContext {

    /// Resolves the restic binary this invocation should use.
    ///
    /// Order:
    ///
    /// 1. **`machine.json` `resticPath`** — the per-machine value, which is
    ///    where a binary path belongs (T24).
    /// 2. **`AppConfig.resticPath`** — deprecated. `config.json` is shared
    ///    across machines (it is the file a user syncs), so a path that is
    ///    correct on one host is wrong on the next. Still honoured because
    ///    every existing macOS install has it set.
    /// 3. **Discovery** — probe the platform's well-known locations and
    ///    `PATH`, running each candidate (`ResticDiscovery`). This is what
    ///    makes a headless Linux host work with no configuration at all.
    ///
    /// Steps 1 and 2 arrive here already collapsed, in that order, into
    /// `resolved.config.resticPath`: `AppConfig.resolved(for: MachineConfig)`
    /// prefers `machine.json`'s value and falls back to the deprecated one.
    /// That is why this takes a `ResolvedConfig` rather than an `AppConfig`
    /// — passing a config that has *not* been resolved for this machine
    /// would silently skip step 1, and the type makes that impossible.
    ///
    /// A discovered path is deliberately **not** written back into
    /// `config.json`: that file is shared across machines, and persisting
    /// one host's `/usr/bin/restic` there would break the next one. It is
    /// logged once instead, so `journalctl`/`log show` can answer "which
    /// restic did it actually run?".
    static func resolveResticPath(
        resolved: ResolvedConfig,
        discovery: ResticDiscovery = ResticDiscovery(),
        log: @Sendable (String) -> Void = { HelperLog.info($0) }
    ) async -> ResticResolution {
        if let configured = resolved.config.resticPath, !configured.isEmpty {
            return .resolved(configured)
        }

        let result = await discovery.discover()
        guard let chosen = result.chosen else {
            // The *result*, not a bare `nil`. Discovery ran every candidate
            // and recorded exactly why each was rejected; throwing that away
            // and reporting "not found" is what made this failure so
            // confusing to act on (issue #50). Carrying it also means the
            // message describes the search that actually happened rather
            // than a second one run against a different environment.
            return .notFound(result)
        }
        log("restic not configured; discovered \(chosen.path) (version \(chosen.version ?? "unknown"))")
        return .resolved(chosen.path)
    }

    /// What to print when nothing resolved.
    ///
    /// Three genuinely different situations, which used to share one
    /// sentence — "restic not found" — and one piece of advice that made two
    /// of them worse (issue #50):
    ///
    /// - **Found, but too old.** The user has restic. Telling them to
    ///   install restic is a loop: `apt install restic` on Ubuntu 24.04
    ///   gives 0.16.4, below the 0.17.0 floor `ResticDiscovery` enforces, so
    ///   following the advice verbatim reproduces the same message with a
    ///   perfectly good binary sitting on `PATH`. This is how CI's own
    ///   `linux-integration` job broke during T29. Name the binary, the
    ///   version found and the minimum: that is a completely different
    ///   action from "install restic".
    /// - **Found, but did not run.** A Homebrew shim for an uninstalled
    ///   formula, a wrapper script, a broken symlink — all pass
    ///   `isExecutableFile` and fail to execute. `ResticDiscovery` records
    ///   the reason precisely so this case "is never silent"; it was silent
    ///   here.
    /// - **Genuinely absent.** Only here is "install restic" the right
    ///   advice — and it points at the official release binaries, not at a
    ///   package manager that on most distributions ships below the floor.
    ///
    /// On macOS the "genuinely absent" case keeps the T10 wording verbatim:
    /// there really is an app to open, and its Settings pane already renders
    /// the too-old and unusable cases (`ResticDiscoveryResult.status`). The
    /// added detail still goes into the log lines, where a launchd-run
    /// helper's output is the only thing anyone can read.
    static func resticNotFoundMessage(paths: AppPaths, result: ResticDiscoveryResult) -> String {
        if let tooOld = result.firstTooOld, let version = tooOld.version {
            return """
                restic \(version) at \(tooOld.path) is too old — Restic Station needs \
                \(ResticDiscovery.minimumVersion) or newer (docs/restic-cli.md §version: it is the \
                first release with the exit-code contract this tool relies on).
                \(Self.officialBinaryAdvice)
                \(Self.resticPathAdvice(paths: paths))
                """
        }

        if let unusable = result.rejected.first, case .unusable(let reason) = unusable.outcome {
            return """
                restic could not be used. \(reason)
                \(Self.officialBinaryAdvice)
                \(Self.resticPathAdvice(paths: paths))
                """
        }

        #if os(macOS)
        return "restic not configured — open Restic Station"
        #else
        return """
            restic not found. Searched \(result.searchedDescription).
            \(Self.officialBinaryAdvice)
            \(Self.resticPathAdvice(paths: paths))
            """
        #endif
    }

    /// Deliberately not `apt install restic` / `dnf install restic`. Ubuntu
    /// 24.04 LTS ships 0.16.4 and Debian stable is comparable, so that
    /// advice hands the reader a binary this tool rejects — see
    /// `resticNotFoundMessage`.
    ///
    /// The minimum is named here rather than referred back to: two of the
    /// three cases above never state a version, so "older than the minimum
    /// above" pointed at nothing.
    private static var officialBinaryAdvice: String {
        """
        Install an official release binary from https://github.com/restic/restic/releases \
        — distribution packages are frequently older than the \
        \(ResticDiscovery.minimumVersion) minimum.
        """
    }

    /// `machine.json`, not `config.json`: a binary path is per-machine, and
    /// `config.json` is the file the user shares between hosts (T24).
    private static func resticPathAdvice(paths: AppPaths) -> String {
        "Or set \"resticPath\" in \(paths.machineFile.path) to point at one you already have."
    }
}

// MARK: - ResticResolution

/// What `resolveResticPath` concluded — and, when it concluded nothing,
/// enough evidence to explain why without searching a second time.
///
/// `.notFound` always carries a real result: the only early return is a
/// configured `resticPath`, which is returned verbatim (an explicit path
/// deliberately bypasses the version gate), so discovery has necessarily run
/// by the time this case is constructed.
enum ResticResolution: Sendable {
    case resolved(String)
    case notFound(ResticDiscoveryResult)

    var path: String? {
        switch self {
        case .resolved(let path): return path
        case .notFound: return nil
        }
    }
}

// MARK: - HelperLog

/// The helper's one-line logging surface. stderr rather than stdout: stdout
/// is each subcommand's result channel (scripts parse it), and launchd /
/// systemd capture both streams anyway.
enum HelperLog {
    static func info(_ message: String) {
        StandardStream.write(Data("info: \(message)\n".utf8), to: .standardError)
    }
}
