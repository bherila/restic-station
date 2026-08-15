import Combine
import Foundation
import ResticStationCore
import ServiceManagement

#if canImport(Darwin)
import Darwin
#endif

/// The app's half of the launchd integration (`docs/keychain-and-fda.md`
/// §3, `docs/scheduling.md` §plist): registers/unregisters the single
/// static LaunchAgent embedded at
/// `Contents/Library/LaunchAgents/net.herila.ResticStation.helper.plist`,
/// publishes its `SMAppService.Status` for the UI, and kicks early ticks
/// with `launchctl kickstart`.
///
/// Deliberately thin: no scheduling logic lives here (the helper's `tick`
/// owns all of it — "the app never computes schedules"), and every argv
/// this class builds comes from `LaunchctlCommand` in Core, where it is
/// unit-tested.
@MainActor
public final class LaunchdManager: ObservableObject {
    /// Filename of the embedded plist; `SMAppService.agent(plistName:)`
    /// resolves it inside `Contents/Library/LaunchAgents/`. A mismatch here
    /// is exactly what produces `.notFound`.
    /// `nonisolated` so it is usable from the (nonisolated) default
    /// argument of `init` and from any context that just needs the name.
    public nonisolated static let plistName = LaunchctlCommand.helperPlistName
    /// The launchd label — must equal `plistName` minus `.plist`.
    public nonisolated static let label = LaunchctlCommand.helperLabel

    /// Last known registration status. Not observable by macOS push, so it
    /// is refreshed explicitly: on `init`, after `register`/`unregister`,
    /// and whenever the UI becomes active (e.g. the menu opens, or the app
    /// returns from System Settings after an approval).
    @Published public private(set) var status: SMAppService.Status
    /// Human-readable explanation of the current `status` — including the
    /// "copy to /Applications" hint when the app is running out of
    /// DerivedData, which is the overwhelmingly likely cause of `.notFound`
    /// during development. `nil` when everything is fine (`.enabled`).
    @Published public private(set) var diagnostic: String?
    /// Last `launchctl kickstart` failure, if any. A failed kickstart is
    /// never fatal — it only means the immediate tick did not happen, and
    /// launchd's own `StartInterval` fires within 2 minutes anyway — so it
    /// is surfaced as information rather than thrown.
    @Published public private(set) var lastKickstartError: String?

    /// Whether this copy of the app actually contains the LaunchAgent plist.
    /// macOS can report `.notFound` before a first registration even when the
    /// resource is present, so the UI must not turn that status alone into a
    /// false "broken installation" diagnosis.
    public let embeddedAgentExists: Bool

    private let service: SMAppService
    private let bundlePath: String

    public init(
        service: SMAppService = SMAppService.agent(plistName: LaunchdManager.plistName),
        bundlePath: String = Bundle.main.bundlePath
    ) {
        self.service = service
        self.bundlePath = bundlePath
        self.embeddedAgentExists = Self.embeddedAgentExists(in: bundlePath)
        self.status = service.status
        self.diagnostic = Self.diagnostic(for: service.status, bundlePath: bundlePath)
    }

    // MARK: - Status

    /// Re-reads `SMAppService.status` and recomputes `diagnostic`. Cheap;
    /// call it liberally (there is no notification for status changes —
    /// the user can toggle the login item in System Settings at any time,
    /// behind our back).
    public func refreshStatus() {
        status = service.status
        diagnostic = Self.diagnostic(for: status, bundlePath: bundlePath)
    }

    /// `true` when the agent is registered and enabled — i.e. scheduled
    /// backups will actually run with the app closed.
    public var isEnabled: Bool {
        status == .enabled
    }

    /// `true` when the user must flip the switch themselves in System
    /// Settings → General → Login Items & Extensions; the UI's call to
    /// action is `openLoginItemsSettings()`.
    public var needsApproval: Bool {
        status == .requiresApproval
    }

    // MARK: - Registration

    /// Registers the LaunchAgent. Registration binds launchd to the app's
    /// **current path**, so it is only meaningful from a stable location —
    /// see `diagnostic` for the DerivedData caveat.
    ///
    /// Throws `LaunchdError.registrationFailed`, whose message already
    /// includes the status-specific hint, so callers can show
    /// `error.localizedDescription` verbatim. `status`/`diagnostic` are
    /// refreshed either way (a throwing `register()` still commonly leaves
    /// a meaningful status, e.g. `.requiresApproval`).
    public func register() throws {
        defer { refreshStatus() }
        do {
            try service.register()
        } catch {
            let statusAfter = service.status
            let hint = Self.diagnostic(for: statusAfter, bundlePath: bundlePath)
            throw LaunchdError.registrationFailed(message: error.localizedDescription, hint: hint)
        }
    }

    /// Unregisters the LaunchAgent (the async variant: macOS performs the
    /// removal out of process, and the completion tells us it really
    /// happened).
    ///
    /// Note that `unregister` on an already-unregistered service throws on
    /// some macOS versions; callers that just want "make sure it's gone"
    /// should ignore the error and check `status` afterwards.
    public func unregister() async throws {
        defer { refreshStatus() }
        do {
            try await service.unregister()
        } catch {
            let hint = Self.diagnostic(for: service.status, bundlePath: bundlePath)
            throw LaunchdError.unregistrationFailed(message: error.localizedDescription, hint: hint)
        }
    }

    /// Opens System Settings → General → Login Items & Extensions. The only
    /// possible remedy for `.requiresApproval`: there is no programmatic
    /// approval API.
    ///
    /// The symbol is `openSystemSettingsLoginItems()` — the SDK header
    /// declares `+ (void)openSystemSettingsLoginItems` with no
    /// `NS_SWIFT_NAME` override (checked against
    /// `MacOSX.sdk/…/ServiceManagement.framework/Headers/SMAppService.h`).
    /// `docs/keychain-and-fda.md` §3 wrote it as
    /// `openSystemSettingsLoginItemsSettings()`, which does not exist.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - kickstart

    /// Asks launchd to run the agent's `tick` immediately, instead of
    /// waiting up to `StartInterval` (120 s). Called after any config save
    /// that changes schedules.
    ///
    /// Going through `launchctl` rather than spawning the helper directly
    /// is deliberate: the tick then runs in the **launchd context**, which
    /// is what the helper's TCC attribution and `state/fda-check.json`
    /// `context: "launchd"` result describe.
    ///
    /// - Parameter restart: passes `-k`, which kills a running instance
    ///   first. This is **only** for the FDA re-check flow
    ///   (`docs/keychain-and-fda.md` §2, "triggers a real launchd-context
    ///   probe via `launchctl kickstart -k`"). The default `false` must
    ///   never be changed: a plain `kickstart` against a busy service is a
    ///   no-op, so a scheduled backup in flight is left alone, whereas `-k`
    ///   would kill it mid-run.
    public func kickstartTick(restart: Bool = false) {
        let argv = LaunchctlCommand.kickstartArgv(uid: getuid(), restart: restart)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: LaunchctlCommand.executablePath)
        process.arguments = argv
        // launchctl's output is diagnostic only; discard it rather than
        // hold pipes open across a fire-and-forget spawn.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            // `Process.run()` is a `posix_spawn`, not a wait — nothing here
            // blocks the main actor, and we deliberately do NOT
            // `waitUntilExit()`: `kickstart` returns as soon as launchd has
            // accepted the request, but we don't need even that.
            try process.run()
            lastKickstartError = nil
        } catch {
            lastKickstartError = "launchctl kickstart failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Diagnostics

    /// One user-facing sentence per `SMAppService.Status`. All four
    /// documented cases are handled explicitly (plus `@unknown default`,
    /// since `SMAppService.Status` is a non-frozen ObjC enum).
    nonisolated static func diagnostic(for status: SMAppService.Status, bundlePath: String) -> String? {
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "Restic Station is registered but switched off. Turn it on in "
                + "System Settings → General → Login Items & Extensions, or scheduled "
                + "backups will not run."
        case .notRegistered:
            return "Background backups are not set up yet. Registering the background "
                + "agent lets Restic Station back up on schedule even while it is closed."
        case .notFound:
            if embeddedAgentExists(in: bundlePath) {
                return "Background backups are not set up yet. Registering the background "
                    + "agent lets Restic Station back up on schedule even while it is closed."
            }
            var message = "macOS could not find the background agent "
                + "(\(plistName)) inside this copy of Restic Station."
            if isDerivedDataPath(bundlePath) {
                message += " This build is running from Xcode's DerivedData: "
                    + "registrations made from a build directory break on every rebuild "
                    + "and confuse Full Disk Access attribution. Copy Restic Station.app "
                    + "to /Applications and launch it from there."
            } else {
                message += " Try reinstalling the app; if it was moved after being "
                    + "registered, re-register it from its new location."
            }
            return message
        @unknown default:
            return "Restic Station could not determine whether the background agent is "
                + "registered (unrecognized status \(status.rawValue))."
        }
    }

    /// A dev-build bundle path check. Substring, not prefix: DerivedData
    /// lives under `~/Library/Developer/Xcode/DerivedData/…` by default but
    /// is freely relocatable via build settings, and `swift build` output
    /// paths differ again — the marker component is what's reliable.
    nonisolated static func isDerivedDataPath(_ path: String) -> Bool {
        path.contains("DerivedData")
    }

    nonisolated static func embeddedAgentExists(in bundlePath: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: bundlePath, isDirectory: true)
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName, isDirectory: false)
            .path)
    }
}

// MARK: - LaunchdError

/// Registration failures, with the status-specific hint already folded into
/// `localizedDescription` so any alert/`Text` can show it as-is.
public enum LaunchdError: LocalizedError {
    case registrationFailed(message: String, hint: String?)
    case unregistrationFailed(message: String, hint: String?)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let message, let hint):
            return Self.combine("Could not register the background agent: \(message)", hint)
        case .unregistrationFailed(let message, let hint):
            return Self.combine("Could not remove the background agent: \(message)", hint)
        }
    }

    private static func combine(_ message: String, _ hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return message }
        return message + "\n\n" + hint
    }
}
