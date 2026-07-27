import ResticStationCore
import SwiftUI

/// The set editor (`docs/ui-spec.md` §Backup Sets, **Set editor**): name,
/// sources, excludes, schedule, staleness warning, retention, integrity
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

    init(initialSet: BackupSet, isNew: Bool) {
        _draft = State(initialValue: initialSet)
        _isNew = State(initialValue: isNew)
    }

    var body: some View {
        Form {
            nameSection

            SourcesSection(
                sources: $draft.sources,
                errorMessage: fieldErrors[.sources]
            )

            ExcludesSection(excludes: $draft.excludes)

            ScheduleSection(
                schedule: $draft.schedule,
                errorMessage: fieldErrors[.schedule]
            )

            stalenessSection

            RetentionSection(retention: $draft.retention)

            CheckPolicySection(
                checkPolicy: $draft.checkPolicy,
                errorMessage: fieldErrors[.checks]
            )

            DestinationTable(
                set: $draft,
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

            Button("Revert") { revert() }
                .disabled(!hasUnsavedChanges || persisted == nil)

            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!hasUnsavedChanges)
        }
    }

    // MARK: - Draft state

    /// What is on disk for this set, if anything.
    private var persisted: BackupSet? {
        model.config.sets.first { $0.id == draft.id }
    }

    private var hasUnsavedChanges: Bool {
        persisted != draft
    }

    private func revert() {
        guard let persisted else { return }
        draft = persisted
        fieldErrors = [:]
    }

    /// Validate → `AppModel.saveSet` → `AppConfig.validate()` →
    /// `ConfigStore.save`. The name check is the editor's own: an unnamed set
    /// is valid config but useless in every list that shows it.
    private func save() {
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
            try model.saveSet(draft)
            isNew = false
            didSave = true
        } catch {
            let mapped = SetsCopy.fieldMessage(for: error)
            fieldErrors[mapped.field] = mapped.message
        }
    }
}
