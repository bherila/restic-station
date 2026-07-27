import AppKit
import ResticStationCore
import ServiceManagement
import SwiftUI

/// Settings → Permissions & background (`docs/ui-spec.md` §Settings,
/// `docs/keychain-and-fda.md` §2/§3).
///
/// Two cards, both of them alarms rather than settings: without Full Disk
/// Access the scheduled helper reads nothing but the files the user could
/// have copied by hand, and without the background agent nothing runs when
/// the app is closed. Neither failure produces an error dialog anywhere else
/// in the app — they produce backups that quietly contain less than the user
/// thinks, or no backups at all. Every state here therefore says what is
/// wrong, and offers exactly one next step.
struct PermissionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchd: LaunchdManager
    @StateObject private var pane = PermissionsPaneModel()

    var body: some View {
        Form {
            fullDiskAccessSection
            backgroundAgentSection
        }
        .formStyle(.grouped)
        .onAppear { pane.refreshAppVerdict() }
        .onDisappear { pane.cancelRecheck() }
        // Returning from System Settings is the moment a grant/revoke
        // becomes true, and nothing notifies us — re-probe on activation.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pane.refreshAppVerdict()
            model.refresh()
        }
    }

    // MARK: - Full Disk Access

    @ViewBuilder
    private var fullDiskAccessSection: some View {
        Section {
            StatusRow(
                title: "App",
                tone: tone(for: pane.appVerdict),
                badgeLabel: pane.appVerdict.label,
                detail: pane.appVerdict.detail
            )

            StatusRow(
                title: "Background agent",
                tone: tone(for: model.agentFullDiskAccess),
                badgeLabel: model.agentFullDiskAccess.label,
                detail: model.agentFullDiskAccess.detail,
                isBusy: pane.recheck == .waiting
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Re-check") {
                        pane.recheckAgent(model: model)
                    }
                    .disabled(pane.recheck == .waiting)

                    Button("Open Full Disk Access settings") {
                        pane.openFullDiskAccessSettings()
                    }
                }

                if let message = pane.recheck.message {
                    Label {
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: pane.recheck.tone.symbolName)
                            .foregroundStyle(pane.recheck.tone.color)
                    }
                    .font(.callout)
                }
            }

            DisclosureGroup("If the background agent still reports Denied") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Granting Full Disk Access to Restic Station normally covers the background "
                        + "agent too, because the agent runs as part of the app. On some Macs macOS "
                        + "attributes the agent separately — then add the helper itself:")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("1. Open the Full Disk Access settings (button above).\n"
                        + "2. Click “+”, then press ⌘⇧G to type a path.\n"
                        + "3. Paste the path below, add it, and make sure its switch is on.\n"
                        + "4. Come back here and choose Re-check.")
                        .fixedSize(horizontal: false, vertical: true)
                    CopyablePath(text: HelperInvoker.helperURL.path, helpText: "Copy the helper path")
                    Text("Full Disk Access changes take effect for the agent the next time it starts, "
                        + "which is what Re-check triggers.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .padding(.top, 4)
            }
        } header: {
            Text("Full Disk Access")
        } footer: {
            Text("macOS hides files like Mail and Safari data from apps without Full Disk Access, and "
                + "never asks — a backup would simply skip them. Restic Station checks the app and "
                + "the background agent separately, because macOS can grant one and not the other.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Background agent

    @ViewBuilder
    private var backgroundAgentSection: some View {
        Section {
            StatusRow(
                title: "Background agent",
                tone: agentTone,
                badgeLabel: agentLabel,
                detail: launchd.diagnostic ?? "Registered and running on schedule."
            )

            switch launchd.status {
            case .enabled:
                EmptyView()
            case .requiresApproval:
                Button("Open Login Items settings") {
                    launchd.openLoginItemsSettings()
                }
            case .notRegistered:
                HStack {
                    Button("Enable") {
                        pane.enableAgent(launchd: launchd)
                    }
                    if let error = pane.agentError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .notFound:
                VStack(alignment: .leading, spacing: 8) {
                    CopyablePath(text: Bundle.main.bundlePath, helpText: "Copy this app's path")
                    Button("Try to register anyway") {
                        pane.enableAgent(launchd: launchd)
                    }
                    if let error = pane.agentError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            @unknown default:
                Button("Enable") {
                    pane.enableAgent(launchd: launchd)
                }
            }
        } header: {
            Text("Background agent")
        } footer: {
            Text("Runs backups on schedule even when Restic Station is closed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var agentTone: StatusTone {
        switch launchd.status {
        case .enabled: return .ok
        case .requiresApproval: return .warning
        case .notRegistered, .notFound: return .problem
        @unknown default: return .unknown
        }
    }

    private var agentLabel: String {
        switch launchd.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Requires approval"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
    }

    private func tone(for verdict: FdaVerdict) -> StatusTone {
        switch verdict {
        case .granted: return .ok
        case .denied: return .problem
        case .unknown: return .unknown
        }
    }
}

// MARK: - PermissionsPaneModel

/// Transient state for the Permissions pane: the in-process FDA verdict, the
/// re-check state machine, and the last agent-registration error.
@MainActor
final class PermissionsPaneModel: ObservableObject {
    @Published private(set) var appVerdict: FdaVerdict = .unknown(reason: "Not checked yet.")
    @Published private(set) var recheck: RecheckPhase = .idle
    @Published private(set) var agentError: String?

    /// How long to wait for the agent to write a fresh
    /// `state/fda-check.json` after the kickstart (T18: "timeout 30 s →
    /// keep unknown + hint").
    /// `nonisolated` so the (non-isolated) `RecheckPhase.message` strings
    /// can quote the same number the state machine actually uses.
    nonisolated static let recheckTimeout: TimeInterval = 30
    nonisolated private static let pollInterval: UInt64 = 400_000_000 // 400 ms

    private var recheckTask: Task<Void, Never>?

    // MARK: App probe

    func refreshAppVerdict() {
        appVerdict = FullDiskAccessProbe.probeInProcess()
    }

    // MARK: Re-check

    /// Triggers a **launchd-context** Full Disk Access probe by restarting
    /// the agent, then waits for the state file to change.
    ///
    /// The gate is the safety-critical part. `kickstartTick(restart: true)`
    /// passes `launchctl kickstart -k`, which **kills the running instance
    /// of the agent first** — and the agent is the process that runs
    /// backups. Firing it during a backup would abort that backup partway
    /// through (leaving an interrupted run for the next tick to recover),
    /// purely to satisfy a permissions check the user could have run a
    /// minute later. So: no run in flight, or no kickstart.
    ///
    /// The check is made against freshly re-read state, not the debounced
    /// copy in memory, and it counts app-initiated invocations that have not
    /// yet produced a `current-run-*.json` (`AppModel.pendingActionSetIds`)
    /// as busy. A residual race remains — a scheduled tick can start a
    /// backup in the milliseconds between the check and the kickstart — and
    /// is accepted: it is bounded by the tick interval, the interrupted run
    /// is recovered on the next tick, and the alternative (never offering a
    /// re-check) leaves the user with no way to verify the agent at all.
    func recheckAgent(model: AppModel) {
        guard recheckTask == nil else { return }

        // Re-read state synchronously: `StateWatcher` publishes on a 250 ms
        // debounce, and "is a backup running?" must not be answered from a
        // stale snapshot.
        model.refresh()

        let busy = model.setsWithWorkInFlight
        guard busy.isEmpty else {
            recheck = .blocked(setNames: busy)
            return
        }
        guard model.launchd.status == .enabled else {
            recheck = .agentUnavailable
            return
        }

        let before = model.stateWatcher.fdaCheck
        model.launchd.kickstartTick(restart: true)
        if let kickstartError = model.launchd.lastKickstartError {
            recheck = .failed(kickstartError)
            return
        }

        recheck = .waiting
        recheckTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.recheckTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                if Task.isCancelled { return }
                model.stateWatcher.reloadNow()
                if Self.isFresherLaunchdRecord(model.stateWatcher.fdaCheck, than: before) {
                    self?.recheck = .completed
                    self?.recheckTask = nil
                    return
                }
            }
            self?.recheck = .timedOut
            self?.recheckTask = nil
        }
    }

    func cancelRecheck() {
        recheckTask?.cancel()
        recheckTask = nil
        if recheck == .waiting {
            recheck = .idle
        }
    }

    /// Only a **new** record written from the **launchd** context ends the
    /// wait. Anything else (an unchanged file, or one written by a
    /// helper the app spawned itself) is not the evidence we asked for, and
    /// accepting it would let the badge claim the agent has access on the
    /// strength of the app's own permissions.
    private static func isFresherLaunchdRecord(_ current: FdaCheckResult?, than previous: FdaCheckResult?) -> Bool {
        guard let current, current.context == "launchd" else { return false }
        guard let previous else { return true }
        return current != previous && current.checkedAt > previous.checkedAt
    }

    // MARK: Agent registration

    func enableAgent(launchd: LaunchdManager) {
        do {
            try launchd.register()
            agentError = nil
        } catch {
            agentError = error.localizedDescription
        }
    }

    // MARK: Deep link

    /// `docs/keychain-and-fda.md` §2. There is no API to request Full Disk
    /// Access — opening the pane is the only thing an app can do.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - RecheckPhase

    enum RecheckPhase: Equatable {
        case idle
        /// Refused because a backup is running — `-k` would kill it.
        case blocked(setNames: [String])
        /// The agent is not enabled, so there is nothing to kickstart.
        case agentUnavailable
        case waiting
        case completed
        case timedOut
        case failed(String)

        var message: String? {
            switch self {
            case .idle:
                return nil
            case .blocked(let setNames):
                let list = setNames.joined(separator: ", ")
                return "Waiting for the current backup to finish — re-checking restarts the background "
                    + "agent, which would interrupt \(list). Try again when it is done."
            case .agentUnavailable:
                return "The background agent is not enabled, so it cannot be asked to check. Enable it "
                    + "below first."
            case .waiting:
                return "Restarting the background agent and waiting for its report (up to "
                    + "\(Int(PermissionsPaneModel.recheckTimeout)) seconds)…"
            case .completed:
                return "The background agent reported just now."
            case .timedOut:
                return "The background agent did not report within "
                    + "\(Int(PermissionsPaneModel.recheckTimeout)) seconds, so its Full Disk Access "
                    + "status stays unknown. Check that the agent is enabled, then try again — or add "
                    + "the helper to Full Disk Access by hand using the steps below."
            case .failed(let reason):
                return reason
            }
        }

        var tone: StatusTone {
            switch self {
            case .idle, .waiting: return .inProgress
            case .completed: return .ok
            case .blocked, .agentUnavailable, .timedOut: return .warning
            case .failed: return .problem
            }
        }
    }
}
