import AppKit
import ResticStationCore
import SwiftUI

/// The `MenuBarExtra` menu, exactly per `docs/ui-spec.md` §Menu bar:
///
/// 1. one disabled status line per set,
/// 2. a disabled progress line for each in-flight run,
/// 3. divider + `Back Up Now ▸` submenu (per-set, disabled while busy),
/// 4. divider + `Open Restic Station` / `Quit Restic Station`.
///
/// Plain `Text` items render as disabled menu items, which is exactly the
/// "informational, not clickable" affordance the spec asks for.
///
/// The lines are computed when the menu is *built* (i.e. when it opens):
/// NSMenu items do not live-update reliably while a menu is open, which the
/// spec explicitly accepts for the progress line.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let failure = model.scheduleStateFailure {
                Text("Schedule state needs recovery")
                    .help(failure.recoveryMessage)
                Divider()
            }

            if let error = model.pendingSecretRollbackError {
                Text("Credential restoration needs attention")
                    .help(error)
                Button("Retry Credential Restoration") {
                    model.retryPendingSecretRollbacks()
                }
                Divider()
            }

            if model.setHealths.isEmpty {
                Text("No backup sets yet")
            } else {
                ForEach(model.setHealths) { health in
                    Text(MenuBarCopy.statusLine(for: health))
                }
                ForEach(model.setHealths.filter(\.isRunning)) { health in
                    Text(MenuBarCopy.progressLine(for: health))
                }
            }

            Divider()

            Menu("Back Up Now") {
                ForEach(model.setHealths) { health in
                    let reason = model.backUpNowUnavailableReason(setId: health.setId)
                    Button(health.name) {
                        model.backUpNow(setId: health.setId)
                    }
                    .disabled(reason != nil)
                    .help(reason ?? "Back up \(health.name) now.")
                }
            }
            .disabled(model.setHealths.isEmpty)

            Divider()

            Button("Open Restic Station") {
                openMainWindow()
            }

            Button("Quit Restic Station") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .help("Scheduled backups keep running after you quit — they are handled by a background agent.")
        }
        .onAppear {
            // Covers the launch-with-no-window case (the menu bar extra can
            // be the only visible part of the app) and refreshes anything
            // that has no change notification of its own before the menu is
            // rendered.
            model.start()
            model.refresh()
        }
    }

    /// Activates the app and brings the main window forward, reusing the
    /// existing one when there is one — `openWindow(id:)` on a `WindowGroup`
    /// would otherwise open a second copy of the same window.
    private func openMainWindow() {
        NSApplication.shared.activate()
        let existing = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue.hasPrefix(AppWindowID.main) == true
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: AppWindowID.main)
        }
    }
}

// MARK: - Copy

/// The menu's text, kept separate from the view so the exact strings from
/// `docs/ui-spec.md` §Menu bar live in one readable place.
enum MenuBarCopy {

    /// `"<SetName> — <relative last backup> <✓|⚠|✕>"`, e.g.
    /// "Projects — 2 hours ago ✓". Never run: "Projects — never backed up".
    static func statusLine(for health: SetHealth, now: Date = Date()) -> String {
        guard let lastBackupAt = health.lastBackupAt else {
            return "\(health.name) — never backed up"
        }
        let formatter = RelativeDateTimeFormatter()
        let relative = formatter.localizedString(for: lastBackupAt, relativeTo: now)
        return "\(health.name) — \(relative) \(glyph(for: health))"
    }

    /// `"Backing up <SetName>… 42%"`. The verb follows the run's phase
    /// (`docs/data-model.md` §current-run): a mirror copy or a repository
    /// check is not "backing up", and saying so would misreport what restic
    /// is doing to the user's data.
    static func progressLine(for health: SetHealth) -> String {
        let percent = health.progressPercent ?? 0
        return "\(verb(for: health.currentRun?.phase)) \(health.name)… \(percent)%"
    }

    /// ✓ success · ⚠ warning or skipped · ✕ failed.
    static func glyph(for health: SetHealth) -> String {
        switch health.lastBackupStatus {
        case .success:
            return "✓"
        case .failed:
            return "✕"
        case .warning, .skipped, .running, .none:
            return "⚠"
        }
    }

    private static func verb(for phase: String?) -> String {
        guard let phase else { return "Backing up" }
        if phase.hasPrefix("copying") {
            return "Copying"
        }
        switch phase {
        case "checking":
            return "Checking"
        case "retention":
            return "Cleaning up"
        case "restoring":
            return "Restoring"
        case "initializing":
            return "Initializing"
        default:
            return "Backing up"
        }
    }
}

// MARK: - Icon

extension AppHealth {
    /// The ordinary three symbols from `docs/ui-spec.md` plus a red-X drive
    /// for the destructive-audit critical state.
    var menuBarSymbolName: String {
        switch self {
        case .critical:
            return "externaldrive.badge.xmark"
        case .idle:
            return "externaldrive.badge.checkmark"
        case .running:
            return "externaldrive.badge.timemachine"
        case .warning:
            return "externaldrive.badge.exclamationmark"
        }
    }
}
