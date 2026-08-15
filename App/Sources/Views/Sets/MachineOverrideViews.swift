import ResticStationCore
import SwiftUI

// MARK: - Testable effective-plan model

enum MachineOverrideUI {
    static func knownMachineIDs(
        config: AppConfig,
        currentMachineID: String,
        additional: some Sequence<String> = EmptyCollection<String>()
    ) -> [String] {
        var ids = Set(config.referencedMachineIds)
        ids.insert(currentMachineID)
        ids.formUnion(additional)
        return ids.sorted()
    }

    static func effectivePlan(config: AppConfig, machineID: String) -> MachineEffectivePlan {
        let addressable = config.addressable(for: machineID)
        let scheduled = config.resolved(for: machineID)
        let scheduledSets = Dictionary(uniqueKeysWithValues: scheduled.config.sets.map { ($0.id, $0) })

        let sets = addressable.config.sets.map { set in
            let scheduledSet = scheduledSets[set.id]
            let enabledDestinationIDs = Set((scheduledSet?.destinations ?? []).map(\.id))
            return MachineEffectiveSet(
                id: set.id,
                name: set.name,
                enabled: scheduledSet != nil,
                sources: set.sources,
                schedule: set.schedule,
                destinations: set.destinations.map { destination in
                    MachineEffectiveDestination(
                        id: destination.id,
                        label: destination.label,
                        repoURL: destination.repoURL,
                        isPrimary: destination.isPrimary,
                        enabled: enabledDestinationIDs.contains(destination.id)
                    )
                }
            )
        }

        return MachineEffectivePlan(
            machineID: machineID,
            sets: sets,
            exclusions: scheduled.omissions.map(String.init(describing:))
        )
    }
}

struct MachineEffectivePlan: Equatable, Sendable {
    let machineID: String
    let sets: [MachineEffectiveSet]
    let exclusions: [String]
}

struct MachineEffectiveSet: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let enabled: Bool
    let sources: [String]
    let schedule: Schedule
    let destinations: [MachineEffectiveDestination]
}

struct MachineEffectiveDestination: Equatable, Identifiable, Sendable {
    let id: UUID
    let label: String
    let repoURL: String
    let isPrimary: Bool
    let enabled: Bool
}

// MARK: - Effective-plan sheet

struct MachineEffectivePlanView: View {
    @Environment(\.dismiss) private var dismiss

    let config: AppConfig
    let currentMachineID: String
    @State private var selectedMachineID: String

    init(config: AppConfig, currentMachineID: String) {
        self.config = config
        self.currentMachineID = currentMachineID
        _selectedMachineID = State(initialValue: currentMachineID)
    }

    private var machineIDs: [String] {
        MachineOverrideUI.knownMachineIDs(config: config, currentMachineID: currentMachineID)
    }

    private var plan: MachineEffectivePlan {
        MachineOverrideUI.effectivePlan(config: config, machineID: selectedMachineID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Effective Backup Plan")
                        .font(.title3.weight(.semibold))
                    Text("Preview exactly what a machine will back up, after shared-config overrides.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section("Machine") {
                    Picker("Profile", selection: $selectedMachineID) {
                        ForEach(machineIDs, id: \.self) { machineID in
                            Text(machineLabel(machineID)).tag(machineID)
                        }
                    }
                    Text("These are the machine IDs referenced by config.json, plus this host. "
                        + "Previewing another profile does not edit this host's machine.json.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if plan.sets.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Nothing runs on this machine",
                            systemImage: "externaldrive.badge.xmark",
                            description: Text("Review the exclusions below to see why.")
                        )
                    }
                } else {
                    ForEach(plan.sets) { set in
                        effectiveSetSection(set)
                    }
                }

                if !plan.exclusions.isEmpty {
                    Section("Excluded on this machine") {
                        ForEach(plan.exclusions, id: \.self) { exclusion in
                            Label(exclusion, systemImage: "minus.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 580, idealHeight: 700)
    }

    private func machineLabel(_ machineID: String) -> String {
        machineID == currentMachineID ? "\(machineID) — this host" : machineID
    }

    private func effectiveSetSection(_ set: MachineEffectiveSet) -> some View {
        Section {
            LabeledContent("Status") {
                Label(
                    set.enabled ? "Runs here" : "Does not run here",
                    systemImage: set.enabled ? "checkmark.circle.fill" : "minus.circle.fill"
                )
                .foregroundStyle(set.enabled ? .green : .secondary)
            }
            LabeledContent("Schedule", value: SetsCopy.scheduleSummary(set.schedule))
            LabeledContent("Sources") {
                VStack(alignment: .trailing, spacing: 3) {
                    if set.sources.isEmpty {
                        Text("None")
                    } else {
                        ForEach(set.sources, id: \.self) { source in
                            Text(source).monospaced().textSelection(.enabled)
                        }
                    }
                }
            }
            ForEach(set.destinations) { destination in
                LabeledContent(destination.isPrimary ? "Primary" : "Secondary") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(
                            destination.label,
                            systemImage: destination.enabled ? "checkmark.circle" : "minus.circle"
                        )
                        Text(destination.repoURL)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text(set.name)
        }
    }
}

// MARK: - Backup-set override editor

struct SetMachineOverridesEditor: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var set: BackupSet
    let sharedConfig: AppConfig
    let currentMachineID: String

    @State private var selectedMachineID: String
    @State private var newMachineID = ""
    @State private var machineIDError: String?

    init(set: Binding<BackupSet>, sharedConfig: AppConfig, currentMachineID: String) {
        _set = set
        self.sharedConfig = sharedConfig
        self.currentMachineID = currentMachineID
        _selectedMachineID = State(initialValue: currentMachineID)
    }

    private var machineIDs: [String] {
        MachineOverrideUI.knownMachineIDs(
            config: sharedConfig,
            currentMachineID: currentMachineID,
            additional: self.set.machines.map { Array($0.keys) } ?? []
        )
    }

    private var selectedOverride: BackupSetMachineOverride {
        self.set.machines?[selectedMachineID] ?? BackupSetMachineOverride()
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "Backup Set Machine Overrides")
            Divider()
            Form {
                profileSection
                enabledSection

                Section {
                    Toggle("Replace the shared sources", isOn: sourcesOverrideEnabled)
                    Text("A machine source list replaces the shared list completely; it is never merged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sources")
                }
                if selectedOverride.sources != nil {
                    SourcesSection(sources: sourcesBinding, errorMessage: nil)
                }

                Section {
                    Toggle("Replace the shared schedule", isOn: scheduleOverrideEnabled)
                    Text("When off, this machine inherits \(SetsCopy.scheduleSummary(self.set.schedule)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Schedule")
                }
                if selectedOverride.schedule != nil {
                    ScheduleSection(schedule: scheduleBinding, errorMessage: nil)
                }

                removeSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 620, idealHeight: 720)
    }

    private func sheetHeader(title: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(self.set.name).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var profileSection: some View {
        Section {
            Picker("Machine", selection: $selectedMachineID) {
                ForEach(machineIDs, id: \.self) { machineID in
                    Text(machineID == currentMachineID ? "\(machineID) — this host" : machineID)
                        .tag(machineID)
                }
            }
            HStack {
                TextField("new-machine-id", text: $newMachineID)
                    .monospaced()
                Button("Add Profile") { addProfile() }
                    .disabled(newMachineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let machineIDError {
                InlineMessage(machineIDError)
            }
            Text("Only config.json is edited. This host's machine.json identity remains local and unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Machine profile")
        }
    }

    private var enabledSection: some View {
        Section {
            Picker("Back up this set", selection: enabledBinding) {
                Text("Inherit (enabled)").tag(Bool?.none)
                Text("Enabled").tag(Bool?.some(true))
                Text("Disabled").tag(Bool?.some(false))
            }
            Text("Disable the whole set when this machine should not schedule backups for it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Availability")
        }
    }

    private var removeSection: some View {
        Section {
            Button("Remove Override for \(selectedMachineID)", role: .destructive) {
                var machines = self.set.machines ?? [:]
                machines.removeValue(forKey: selectedMachineID)
                self.set.machines = machines.isEmpty ? nil : machines
            }
            .disabled(self.set.machines?[selectedMachineID] == nil)
        } footer: {
            Text("Removing an override makes this machine inherit all shared values.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool?> {
        Binding(get: { selectedOverride.enabled }, set: { value in mutateOverride { $0.enabled = value } })
    }

    private var sourcesOverrideEnabled: Binding<Bool> {
        Binding(
            get: { selectedOverride.sources != nil },
            set: { enabled in mutateOverride { $0.sources = enabled ? self.set.sources : nil } }
        )
    }

    private var sourcesBinding: Binding<[String]> {
        Binding(
            get: { selectedOverride.sources ?? self.set.sources },
            set: { value in mutateOverride { $0.sources = value } }
        )
    }

    private var scheduleOverrideEnabled: Binding<Bool> {
        Binding(
            get: { selectedOverride.schedule != nil },
            set: { enabled in mutateOverride { $0.schedule = enabled ? self.set.schedule : nil } }
        )
    }

    private var scheduleBinding: Binding<Schedule> {
        Binding(
            get: { selectedOverride.schedule ?? self.set.schedule },
            set: { value in mutateOverride { $0.schedule = value } }
        )
    }

    private func mutateOverride(_ mutate: (inout BackupSetMachineOverride) -> Void) {
        var machines = self.set.machines ?? [:]
        var value = machines[selectedMachineID] ?? BackupSetMachineOverride()
        mutate(&value)
        machines[selectedMachineID] = value
        self.set.machines = machines
    }

    private func addProfile() {
        let value = newMachineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MachineIdentity.isValid(value) else {
            machineIDError = "Use lowercase letters, numbers, and hyphens only."
            return
        }
        var machines = self.set.machines ?? [:]
        machines[value] = machines[value] ?? BackupSetMachineOverride()
        self.set.machines = machines
        selectedMachineID = value
        newMachineID = ""
        machineIDError = nil
    }
}

// MARK: - Destination override editor

struct DestinationMachineOverridesEditor: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var destination: Destination
    let sharedConfig: AppConfig
    let currentMachineID: String

    @State private var selectedMachineID: String
    @State private var newMachineID = ""
    @State private var machineIDError: String?
    @State private var environmentRows: [EnvRow]

    init(destination: Binding<Destination>, sharedConfig: AppConfig, currentMachineID: String) {
        _destination = destination
        self.sharedConfig = sharedConfig
        self.currentMachineID = currentMachineID
        _selectedMachineID = State(initialValue: currentMachineID)
        _environmentRows = State(initialValue: EnvRow.rows(
            from: destination.wrappedValue.machines?[currentMachineID]?.nonSecretEnv ?? [:],
            excludingKeys: []
        ))
    }

    private var machineIDs: [String] {
        MachineOverrideUI.knownMachineIDs(
            config: sharedConfig,
            currentMachineID: currentMachineID,
            additional: destination.machines.map { Array($0.keys) } ?? []
        )
    }

    private var selectedOverride: DestinationMachineOverride {
        destination.machines?[selectedMachineID] ?? DestinationMachineOverride()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Destination Machine Overrides").font(.title3.weight(.semibold))
                    Text(destination.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            Form {
                profileSection

                Section("Availability") {
                    Picker("Use this destination", selection: enabledBinding) {
                        Text("Inherit (enabled)").tag(Bool?.none)
                        Text("Enabled").tag(Bool?.some(true))
                        Text("Disabled").tag(Bool?.some(false))
                    }
                    Text("Disable a destination that is unavailable on this machine. "
                        + "A running set must still have exactly one enabled primary.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Repository URL") {
                    Toggle("Replace the shared repository URL", isOn: repoURLOverrideEnabled)
                    if selectedOverride.repoURL != nil {
                        TextField("Repository URL", text: repoURLBinding)
                            .monospaced()
                    }
                    Text("The override is a complete restic repository URL, not a partial path.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Non-secret environment") {
                    Toggle("Replace the shared environment", isOn: environmentOverrideEnabled)
                    if selectedOverride.nonSecretEnv != nil {
                        EnvRowsEditor(rows: $environmentRows, isSecret: false)
                    }
                    Text("This dictionary replaces the shared values completely. Passwords and secret "
                        + "variables remain in the destination's local secret store and are never written here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Remove Override for \(selectedMachineID)", role: .destructive) {
                        var machines = destination.machines ?? [:]
                        machines.removeValue(forKey: selectedMachineID)
                        destination.machines = machines.isEmpty ? nil : machines
                        environmentRows = []
                    }
                    .disabled(destination.machines?[selectedMachineID] == nil)
                } footer: {
                    Text("Removing an override makes this machine inherit all shared values.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 600, idealHeight: 700)
        .onChange(of: environmentRows) { _, rows in
            guard selectedOverride.nonSecretEnv != nil else { return }
            mutateOverride { $0.nonSecretEnv = EnvRow.dictionary(from: rows) }
        }
    }

    private var profileSection: some View {
        Section {
            Picker("Machine", selection: Binding(
                get: { selectedMachineID },
                set: { selectMachine($0) }
            )) {
                ForEach(machineIDs, id: \.self) { machineID in
                    Text(machineID == currentMachineID ? "\(machineID) — this host" : machineID)
                        .tag(machineID)
                }
            }
            HStack {
                TextField("new-machine-id", text: $newMachineID).monospaced()
                Button("Add Profile") { addProfile() }
                    .disabled(newMachineID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let machineIDError { InlineMessage(machineIDError) }
            Text("Only config.json is edited. This host's machine.json identity remains local and unchanged.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Machine profile")
        }
    }

    private var enabledBinding: Binding<Bool?> {
        Binding(get: { selectedOverride.enabled }, set: { value in mutateOverride { $0.enabled = value } })
    }

    private var repoURLOverrideEnabled: Binding<Bool> {
        Binding(
            get: { selectedOverride.repoURL != nil },
            set: { enabled in mutateOverride { $0.repoURL = enabled ? destination.repoURL : nil } }
        )
    }

    private var repoURLBinding: Binding<String> {
        Binding(
            get: { selectedOverride.repoURL ?? destination.repoURL },
            set: { value in mutateOverride { $0.repoURL = value } }
        )
    }

    private var environmentOverrideEnabled: Binding<Bool> {
        Binding(
            get: { selectedOverride.nonSecretEnv != nil },
            set: { enabled in
                if enabled {
                    environmentRows = EnvRow.rows(from: destination.nonSecretEnv, excludingKeys: [])
                    mutateOverride { $0.nonSecretEnv = destination.nonSecretEnv }
                } else {
                    mutateOverride { $0.nonSecretEnv = nil }
                    environmentRows = []
                }
            }
        )
    }

    private func mutateOverride(_ mutate: (inout DestinationMachineOverride) -> Void) {
        var machines = destination.machines ?? [:]
        var value = machines[selectedMachineID] ?? DestinationMachineOverride()
        mutate(&value)
        machines[selectedMachineID] = value
        destination.machines = machines
    }

    private func selectMachine(_ machineID: String) {
        selectedMachineID = machineID
        environmentRows = EnvRow.rows(
            from: destination.machines?[machineID]?.nonSecretEnv ?? [:],
            excludingKeys: []
        )
        machineIDError = nil
    }

    private func addProfile() {
        let value = newMachineID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MachineIdentity.isValid(value) else {
            machineIDError = "Use lowercase letters, numbers, and hyphens only."
            return
        }
        var machines = destination.machines ?? [:]
        machines[value] = machines[value] ?? DestinationMachineOverride()
        destination.machines = machines
        newMachineID = ""
        selectMachine(value)
    }
}
