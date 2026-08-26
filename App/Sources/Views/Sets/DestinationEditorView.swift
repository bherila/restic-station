import AppKit
import ResticStationCore
import SwiftUI

/// The destination editor sheet (`docs/ui-spec.md` §Backup Sets →
/// *Destination editor*): label, a kind picker driving one of three forms,
/// the repository password, and the two repository actions.
///
/// **Where things are stored.** The repository URL and non-secret env end up
/// in `config.json`; the password and every secret env var go to the login
/// keychain keyed by the destination's UUID (`docs/data-model.md` §Keychain
/// items) — which is why a new destination is given its UUID *before* this
/// sheet opens and never regenerates it.
///
/// **Why *Test connection* saves first.** `probe-repo` and `init-secondary`
/// run in the helper, which reads `config.json` and the keychain itself
/// (`docs/architecture.md` §Process model). A destination that exists only in
/// this sheet's `@State` is invisible to it. So both buttons commit the draft
/// into the set *and* persist the set before they invoke anything — and a
/// validation failure from that save is shown here rather than silently
/// probing a stale config.
struct DestinationEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @Binding var set: BackupSet
    @Binding var configFingerprint: String
    private let isNew: Bool

    // Config-backed fields.
    @State private var draft: Destination
    @State private var kind: FormKind
    @State private var localPath: String
    @State private var endpoint: String
    @State private var bucket: String
    @State private var prefix: String
    @State private var region: String
    @State private var rawURL: String
    @State private var nonSecretEnvRows: [EnvRow]

    // Keychain-backed fields.
    @State private var password: String = ""
    @State private var accessKeyID: String = ""
    @State private var secretAccessKey: String = ""
    @State private var secretEnvRows: [EnvRow] = []
    /// `true` once the existing keychain items have been read (or there were
    /// none to read). Until then an empty field means "unknown", not "clear
    /// it" — see `secretEnvToWrite`.
    @State private var secretsLoaded = false
    @State private var secretsNote: String?

    // Transient UI state.
    @State private var probe: DestinationProbeOutcome?
    @State private var busy: BusyKind?
    @State private var message: EditorMessage?
    @State private var showingMachineOverrides = false

    init(
        set: Binding<BackupSet>,
        configFingerprint: Binding<String>,
        initialDestination destination: Destination,
        isNew: Bool
    ) {
        _set = set
        _configFingerprint = configFingerprint
        self.isNew = isNew
        _draft = State(initialValue: destination)

        let formKind = FormKind(destination: destination)
        _kind = State(initialValue: formKind)
        _localPath = State(initialValue: formKind == .local ? destination.repoURL : "")

        let s3 = formKind == .s3 ? S3RepoURL.decompose(destination.repoURL) : nil
        _endpoint = State(initialValue: s3?.endpoint ?? "")
        _bucket = State(initialValue: s3?.bucket ?? "")
        _prefix = State(initialValue: s3?.prefix ?? "")
        _region = State(initialValue: destination.nonSecretEnv[Self.regionKey] ?? "")

        _rawURL = State(initialValue: formKind.usesRawURL ? destination.repoURL : "")
        _nonSecretEnvRows = State(initialValue: EnvRow.rows(
            from: destination.nonSecretEnv,
            excludingKeys: formKind == .s3 ? [Self.regionKey] : []
        ))
    }

    private static let regionKey = "AWS_DEFAULT_REGION"

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                identitySection

                machineOverridesSection

                switch kind {
                case .local:
                    localSection
                case .s3:
                    s3Section
                case .sftp, .rest, .other:
                    rawURLSection
                    envSections
                }

                passwordSection
                connectionSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 560, idealHeight: 640)
        .task {
            await loadSecrets()
        }
        .sheet(isPresented: $showingMachineOverrides) {
            DestinationMachineOverridesEditor(
                destination: $draft,
                sharedConfig: model.config,
                currentMachineID: model.machine.machineId
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(isNew ? "Add Destination" : "Edit Destination")
                    .font(.title3.weight(.semibold))
                Text(draft.isPrimary
                    ? "Primary — backups are written here."
                    : "Secondary — mirrored from the primary after each backup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    // MARK: - Sections

    private var identitySection: some View {
        Section {
            TextField("Label", text: $draft.label, prompt: Text("External HDD"))
            Picker("Kind", selection: kindBinding) {
                ForEach(FormKind.allCases) { formKind in
                    Text(formKind.title).tag(formKind)
                }
            }
        }
    }

    private var machineOverridesSection: some View {
        Section {
            LabeledContent("Configured profiles", value: "\(draft.machines?.count ?? 0)")
            Button("Edit Machine Overrides…") { openMachineOverrides() }
        } header: {
            Text("Machine overrides")
        } footer: {
            Text("Override this destination's enabled state, complete repository URL, or non-secret "
                + "environment per machine. Secrets stay in the local secret store.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Local

    private var localSection: some View {
        Section {
            HStack {
                TextField("Folder", text: $localPath, prompt: Text("/Volumes/BackupDisk/projects.restic"))
                    .monospaced()
                Button("Choose…") { chooseFolder() }
            }

            if isICloudPath {
                InlineMessage(SetsCopy.iCloudWarning, level: .warning)
            }
            if isRemovableVolumePath {
                InlineMessage(removableVolumeText, level: .info)
            }
        } header: {
            Text("Local folder")
        } footer: {
            Text("restic creates the repository in this folder when you initialize it. "
                + "The folder does not have to exist yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: S3

    private var s3Section: some View {
        Section {
            TextField("Endpoint", text: $endpoint, prompt: Text(SetsCopy.s3EndpointPlaceholder))
                .monospaced()
            TextField("Bucket", text: $bucket, prompt: Text("my-bucket"))
            TextField("Path prefix", text: $prefix, prompt: Text("projects"))
            TextField("Region", text: $region, prompt: Text("auto"))

            LabeledContent("Repository URL") {
                Text(assembledRepoURL.isEmpty ? "—" : assembledRepoURL)
                    .monospaced()
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            TextField("Access Key ID", text: $accessKeyID)
                .monospaced()
            SecureField("Secret Access Key", text: $secretAccessKey)

            if hasOtherS3Destination {
                InlineMessage(SetsCopy.sharedS3CredentialsNote, level: .info)
            }
        } header: {
            Text("S3-compatible")
        } footer: {
            Text("Leave the endpoint empty for AWS S3. Cloudflare R2 uses "
                + "https://<accountid>.r2.cloudflarestorage.com with region “auto”. "
                + "The two keys are stored in your login keychain, never in config.json.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: SFTP / REST / Other

    private var rawURLSection: some View {
        Section {
            TextField("Repository URL", text: $rawURL, prompt: Text(kind.rawURLPlaceholder))
                .monospaced()
            if kind == .sftp {
                Toggle("Run pack reclamation on this SSH host", isOn: Binding(
                    get: { draft.remoteMaintenance?.enabled ?? false },
                    set: { enabled in
                        var remote = draft.remoteMaintenance ?? RemoteMaintenance()
                        remote.enabled = enabled
                        draft.remoteMaintenance = remote
                    }
                ))
                if draft.remoteMaintenance?.enabled == true {
                    TextField("SSH target", text: remoteMaintenanceBinding(\.sshTarget))
                        .monospaced()
                    TextField("Remote repository path", text: remoteMaintenanceBinding(\.remoteRepoPath))
                        .monospaced()
                    TextField("Remote restic path", text: Binding(
                        get: { draft.remoteMaintenance?.remoteResticPath ?? "restic" },
                        set: { value in
                            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.remoteMaintenance?.remoteResticPath = trimmed.isEmpty ? nil : trimmed
                        }
                    )).monospaced()
                }
            }
        } header: {
            Text(kind.title)
        } footer: {
            Text(SetsCopy.rawRepoCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var envSections: some View {
        Section {
            EnvRowsEditor(rows: $nonSecretEnvRows, isSecret: false)
        } header: {
            Text("Environment variables")
        } footer: {
            Text("Stored in config.json. Use these for non-secret settings restic reads from the "
                + "environment, such as a region name.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section {
            EnvRowsEditor(rows: $secretEnvRows, isSecret: true)
        } header: {
            Text("Secret environment variables")
        } footer: {
            Text("Stored in your login keychain, alongside the repository password.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Password

    private var passwordSection: some View {
        Section {
            HStack {
                SecureField("Repository password", text: $password)
                Button("Generate") { password = SetsCopy.generatePassword() }
                    .help("Generate a 32-character random password")
            }

            InlineMessage(SetsCopy.passwordSafety, level: .warning)

            if let secretsNote {
                Text(secretsNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Repository password")
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            HStack(spacing: 12) {
                Button("Test connection") { testConnection() }
                    .disabled(busy != nil)

                if kind == .sftp, draft.remoteMaintenance?.enabled == true {
                    Button("Test remote maintenance") { testRemoteMaintenance() }
                        .disabled(busy != nil)
                }

                // Prominent exactly when the probe said the repository is
                // missing (ui-spec: "surface Initialize prominently").
                if needsInitialization {
                    Button("Initialize repository") { initializeRepository() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy != nil)
                } else {
                    Button("Initialize repository") { initializeRepository() }
                        .disabled(busy != nil)
                }

                if busy != nil {
                    ProgressView().controlSize(.small)
                    Text(busy?.label ?? "")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let probe {
                probeResult(probe)
            }

            if isNew && !draft.isPrimary {
                InlineMessage(SetsCopy.secondaryNeedsInit, level: .info)
            }

            if let message {
                switch message {
                case .error(let text):
                    InlineMessage(text)
                case .success(let text):
                    Label(text, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Repository")
        } footer: {
            Text(draft.isPrimary
                ? "Initializing creates an empty repository at this location."
                : "Initializing copies the primary's chunker parameters, which is what keeps "
                    + "deduplication working between the two repositories.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func probeResult(_ outcome: DestinationProbeOutcome) -> some View {
        switch outcome {
        case .reachable(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .notInitialized(let text):
            VStack(alignment: .leading, spacing: 4) {
                InlineMessage(text, level: .warning)
                Text("Initialize the repository to create it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .offline(let text):
            InlineMessage(text, level: .warning)
        case .error(let text):
            InlineMessage(text)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy != nil)
        }
        .padding(16)
    }

    // MARK: - Derived values

    private var kindBinding: Binding<FormKind> {
        Binding(
            get: { kind },
            set: { newKind in
                kind = newKind
                if newKind != .sftp {
                    draft.remoteMaintenance = nil
                }
                probe = nil
                message = nil
            }
        )
    }

    /// `s3:<endpoint>/<bucket>/<prefix>` for S3; the field's own value
    /// otherwise (`docs/restic-cli.md` §S3-compatible destinations).
    private var assembledRepoURL: String {
        switch kind {
        case .local:
            return localPath.trimmingCharacters(in: .whitespacesAndNewlines)
        case .s3:
            return S3RepoURL.assemble(endpoint: endpoint, bucket: bucket, prefix: prefix)
        case .sftp, .rest, .other:
            return rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var assembledNonSecretEnv: [String: String] {
        switch kind {
        case .s3:
            var env = draft.nonSecretEnv
            let trimmedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedRegion.isEmpty {
                env.removeValue(forKey: Self.regionKey)
            } else {
                env[Self.regionKey] = trimmedRegion
            }
            return env
        case .local:
            return draft.nonSecretEnv
        case .sftp, .rest, .other:
            return EnvRow.dictionary(from: nonSecretEnvRows)
        }
    }

    /// `nil` = "leave the stored blob alone". Only returned before the
    /// existing items have been read, so an in-flight keychain read can never
    /// cause a wipe.
    private var secretEnvToWrite: [String: String]? {
        var env: [String: String] = [:]
        switch kind {
        case .s3:
            let key = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { env["AWS_ACCESS_KEY_ID"] = key }
            if !secretAccessKey.isEmpty { env["AWS_SECRET_ACCESS_KEY"] = secretAccessKey }
        case .local:
            env = [:]
        case .sftp, .rest, .other:
            env = EnvRow.dictionary(from: secretEnvRows)
        }
        if env.isEmpty && !secretsLoaded {
            return nil
        }
        return env
    }

    private var needsInitialization: Bool {
        if case .notInitialized = probe { return true }
        return false
    }

    private var isICloudPath: Bool {
        let path = (localPath as NSString).standardizingPath
        let mobileDocuments = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Mobile Documents")
        return !path.isEmpty && path.hasPrefix(mobileDocuments)
    }

    private var isRemovableVolumePath: Bool {
        localPath.hasPrefix("/Volumes/")
    }

    private var removableVolumeText: String {
        draft.isPrimary
            ? SetsCopy.removableVolumeNote
            : SetsCopy.removableVolumeNote + " — for a secondary destination that is normal."
    }

    private var hasOtherS3Destination: Bool {
        // `self.` is load-bearing: a computed property whose body starts with
        // `set` is parsed as a setter declaration.
        self.set.destinations.contains { $0.id != draft.id && $0.kind == .s3 }
    }

    private func remoteMaintenanceBinding(
        _ keyPath: WritableKeyPath<RemoteMaintenance, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.remoteMaintenance?[keyPath: keyPath] ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.remoteMaintenance?[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - Actions

    private func openMachineOverrides() {
        // The destination form decomposes the shared URL into friendlier
        // fields. Bring those pending values into the draft before the
        // machine editor offers them as the starting point for an override.
        draft.repoURL = assembledRepoURL
        draft.nonSecretEnv = assembledNonSecretEnv
        showingMachineOverrides = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds this restic repository."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = url.path
    }

    private func save() {
        Task {
            busy = .saving
            defer { busy = nil }
            if await commitDraft() != nil {
                dismiss()
            }
        }
    }

    private func testConnection() {
        Task {
            busy = .testing
            defer { busy = nil }
            probe = nil
            guard let updated = await commitDraft(), persistSet(updated) else { return }
            probe = await model.probeDestination(setId: updated.id, destId: draft.id)
        }
    }

    private func testRemoteMaintenance() {
        Task {
            busy = .testingRemoteMaintenance
            defer { busy = nil }
            guard let updated = await commitDraft(), persistSet(updated) else { return }
            switch await model.testRemoteMaintenance(setId: updated.id, destId: draft.id) {
            case .available(let text):
                message = .success(text)
            case .failed(let text):
                message = .error(text)
            }
        }
    }

    private func initializeRepository() {
        Task {
            busy = .initializing
            defer { busy = nil }
            guard let updated = await commitDraft(), persistSet(updated) else { return }
            switch await model.initializeRepository(setId: updated.id, destId: draft.id) {
            case .initialized(let text):
                message = .success(text)
                probe = .reachable(text)
            case .failed(let text):
                message = .error(text)
            }
        }
    }

    /// Validates the form, writes the keychain items, and merges the
    /// destination into the set draft. Returns the merged set (so callers do
    /// not have to read it back through the binding, which is not guaranteed
    /// to reflect the write within the same update), or `nil` with `message`
    /// set when anything refused.
    private func commitDraft() async -> BackupSet? {
        message = nil

        let label = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else {
            message = .error("Give this destination a label — it is how it is named everywhere else.")
            return nil
        }
        let repoURL = assembledRepoURL
        guard !repoURL.isEmpty else {
            message = .error(kind == .local
                ? "Choose the folder that holds this repository."
                : "Enter the repository URL restic should use.")
            return nil
        }
        if kind == .local && !repoURL.hasPrefix("/") {
            message = .error("A local repository needs an absolute path, starting with “/”.")
            return nil
        }
        if kind == .s3 && bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = .error("Enter the bucket this repository lives in.")
            return nil
        }

        var destination = draft
        destination.label = label
        destination.repoURL = repoURL
        destination.nonSecretEnv = assembledNonSecretEnv

        do {
            try await model.storeDestinationSecrets(
                destId: destination.id,
                password: password.isEmpty ? nil : password,
                secretEnv: secretEnvToWrite
            )
        } catch {
            message = .error("The keychain items for this destination could not be written "
                + "(\(error)). Unlock your login keychain, then try again.")
            return nil
        }

        var updated = self.set
        if let index = updated.destinations.firstIndex(where: { $0.id == destination.id }) {
            updated.destinations[index] = destination
        } else {
            updated.destinations.append(destination)
        }
        // Invariant 1 belt-and-braces: a set whose destinations somehow carry
        // no primary gets the first one promoted, so this sheet can never
        // produce a config `validate()` would reject.
        if !updated.destinations.contains(where: \.isPrimary), !updated.destinations.isEmpty {
            updated.destinations[0].isPrimary = true
        }

        draft = destination
        set = updated
        return updated
    }

    /// Persists the whole set so the helper can see this destination. Any
    /// validation failure is the *set's* (no sources yet, for example) and is
    /// reported here with that context.
    private func persistSet(_ updated: BackupSet) -> Bool {
        do {
            configFingerprint = try model.saveSet(
                updated,
                ifUnchangedFrom: configFingerprint
            )
            return true
        } catch {
            let mapped = SetsCopy.fieldMessage(for: error)
            message = .error(mapped.message
                + " Testing and initializing save the backup set first, because the background "
                + "helper reads the saved configuration.")
            return false
        }
    }

    /// Pre-fills the keychain-backed fields when editing an existing
    /// destination. A password that cannot be read is not an error — the
    /// caption then explains that leaving the field blank keeps it.
    private func loadSecrets() async {
        guard !secretsLoaded else { return }
        guard !isNew else {
            secretsLoaded = true
            return
        }

        let secrets = await model.loadDestinationSecrets(destId: draft.id)
        if let existing = secrets.password {
            password = existing
        } else {
            secretsNote = "No stored password was found for this destination. "
                + "Enter one (or generate it) before testing the connection."
        }

        var remaining = secrets.secretEnv
        if kind == .s3 {
            accessKeyID = remaining.removeValue(forKey: "AWS_ACCESS_KEY_ID") ?? ""
            secretAccessKey = remaining.removeValue(forKey: "AWS_SECRET_ACCESS_KEY") ?? ""
        }
        secretEnvRows = EnvRow.rows(from: remaining, excludingKeys: [])
        secretsLoaded = true
    }

    // MARK: - Local types

    private enum EditorMessage: Equatable {
        case error(String)
        case success(String)
    }

    enum BusyKind: Equatable {
        case testing
        case testingRemoteMaintenance
        case initializing
        case saving

        var label: String {
            switch self {
            case .testing: return "Probing the repository…"
            case .testingRemoteMaintenance: return "Testing SSH and remote restic…"
            case .initializing: return "Initializing…"
            case .saving: return "Saving…"
            }
        }
    }

    /// The kind picker's cases. Distinct from `DestinationKind` (which is
    /// *derived* from a repo URL) because the picker has to exist before
    /// there is a URL to derive anything from.
    enum FormKind: String, CaseIterable, Identifiable, Sendable {
        case local
        case s3
        case sftp
        case rest
        case other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .local: return "Local folder"
            case .s3: return "S3-compatible"
            case .sftp: return "SFTP"
            case .rest: return "REST server"
            case .other: return "Other"
            }
        }

        var usesRawURL: Bool {
            switch self {
            case .local, .s3: return false
            case .sftp, .rest, .other: return true
            }
        }

        var rawURLPlaceholder: String {
            switch self {
            case .local: return "/Volumes/BackupDisk/projects.restic"
            case .s3: return "s3:https://endpoint/bucket/prefix"
            case .sftp: return "sftp:user@host:/srv/restic-repo"
            case .rest: return "rest:https://host:8000/projects/"
            case .other: return "b2:bucket:path"
            }
        }

        init(destination: Destination) {
            switch destination.kind {
            case .localPath: self = .local
            case .s3: self = .s3
            case .sftp: self = .sftp
            case .rest: self = .rest
            case .otherCloud: self = .other
            }
        }
    }
}

// MARK: - EnvRow

/// One row of an environment-variable table. Identity is per-row and stable
/// across edits so a `ForEach` binding does not lose focus while typing.
struct EnvRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }

    /// Sorted by key so the table's order is stable across reloads
    /// (dictionaries have none).
    static func rows(from dictionary: [String: String], excludingKeys excluded: Set<String>) -> [EnvRow] {
        dictionary
            .filter { !excluded.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { EnvRow(key: $0.key, value: $0.value) }
    }

    static func dictionary(from rows: [EnvRow]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            result[key] = row.value
        }
        return result
    }
}

// MARK: - EnvRowsEditor

/// The free-form key/value table used for both the non-secret env (plain
/// fields) and the secret env (`SecureField` values).
struct EnvRowsEditor: View {
    @Binding var rows: [EnvRow]
    let isSecret: Bool

    var body: some View {
        if rows.isEmpty {
            Text(isSecret ? "No secret variables." : "No extra variables.")
                .foregroundStyle(.secondary)
        }

        ForEach($rows) { $row in
            HStack {
                TextField("Name", text: $row.key, prompt: Text("AWS_DEFAULT_REGION"))
                    .monospaced()
                if isSecret {
                    SecureField("Value", text: $row.value)
                } else {
                    TextField("Value", text: $row.value, prompt: Text("auto"))
                }
                Button {
                    rows.removeAll { $0.id == row.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this variable")
            }
        }

        HStack {
            Button("Add Variable") { rows.append(EnvRow()) }
            Spacer()
        }
    }
}

// MARK: - S3RepoURL

/// Assembly and decomposition of the S3 repository URL forms documented in
/// `docs/restic-cli.md` §S3-compatible destinations:
///
/// - AWS: `s3:s3.amazonaws.com/<bucket>[/<prefix>]`
/// - Any S3-compatible endpoint: `s3:https://<host>/<bucket>[/<prefix>]`
enum S3RepoURL {
    /// The host used when the endpoint field is left empty ("empty = AWS").
    static let awsDefaultEndpoint = "s3.amazonaws.com"

    static func assemble(endpoint: String, bucket: String, prefix: String) -> String {
        let host = trimSlashes(endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
        let bucketName = trimSlashes(bucket.trimmingCharacters(in: .whitespacesAndNewlines))
        let path = trimSlashes(prefix.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !bucketName.isEmpty else { return "" }
        var url = "s3:\(host.isEmpty ? awsDefaultEndpoint : host)/\(bucketName)"
        if !path.isEmpty {
            url += "/\(path)"
        }
        return url
    }

    /// The inverse, for editing an existing destination. Returns `nil` when
    /// `repoURL` is not an `s3:` URL at all.
    static func decompose(_ repoURL: String) -> (endpoint: String, bucket: String, prefix: String)? {
        guard repoURL.hasPrefix("s3:") else { return nil }
        var remainder = String(repoURL.dropFirst("s3:".count))

        var scheme = ""
        for candidate in ["https://", "http://"] where remainder.hasPrefix(candidate) {
            scheme = candidate
            remainder = String(remainder.dropFirst(candidate.count))
        }

        let components = remainder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let host = components.first else { return ("", "", "") }
        let endpoint = scheme + host
        let bucket = components.count > 1 ? components[1] : ""
        let prefix = components.count > 2 ? components[2...].joined(separator: "/") : ""
        return (
            endpoint == awsDefaultEndpoint ? "" : endpoint,
            bucket,
            prefix
        )
    }

    private static func trimSlashes(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") {
            result.removeLast()
        }
        while result.hasPrefix("/") {
            result.removeFirst()
        }
        return result
    }
}
