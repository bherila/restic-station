import Foundation
import ResticStationCore

/// The model half of T18 (`docs/tasks/T18-onboarding-settings.md`): restic
/// discovery, the two Full Disk Access verdicts, and the onboarding gate.
///
/// It lives in an extension because `AppModel` itself is closed for this
/// task, which has a useful consequence: **nothing here adds stored state.**
/// Every value below is either derived from something `AppModel` already
/// publishes (`config`, `stateWatcher`, `launchd`) or computed on the spot,
/// so there is no second copy of the truth to go stale. The transient UI
/// state that genuinely needs storing (a probe in flight, a re-check
/// waiting) lives in the small `ObservableObject`s next to the views that
/// own it.

// MARK: - restic discovery

@MainActor
extension AppModel {

    /// Searches the well-known locations and `PATH`, and — only if the
    /// search found a binary that actually runs and meets the minimum
    /// version — records its absolute path in `config.resticPath`.
    ///
    /// Deliberately **does not persist a rejected candidate**. `resticPath`
    /// is read by the helper running headless from launchd; writing a binary
    /// there that we already know is too old (or unrunnable) would trade a
    /// visible yellow chip in Settings for scheduled backups that fail with
    /// no one watching. The rejection is reported instead.
    @discardableResult
    func discoverResticBinary() async -> ResticDiscoveryResult {
        assert(
            ResticDiscovery.minimumVersion == Self.minimumResticVersion,
            "The discovery minimum and AppModel.minimumResticVersion have drifted apart: "
                + "\(ResticDiscovery.minimumVersion) vs \(Self.minimumResticVersion)."
        )
        let result = await ResticDiscovery().discover()
        if let chosen = result.chosen, chosen.path != config.resticPath {
            persistResticPath(chosen.path)
        }
        await refreshResticInfo()
        return result
    }

    /// "Locate manually…": validates a user-picked binary the same way
    /// discovery validates a found one, and persists it only if it passes.
    @discardableResult
    func useResticBinary(at path: String) async -> ResticProbe {
        let probe = await ResticDiscovery().probe(path: path)
        if probe.isUsable {
            persistResticPath(probe.path)
            await refreshResticInfo()
        }
        return probe
    }

    private func persistResticPath(_ path: String) {
        do {
            try updateConfig { $0.resticPath = path }
        } catch {
            // `saveConfig` already recorded the reason in `lastConfigError`
            // (the only way this throws is an unreadable config on disk,
            // which the panes surface separately).
        }
    }
}

// MARK: - Full Disk Access

@MainActor
extension AppModel {

    /// The **App** badge: the in-process probe, re-run every time it is
    /// asked for (it is two syscalls) so returning from System Settings with
    /// FDA freshly granted flips the badge on the next appearance/activation.
    var appFullDiskAccess: FdaVerdict {
        FullDiskAccessProbe.probeInProcess()
    }

    /// The **Background agent** badge: whatever the launchd-context probe
    /// last wrote to `state/fda-check.json`, subject to the staleness and
    /// provenance rules in `FullDiskAccessProbe.agentVerdict`.
    var agentFullDiskAccess: FdaVerdict {
        FullDiskAccessProbe.agentVerdict(from: stateWatcher.fdaCheck)
    }

    /// Names of the sets with a run in flight (or an invocation we have
    /// started that has not yet appeared in `state/`). The gate for the FDA
    /// re-check, which restarts the agent with `kickstart -k`.
    var setsWithWorkInFlight: [String] {
        let ids = Set(stateWatcher.currentRuns.keys).union(pendingActionSetIds)
        guard !ids.isEmpty else { return [] }
        let named = config.sets.filter { ids.contains($0.id) }.map(\.name)
        // A run whose set has since been deleted from the config still
        // counts as work in flight — it just has no name to show.
        return named.isEmpty ? ["a backup"] : named
    }
}

// MARK: - FdaVerdict

/// What we are entitled to claim about Full Disk Access for one process
/// context.
///
/// `unknown` is a first-class answer, not a placeholder: an FDA probe that
/// did not happen (or happened too long ago, or happened in the wrong
/// process) proves nothing, and the one thing this UI must never do is show
/// a reassuring badge on the strength of evidence that has expired. There is
/// no "probably granted".
enum FdaVerdict: Equatable, Sendable {
    /// The probe read a TCC-protected directory successfully.
    case granted(probedPath: String, checkedAt: Date?)
    /// The probe was performed and was refused.
    case denied(probedPath: String, checkedAt: Date?)
    /// No usable evidence. `reason` is shown to the user verbatim.
    case unknown(reason: String)

    var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .unknown: return "Unknown"
        }
    }

    /// The one-line explanation shown under the badge. When the verdict came
    /// from a recorded probe (rather than one we just ran), it carries its
    /// own timestamp: "granted" is only as true as it is fresh, and the user
    /// should be able to see how fresh without doing arithmetic.
    var detail: String {
        switch self {
        case .granted(let path, let checkedAt):
            return "Read \(path) successfully." + Self.suffix(for: checkedAt)
        case .denied(let path, let checkedAt):
            return "Could not read \(path) — macOS refused access." + Self.suffix(for: checkedAt)
        case .unknown(let reason):
            return reason
        }
    }

    private static func suffix(for checkedAt: Date?) -> String {
        guard let checkedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return " Checked \(formatter.localizedString(for: checkedAt, relativeTo: Date()))."
    }
}

// MARK: - FullDiskAccessProbe

/// The Full Disk Access verification protocol from
/// `docs/keychain-and-fda.md` §2, app side.
///
/// The probe has to be read carefully in both directions:
///
/// - **A failure only means "denied" if the path exists.** TCC does not hide
///   `~/Library/Safari`; it refuses to enumerate it. `contentsOfDirectory`
///   failing on a directory that is not there is an ordinary
///   `ENOENT`, and reporting that as "denied" would send a user who has
///   never opened Safari or Mail into System Settings to fix a permission
///   that is not the problem.
/// - **Both candidate paths can be absent.** Safari's directory exists for
///   any account that has ever launched Safari, and `~/Library/Mail` for any
///   account that has ever launched Mail — but a fresh account (or a CI
///   machine) can have neither, and then the honest answer is `unknown`.
enum FullDiskAccessProbe {
    /// Display forms of the two probe locations, matching what the helper
    /// records in `state/fda-check.json` (`Helper/Sources/Commands/FdaCheck.swift`).
    static let safariDisplayPath = "~/Library/Safari"
    static let mailDisplayPath = "~/Library/Mail"

    /// Evidence older than this is not evidence: FDA can be revoked in
    /// System Settings at any moment, without notification.
    /// `docs/tasks/T18-onboarding-settings.md`: "unknown when file
    /// absent/stale > 1 h".
    static let stalenessLimit: TimeInterval = 3600

    /// The in-process ("App" badge) probe. Same logic and same two paths as
    /// the helper's `fda-check`, so the two badges are comparable.
    ///
    /// The verdict carries no timestamp because it does not need one: it is
    /// produced on the spot, every time the pane appears or the app is
    /// activated. Staleness is only a question for the recorded
    /// launchd-context result.
    static func probeInProcess() -> FdaVerdict {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let safari = home.appendingPathComponent("Library/Safari", isDirectory: true)
        let mail = home.appendingPathComponent("Library/Mail", isDirectory: true)

        let probedURL: URL
        let displayPath: String
        if FileManager.default.fileExists(atPath: safari.path) {
            probedURL = safari
            displayPath = safariDisplayPath
        } else if FileManager.default.fileExists(atPath: mail.path) {
            probedURL = mail
            displayPath = mailDisplayPath
        } else {
            return .unknown(reason: "Neither \(safariDisplayPath) nor \(mailDisplayPath) exists on this Mac, "
                + "so Restic Station cannot test Full Disk Access. Open Safari or Mail once, then check again.")
        }

        let readable = (try? FileManager.default.contentsOfDirectory(atPath: probedURL.path)) != nil
        return readable
            ? .granted(probedPath: displayPath, checkedAt: nil)
            : .denied(probedPath: displayPath, checkedAt: nil)
    }

    /// Interprets `state/fda-check.json` for the **Background agent** badge.
    ///
    /// Three ways a record turns into `unknown` rather than a verdict — each
    /// one a way the badge could otherwise be quietly wrong:
    ///
    /// 1. **Absent.** The probe has never run.
    /// 2. **Stale.** Older than an hour: FDA is revocable at any time and
    ///    nothing tells us when it happens, so an old *granted* is exactly
    ///    the reassuring lie this pane exists to prevent. (An old *denied*
    ///    goes the same way — symmetry keeps the rule simple, and it is the
    ///    "Re-check" button's whole purpose to produce a fresh answer.)
    /// 3. **Wrong context.** Only `context: "launchd"` is evidence about the
    ///    background agent. A record written by the app-spawned helper
    ///    (`context: "app-spawned"`) reflects the *app's* TCC responsibility
    ///    — the very thing that can differ (`docs/keychain-and-fda.md` §2) —
    ///    so treating it as the agent's verdict would defeat the check.
    static func agentVerdict(
        from record: FdaCheckResult?,
        now: Date = Date(),
        stalenessLimit: TimeInterval = FullDiskAccessProbe.stalenessLimit
    ) -> FdaVerdict {
        guard let record else {
            return .unknown(reason: "The background agent has not reported yet. Choose Re-check to run the "
                + "check now.")
        }
        guard record.context == "launchd" else {
            return .unknown(reason: "The last check ran in the “\(record.context)” context, which says nothing "
                + "about the background agent. Choose Re-check to run it from launchd.")
        }
        let age = now.timeIntervalSince(record.checkedAt)
        guard age >= 0, age <= stalenessLimit else {
            return .unknown(reason: "The last check ran \(describeAge(age)) and is no longer current — Full Disk "
                + "Access can be withdrawn at any time. Choose Re-check.")
        }
        return record.hasFullDiskAccess
            ? .granted(probedPath: record.probedPath, checkedAt: record.checkedAt)
            : agentDenialVerdict(record)
    }

    /// A recorded denial is only reported as "denied" if the probed
    /// directory exists here and now — otherwise the helper's `false` is an
    /// `ENOENT`, not a TCC refusal (the helper writes `hasFullDiskAccess:
    /// false` for both). Reporting `unknown` keeps the user out of a
    /// System Settings rabbit hole for a permission that was never tested.
    private static func agentDenialVerdict(_ record: FdaCheckResult) -> FdaVerdict {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded: String
        switch record.probedPath {
        case safariDisplayPath:
            expanded = home.appendingPathComponent("Library/Safari", isDirectory: true).path
        case mailDisplayPath:
            expanded = home.appendingPathComponent("Library/Mail", isDirectory: true).path
        default:
            expanded = (record.probedPath as NSString).expandingTildeInPath
        }
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .unknown(reason: "The background agent could not test Full Disk Access: \(record.probedPath) "
                + "does not exist on this Mac. Open Safari or Mail once, then choose Re-check.")
        }
        return .denied(probedPath: record.probedPath, checkedAt: record.checkedAt)
    }

    private static func describeAge(_ age: TimeInterval) -> String {
        if age < 0 {
            return "in the future (this Mac's clock has moved)"
        }
        let hours = Int(age / 3600)
        if hours >= 48 {
            return "\(hours / 24) days ago"
        }
        if hours >= 1 {
            return hours == 1 ? "over an hour ago" : "\(hours) hours ago"
        }
        return "recently"
    }
}

// MARK: - Onboarding

@MainActor
extension AppModel {

    /// First-launch gate (`docs/ui-spec.md` §Onboarding): no backup sets and
    /// the assistant has never been completed.
    ///
    /// Suppressed while `config.json` is unreadable: in that state we do not
    /// know whether the user has sets, and an assistant that ends by writing
    /// a config would be building on top of a file we refused to parse.
    var shouldPresentOnboarding: Bool {
        configLoadError == nil
            && config.sets.isEmpty
            && config.onboardingCompleted != true
    }

    /// Records that the assistant has run, so it never reappears — including
    /// when the user finished it without creating a set (skippable steps are
    /// still a completed pass).
    func markOnboardingCompleted() {
        guard config.onboardingCompleted != true else { return }
        do {
            try updateConfig { $0.onboardingCompleted = true }
        } catch {
            // Unreadable config: the flag cannot be persisted, so the
            // assistant may reappear next launch. Better than silently
            // dropping the user's actual configuration.
        }
    }
}
