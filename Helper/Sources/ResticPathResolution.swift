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
    ) async -> String? {
        if let configured = resolved.config.resticPath, !configured.isEmpty {
            return configured
        }

        let result = await discovery.discover()
        guard let chosen = result.chosen else {
            return nil
        }
        log("restic not configured; discovered \(chosen.path) (version \(chosen.version ?? "unknown"))")
        return chosen.path
    }

    /// What to print when nothing resolved.
    ///
    /// On macOS this stays the T10 wording verbatim — there *is* an app to
    /// open, and onboarding walks the user through picking a binary.
    /// On Linux that advice is impossible to follow on a headless host, so
    /// the message names what was searched and how to fix it.
    static func resticNotFoundMessage(
        paths: AppPaths,
        discovery: ResticDiscovery = ResticDiscovery()
    ) -> String {
        #if os(macOS)
        return "restic not configured — open Restic Station"
        #else
        // `machine.json`, not `config.json`: a binary path is per-machine,
        // and `config.json` is the file the user shares between hosts.
        return """
            restic not found. Searched \(discovery.searchedDescription).
            Install restic (for example `apt install restic` or \
            `dnf install restic`), or set "resticPath" in \(paths.machineFile.path).
            """
        #endif
    }
}

// MARK: - HelperLog

/// The helper's one-line logging surface. stderr rather than stdout: stdout
/// is each subcommand's result channel (scripts parse it), and launchd /
/// systemd capture both streams anyway.
enum HelperLog {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("info: \(message)\n".utf8))
    }
}
