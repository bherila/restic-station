import ResticStationCore
import SwiftUI

enum SetEditorSaveState {
    static func hasUnsavedChanges(
        persisted: BackupSet?,
        draft: BackupSet,
        pendingSecretRollbacks: [AppModel.DestinationSecretsRollback]
    ) -> Bool {
        persisted != draft || pendingSecretRollbacks.contains {
            $0.transaction.password != nil || $0.transaction.secretEnv != nil
        }
    }

    static func canFinishRevert(
        startingFingerprint: String,
        currentFingerprint: String
    ) -> Bool {
        startingFingerprint == currentFingerprint
    }
}

/// The set editor (`docs/ui-spec.md` §Backup Sets, **Set editor**): name,
/// sources, excludes, purge excludes, schedule, staleness warning, retention, integrity
/// checks, destinations.
///
/// Editing rules (T14): every change lands in a **draft copy**; *Save*
/// validates through `AppConfig.validate()` (inside `AppModel.saveConfig`)
/// and surfaces each `ConfigError` as an inline message on the section it
/// belongs to. Nothing is written to `config.json` until then — with one
/// deliberate exception the destination editor documents: *Test connection*
/// and *Initialize repository* persist first, because the helper reads the
/// config from disk.
struct SetEditorView: View {
    @EnvironmentObject private var model: AppModel

    @State private var draft: BackupSet
    @State private var isNew: Bool
    @State private var fieldErrors: [SetEditorField: String] = [:]
    @State private var didSave = false
    @State private var showingMachineOverrides = false
    /// Exact config revision this draft was derived from. It is advanced by
    /// this editor's own successful writes, never by a background reload.
    @State private var configFingerprint: String
    /// Destination sheets must update the keychain before the parent draft
    /// can be saved. Retain the old values until the config CAS commits, so
    /// abandoning/reverting the draft or losing a fleet-sync race restores
    /// the matching credentials.
    @State private var pendingSecretRollbacks: [AppModel.DestinationSecretsRollback] = []
    @State private var secretRollbackInProgress = false
    @State private var secretEditorSessionID: UUID

    init(initialSet: BackupSet, isNew: Bool, configFingerprint: String) {
        _draft = State(initialValue: initialSet)
        _isNew = State(initialValue: isNew)
        _configFingerprint = State(initialValue: configFingerprint)
        _secretEditorSessionID = State(initialValue: UUID())
    }

    var body: some View {
        Form {
            nameSection

            SourcesSection(
                sources: $draft.sources,
                errorMessage: fieldErrors[.sources]
            )

            ExcludesSection(excludes: $draft.excludes)

            PurgeExcludesSection(
                purgeExcludes: $draft.purgeExcludes,
                errorMessage: fieldErrors[.purgeExcludes]
            )

            ScheduleSection(
                schedule: $draft.schedule,
                errorMessage: fieldErrors[.schedule]
            )

            machineOverridesSection

            stalenessSection

            RetentionEditorSection(retention: $draft.retention)

            CheckPolicySection(
                checkPolicy: $draft.checkPolicy,
                errorMessage: fieldErrors[.checks]
            )

            DestinationTable(
                set: $draft,
                configFingerprint: $configFingerprint,
                pendingSecretRollbacks: $pendingSecretRollbacks,
                secretEditorSessionID: secretEditorSessionID,
                mutationsDisabled: secretRollbackInProgress,
                errorMessage: fieldErrors[.destinations]
            )

            if let general = fieldErrors[.general] {
                Section {
                    InlineMessage(general)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Restic Station")
        .navigationSubtitle(draft.name.isEmpty ? "New Backup Set" : draft.name)
        .toolbar { toolbarContent }
        .onChange(of: draft) { _, _ in
            didSave = false
        }
        .sheet(isPresented: $showingMachineOverrides) {
            SetMachineOverridesEditor(
                set: $draft,
                sharedConfig: model.config,
                currentMachineID: model.machine.machineId
            )
        }
        .onAppear {
            model.beginSecretEditorSession(secretEditorSessionID)
        }
        .onDisappear {
            // Transfer ownership synchronously before SwiftUI destroys this
            // view. AppModel retries and surfaces failures window-wide.
            let abandoned = pendingSecretRollbacks
            pendingSecretRollbacks.removeAll()
            model.endSecretEditorSession(
                secretEditorSessionID,
                claimedRollbacks: abandoned
            )
        }
    }

    // MARK: - Sections owned by the editor itself

    private var nameSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Projects"))
            if let message = fieldErrors[.name] {
                InlineMessage(message)
            }
        } header: {
            Text("Name")
        }
    }

    private var stalenessSection: some View {
        Section {
            Stepper(value: $draft.stalenessWarningDays, in: 1...365) {
                Text("Warn after \(draft.stalenessWarningDays) "
                    + (draft.stalenessWarningDays == 1 ? "day" : "days")
                    + " without a successful sync")
            }
            if let message = fieldErrors[.staleness] {
                InlineMessage(message)
            }
            Text("A destination that has not received a copy in this long is flagged in the list "
                + "and turns the menu bar icon yellow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Staleness warning")
        }
    }

    private var machineOverridesSection: some View {
        Section {
            LabeledContent("This host") {
                let plan = MachineOverrideUI.effectivePlan(
                    config: configReplacingDraft,
                    machineID: model.machine.machineId
                )
                let runsHere = plan.sets.first(where: { $0.id == draft.id })?.enabled == true
                Label(
                    runsHere ? "Runs here" : "Does not run here",
                    systemImage: runsHere ? "checkmark.circle.fill" : "minus.circle.fill"
                )
                .foregroundStyle(runsHere ? .green : .secondary)
            }
            LabeledContent("Configured profiles", value: "\(draft.machines?.count ?? 0)")
            Button("Edit Machine Overrides…") { showingMachineOverrides = true }
        } header: {
            Text("Machine overrides")
        } footer: {
            Text("Override this set's enabled state, complete source list, or schedule per machine. "
                + "Overrides live in shared config.json; this host's machine.json is never edited here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var configReplacingDraft: AppConfig {
        var config = model.config
        if let index = config.sets.firstIndex(where: { $0.id == draft.id }) {
            config.sets[index] = draft
        } else {
            config.sets.append(draft)
        }
        return config
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if hasUnsavedChanges {
                Text(isNew ? "Not saved yet" : "Unsaved changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if didSave {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Button("Revert") {
                Task { await revert() }
            }
            .disabled(!hasUnsavedChanges || persisted == nil || secretRollbackInProgress)

            Button("Save") {
                Task { await save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!hasUnsavedChanges || secretRollbackInProgress)
        }
    }

    // MARK: - Draft state

    /// What is on disk for this set, if anything.
    private var persisted: BackupSet? {
        model.config.sets.first { $0.id == draft.id }
    }

    private var hasUnsavedChanges: Bool {
        SetEditorSaveState.hasUnsavedChanges(
            persisted: persisted,
            draft: draft,
            pendingSecretRollbacks: pendingSecretRollbacks
        )
    }

    private func revert() async {
        guard let persisted else { return }
        let revertFingerprint = model.configFingerprint
        if let rollbackError = await restorePendingSecrets() {
            fieldErrors[.general] = rollbackError
            return
        }
        guard SetEditorSaveState.canFinishRevert(
            startingFingerprint: revertFingerprint,
            currentFingerprint: model.configFingerprint
        ) else {
            fieldErrors[.general] = "Settings were reloaded while credentials were being restored. "
                + "This draft was left on its original revision; close it and reopen the latest settings."
            return
        }
        draft = persisted
        configFingerprint = model.configFingerprint
        fieldErrors = [:]
    }

    /// Validate → `AppModel.saveSet` → `AppConfig.validate()` →
    /// `ConfigStore.save`. The name check is the editor's own: an unnamed set
    /// is valid config but useless in every list that shows it.
    private func save() async {
        guard !secretRollbackInProgress else {
            fieldErrors[.general] = "The previous credentials are still being restored. "
                + "Wait for restoration to finish before saving."
            return
        }
        fieldErrors = [:]
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            fieldErrors[.name] = "Give this backup set a name."
            return
        }
        if trimmedName != draft.name {
            draft.name = trimmedName
        }

        do {
            configFingerprint = try model.saveSet(
                draft,
                ifUnchangedFrom: configFingerprint
            )
            model.retirePendingSecretRollbackFields(committedBy: pendingSecretRollbacks)
            pendingSecretRollbacks.removeAll()
            isNew = false
            didSave = true
        } catch {
            let mapped = SetsCopy.fieldMessage(for: error)
            var message = mapped.message
            if let storeError = error as? ConfigStoreError,
               storeError.isRevisionConflict,
               !storeError.commitMayBeUncertain,
               let rollbackError = await restorePendingSecrets() {
                message += " " + rollbackError
            } else if let storeError = error as? ConfigStoreError,
                      storeError.commitMayBeUncertain {
                // The candidate may be live but unreadable. Restoring its
                // paired secrets could create a worse config/credential
                // mismatch; require explicit operator reconciliation.
                model.retirePendingSecretRollbackFields(committedBy: pendingSecretRollbacks)
                pendingSecretRollbacks.removeAll()
                message += " Its credential changes were left in place because the app could not "
                    + "determine which config revision is live. Reload settings and verify this destination."
            }
            fieldErrors[mapped.field] = message
        }
    }

    /// Restores every keychain edit which has not yet been paired with a
    /// successful config write. The list is retained if restoration itself
    /// fails, allowing an explicit Revert to retry while this editor lives.
    private func restorePendingSecrets() async -> String? {
        guard !pendingSecretRollbacks.isEmpty else { return nil }
        guard !secretRollbackInProgress else {
            return "The previous keychain values are still being restored."
        }
        secretRollbackInProgress = true
        defer { secretRollbackInProgress = false }
        do {
            try await model.restoreDestinationSecrets(
                pendingSecretRollbacks,
                onProgress: { pendingSecretRollbacks = $0 }
            )
            return nil
        } catch {
            return "The previous keychain values could not be restored (\(error)). "
                + "Re-open the destination and verify its credentials before running a backup."
        }
    }
}
