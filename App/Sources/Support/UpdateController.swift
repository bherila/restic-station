import AppKit
import Combine
import ResticStationCore
import Sparkle
import SwiftUI

/// Owns the Sparkle updater (`docs/release.md` §Updates): a daily background
/// check against the GitHub Releases appcast, Sparkle's standard update
/// window, and nothing installed without the user clicking Install
/// (`SUAllowsAutomaticUpdates` is `NO` in Info.plist).
///
/// Its one piece of policy is `UpdateSchemaGate`: an update that migrates the
/// shared `config.json` is explained and confirmed before Sparkle's window is
/// allowed to offer it.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Mirrors `SPUUpdater.canCheckForUpdates` (false while a check or an
    /// install is already in flight) for the "Check for Updates…" items.
    @Published private(set) var canCheckForUpdates = false

    /// Versions whose schema change the user has already confirmed, so
    /// Sparkle's "Remind Me Later" doesn't re-ask the same question.
    static let acknowledgedVersionsKey = "UpdateSchemaGate.acknowledgedVersions"

    private let defaults: UserDefaults
    private let runningSchema: Int
    /// Presents the confirmation; `true` means "continue to the update".
    /// Injected so tests can drive `evaluate` without a modal alert.
    private let confirm: @MainActor (_ title: String, _ message: String) -> Bool
    private var controller: SPUStandardUpdaterController?
    private var cancellables: Set<AnyCancellable> = []

    /// True when the process is the host app of a unit-test run
    /// (`xcodebuild test` sets this for Swift Testing suites too).
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(
        defaults: UserDefaults = .standard,
        runningSchema: Int = AppConfig.currentVersion,
        startingUpdater: Bool = !UpdateController.isTestHost,
        confirm: (@MainActor (_ title: String, _ message: String) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.runningSchema = runningSchema
        self.confirm = confirm ?? UpdateController.presentConfirmation
        super.init()
        // Never started in a test host: a test run must not schedule a real
        // network check or show Sparkle's windows.
        guard startingUpdater else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Settings → General's "Check for updates automatically".
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try evaluate(
            declared: item.propertiesDictionary[UpdateSchemaGate.appcastElement],
            version: item.displayVersionString,
            build: item.versionString,
            updateCheck: updateCheck
        )
    }

    /// The gate, separated from Sparkle's types so it is testable. Throws to
    /// stop Sparkle from offering the update: `SUInstallationCanceledError`
    /// ends the check silently (the user already said "Not Now"); any other
    /// error is shown to the user for a check they started.
    func evaluate(declared: Any?, version: String, build: String, updateCheck: SPUUpdateCheck) throws {
        // `.updateInformation` only probes; nothing is offered or installed.
        guard updateCheck != .updateInformation else { return }

        switch UpdateSchemaGate.decision(declared: declared, running: runningSchema) {
        case .proceed:
            return
        case .refuse(let declaredSchema):
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.validationError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: UpdateSchemaGate.refusalMessage(
                    version: version, declared: declaredSchema, running: runningSchema
                ),
            ])
        case .confirm(let change):
            if acknowledgedBuilds.contains(build) {
                return
            }
            let proceed = confirm(
                UpdateSchemaGate.confirmationTitle(version: version, change: change),
                UpdateSchemaGate.confirmationMessage(change: change)
            )
            guard proceed else {
                throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
            }
            defaults.set(Array(acknowledgedBuilds.union([build])).sorted(), forKey: Self.acknowledgedVersionsKey)
        }
    }

    private var acknowledgedBuilds: Set<String> {
        Set(defaults.stringArray(forKey: Self.acknowledgedVersionsKey) ?? [])
    }

    private static func presentConfirmation(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue to Update…")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// "Check for Updates…", shared by the app menu and the menu bar extra.
struct CheckForUpdatesButton: View {
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheckForUpdates)
    }
}
