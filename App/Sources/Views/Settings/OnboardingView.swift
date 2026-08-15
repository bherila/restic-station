import AppKit
import ResticStationCore
import ServiceManagement
import SwiftUI

/// The first-launch setup assistant (`docs/ui-spec.md` §Onboarding): four
/// steps, "skippable except where noted", re-runnable from Settings →
/// "Setup assistant…".
///
/// Only step 1 blocks. Without restic there is nothing to configure — every
/// later step would be theatre. The agent and Full Disk Access steps are
/// skippable because a user may reasonably want to look around first, but
/// each one says plainly what stops working if it is skipped, and the same
/// state is permanently visible in Settings → Permissions afterwards. What
/// the assistant must never do is imply that skipping is free.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var launchd: LaunchdManager

    @Binding var isPresented: Bool

    @State private var step: Step = .welcome
    @StateObject private var restic = ResticSettingsModel()
    @StateObject private var permissions = PermissionsPaneModel()

    enum Step: Int, CaseIterable, Comparable {
        case welcome = 0
        case agent
        case fullDiskAccess
        case firstSet

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .agent: return "Background agent"
            case .fullDiskAccess: return "Full Disk Access"
            case .firstSet: return "First backup set"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .task {
            await restic.refreshIfNeeded(model: model)
        }
        .onAppear {
            permissions.refreshAppVerdict()
            launchd.refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshAppVerdict()
            model.refresh()
        }
        .onDisappear { permissions.cancelRecheck() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.headline)
                Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { candidate in
                    Circle()
                        .fill(candidate <= step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            // An exit that is always available. Step 1 blocks *Continue*
            // when restic is missing, which must not mean the assistant
            // traps the user in a sheet they cannot satisfy: closing early
            // leaves `onboardingCompleted` unset, so setup is offered again
            // next launch — it is unfinished, and pretending otherwise would
            // hide the fact that nothing can back up yet.
            if step != .firstSet {
                Button("Close") { isPresented = false }
            }
            if step != .welcome {
                Button("Back") { goBack() }
            }
            Spacer()
            if step == .firstSet {
                Button("Finish later") { finish() }
                Button("Create your first backup set") { createFirstSet() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if canSkipCurrentStep {
                    Button("Skip") { goForward() }
                }
                Button("Continue") { goForward() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .agent: agentStep
        case .fullDiskAccess: fullDiskAccessStep
        case .firstSet: firstSetStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restic Station runs scheduled backups with restic, and keeps working when the app "
                + "is closed. Three things need to be in place first.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("restic binary")
                        Spacer(minLength: 12)
                        StatusBadge(tone: resticChip.tone, label: resticChip.label, isBusy: restic.isSearching)
                    }
                    Text(resticChip.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !resticIsUsable {
                        CopyablePath(text: "brew install restic", helpText: "Copy the install command")
                        Text("Install restic (Homebrew is the easiest way), then choose Search again.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Search again") {
                            Task { await restic.search(model: model) }
                        }
                        .disabled(restic.isSearching)
                        Button("Locate manually…") {
                            Task { await restic.locateManually(model: model) }
                        }
                        .disabled(restic.isSearching)
                    }
                }
                .padding(4)
            }

            if !resticIsUsable {
                Label("Restic Station cannot back anything up until restic is installed, so this step "
                    + "cannot be skipped.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var agentStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The background agent runs your backups on schedule — including when Restic Station "
                + "is closed. Quitting the app does not stop scheduled backups; removing this agent "
                + "does.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Status")
                        Spacer(minLength: 12)
                        StatusBadge(tone: agentTone, label: agentLabel)
                    }
                    if let diagnostic = launchd.diagnostic {
                        Text(diagnostic)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = permissions.agentError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch launchd.status {
                    case .enabled:
                        EmptyView()
                    case .requiresApproval:
                        Button("Open Login Items settings") { launchd.openLoginItemsSettings() }
                    case .notFound:
                        if launchd.embeddedAgentExists {
                            Button("Enable background agent") { permissions.enableAgent(launchd: launchd) }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                CopyablePath(text: Bundle.main.bundlePath, helpText: "Copy this app's path")
                                Button("Try to register anyway") { permissions.enableAgent(launchd: launchd) }
                            }
                        }
                    default:
                        Button("Enable background agent") { permissions.enableAgent(launchd: launchd) }
                    }
                }
                .padding(4)
            }

            if launchd.status != .enabled {
                Label("Skipping this step means backups only run while Restic Station is open and you "
                    + "start them by hand.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fullDiskAccessStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("macOS hides some files — Mail, Safari, Messages and more — from apps that do not "
                + "have Full Disk Access, and never asks for permission. A backup without it quietly "
                + "skips those files.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(
                        title: "App",
                        tone: tone(for: permissions.appVerdict),
                        badgeLabel: permissions.appVerdict.label,
                        detail: permissions.appVerdict.detail
                    )
                    StatusRow(
                        title: "Background agent",
                        tone: tone(for: model.agentFullDiskAccess),
                        badgeLabel: model.agentFullDiskAccess.label,
                        detail: model.agentFullDiskAccess.detail,
                        isBusy: permissions.recheck == .waiting
                    )
                    HStack {
                        Button("Open Full Disk Access settings") {
                            permissions.openFullDiskAccessSettings()
                        }
                        Button("Re-check") {
                            permissions.recheckAgent(model: model)
                        }
                        .disabled(permissions.recheck == .waiting)
                    }
                    if let message = permissions.recheck.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            Text("Add Restic Station in System Settings → Privacy & Security → Full Disk Access, then "
                + "come back here. The badges update on their own; the agent's badge needs Re-check, "
                + "which restarts it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var firstSetStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A backup set is what to back up, where to send it, and how often. You will choose "
                + "source folders, a destination repository, and a schedule.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    summaryRow(
                        title: "restic",
                        tone: resticChip.tone,
                        label: resticChip.label
                    )
                    summaryRow(
                        title: "Background agent",
                        tone: agentTone,
                        label: agentLabel
                    )
                    summaryRow(
                        title: "Full Disk Access (app)",
                        tone: tone(for: permissions.appVerdict),
                        label: permissions.appVerdict.label
                    )
                    summaryRow(
                        title: "Full Disk Access (agent)",
                        tone: tone(for: model.agentFullDiskAccess),
                        label: model.agentFullDiskAccess.label
                    )
                }
                .padding(4)
            }

            Text("Everything here stays visible in Settings, and the setup assistant can be re-run at "
                + "any time from Settings → General.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summaryRow(title: String, tone: StatusTone, label: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            StatusBadge(tone: tone, label: label)
        }
    }

    // MARK: - Navigation

    private var canContinue: Bool {
        step != .welcome || resticIsUsable
    }

    /// Step 1 is the only one that blocks (`docs/ui-spec.md` §Onboarding).
    private var canSkipCurrentStep: Bool {
        switch step {
        case .welcome: return false
        case .agent: return launchd.status != .enabled
        case .fullDiskAccess: return !permissions.appVerdict.isGranted
        case .firstSet: return false
        }
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation { step = previous }
    }

    /// Ends the assistant. The completion flag is written whichever way the
    /// last step is left ("Finish later" included): the assistant has run,
    /// and re-showing it on the next launch would be nagging, not helping —
    /// Settings → General re-runs it on request.
    private func finish() {
        model.markOnboardingCompleted()
        isPresented = false
    }

    /// Hands off to the Backup Sets section (`docs/ui-spec.md` §Onboarding:
    /// step 4 "→ opens set editor").
    ///
    /// The assistant cannot reach into the main window's navigation state
    /// from here, so it does the two things it can do from any scene —
    /// bring the main window forward, and post the request — and leaves the
    /// Backup Sets screen to observe `.resticStationCreateFirstBackupSet`
    /// and open its editor. If nothing observes it yet, the user still lands
    /// on the Backup Sets list with its "Create your first backup set" empty
    /// state, which is the same destination one click later.
    private func createFirstSet() {
        model.markOnboardingCompleted()
        isPresented = false
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .resticStationCreateFirstBackupSet, object: nil)
    }

    // MARK: - Derived status

    private var resticIsUsable: Bool {
        if case .ok = model.resticStatus { return true }
        return false
    }

    private var resticChip: (tone: StatusTone, label: String, detail: String) {
        switch restic.effectiveStatus(model: model) {
        case .unknown:
            return (.inProgress, "Checking…", "Looking for the restic binary.")
        case .notConfigured:
            return (.problem, "Missing", "No restic binary was found on this Mac.")
        case .ok(let path, let version):
            return (.ok, "restic \(version)", path)
        case .tooOld(let path, let version, let minimum):
            return (.warning, "\(version) found — \(minimum)+ required", path)
        case .unavailable(let path, let reason):
            return (.problem, "Not usable", "\(path): \(reason)")
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
        case .notFound: return launchd.embeddedAgentExists ? "Not registered" : "Not found"
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

// MARK: - Presentation

extension Notification.Name {
    /// Posted by the setup assistant's last step. The Backup Sets screen
    /// (T14) can observe it to open a new-set editor; ignoring it is
    /// harmless.
    static let resticStationCreateFirstBackupSet =
        Notification.Name("net.herila.ResticStation.createFirstBackupSet")
}

/// Presents the setup assistant automatically the first time it is needed
/// (`docs/ui-spec.md` §Onboarding: "first launch, no config").
///
/// Applied by `SettingsRootView`; attaching it to `MainWindow` as well is a
/// one-liner (`MainWindow().onboardingSheet()`) whenever that file is next
/// open — the gate (`AppModel.shouldPresentOnboarding`) is idempotent and
/// safe to apply in more than one place, since completing the assistant
/// writes `onboardingCompleted` before the sheet closes.
struct OnboardingSheetModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    /// When `true`, the sheet also opens by itself the first time the host
    /// view appears and `AppModel.shouldPresentOnboarding` is met.
    var autoPresentOnFirstLaunch: Bool = true

    @State private var hasEvaluated = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                OnboardingView(isPresented: $isPresented)
            }
            .onAppear {
                guard autoPresentOnFirstLaunch, !hasEvaluated else { return }
                hasEvaluated = true
                if model.shouldPresentOnboarding {
                    isPresented = true
                }
            }
    }
}

/// The binding-free form, for hosts that only want the automatic
/// first-launch behaviour.
private struct AutoOnboardingSheetModifier: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content.modifier(OnboardingSheetModifier(isPresented: $isPresented))
    }
}

extension View {
    /// Presents the assistant on demand (a "Setup assistant…" button) and,
    /// unless disabled, automatically on first launch.
    func onboardingSheet(isPresented: Binding<Bool>, autoPresentOnFirstLaunch: Bool = true) -> some View {
        modifier(OnboardingSheetModifier(
            isPresented: isPresented,
            autoPresentOnFirstLaunch: autoPresentOnFirstLaunch
        ))
    }

    /// First-launch presentation only — the one-line form for `MainWindow`.
    func onboardingSheet() -> some View {
        modifier(AutoOnboardingSheetModifier())
    }
}
