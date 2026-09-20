import ResticStationCore
import SwiftUI

/// Settings → Exclusions (`docs/ui-spec.md` §Settings): the global exclusion
/// list this machine applies to every backup set that has not opted out.
///
/// The list itself ships in the binary (`GlobalExcludeCatalog`); this pane
/// edits `global-excludes.json` beside `machine.json`, which holds only the
/// decisions that differ from the built-in defaults
/// (`docs/data-model.md` §global-excludes.json). The settings file's path is
/// shown because "machine level or user level" is decided by which data
/// directory this install resolved, and the honest answer to that question
/// is the path.
struct ExclusionsSettings: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var pane = ExclusionsSettingsModel()

    var body: some View {
        Form {
            if let failure = pane.loadFailure {
                loadFailureSection(failure)
            }
            overviewSection
            groupsSection
            extraPatternsSection
            fileSection
        }
        .formStyle(.grouped)
        .task { pane.load(paths: model.paths) }
    }

    // MARK: Sections

    private func loadFailureSection(_ failure: String) -> some View {
        Section {
            Label {
                Text(failure)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.callout)
        } header: {
            Text("Settings file unusable")
        } footer: {
            Text(ExclusionsCopy.loadFailureFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var overviewSection: some View {
        Section {
            Toggle(ExclusionsCopy.enabledLabel, isOn: enabledBinding)
            Toggle(ExclusionsCopy.excludeCachesLabel, isOn: excludeCachesBinding)
                .disabled(!pane.settings.enabled)
            HStack {
                Toggle(ExclusionsCopy.sizeCapLabel, isOn: sizeCapEnabledBinding)
                TextField(
                    ExclusionsCopy.sizeCapLabel,
                    text: sizeCapBinding,
                    prompt: Text(ExclusionsCopy.sizeCapPlaceholder)
                )
                .labelsHidden()
                .frame(width: 90)
                .disabled(pane.settings.excludeLargerThan == nil)
            }
            .disabled(!pane.settings.enabled)
        } header: {
            Text("Global Exclusions")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ExclusionsCopy.overviewFooter)
                Text(ExclusionsCopy.cacheDirTagFooter)
                Text(ExclusionsCopy.sizeCapFooter)
                if pane.settings.excludeLargerThan.map({ !GlobalExcludeSettings.isValidSize($0) }) == true {
                    Text(ExclusionsCopy.sizeCapInvalid)
                        .foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(GlobalExcludeCatalog.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(group.title, isOn: groupBinding(group))
                        .disabled(!pane.settings.enabled)
                    Text(group.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ExclusionsCopy.patternCount(group.patterns(on: .current).count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("What is skipped")
        } footer: {
            Text(ExclusionsCopy.groupsFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var extraPatternsSection: some View {
        Section {
            if pane.settings.extraPatterns.isEmpty {
                Text(ExclusionsCopy.extraPatternsEmptyState)
                    .foregroundStyle(.secondary)
            }

            ForEach(pane.settings.extraPatterns.indices, id: \.self) { index in
                HStack {
                    TextField("Pattern", text: extraPatternBinding(at: index), prompt: Text("*.iso"))
                        .labelsHidden()
                    Button {
                        pane.removeExtraPattern(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this pattern")
                }
            }

            HStack {
                Button("Add Pattern") { pane.addExtraPattern() }
                Spacer()
            }
        } header: {
            Text("This machine also skips")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ExclusionsCopy.extraPatternsFooter)
                Link(SetsCopy.excludeSyntaxLinkText, destination: SetsCopy.excludeSyntaxURL)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fileSection: some View {
        Section {
            LabeledContent("Settings file") {
                Text(pane.settingsFilePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Patterns applied") {
                Text(String(pane.settings.plan().patterns.count))
            }
            Button("Restore Built-in Defaults") { pane.restoreDefaults() }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(ExclusionsCopy.scopeFooter)
                if let saveFailure = pane.saveFailure {
                    Text(saveFailure)
                        .foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Bindings
    //
    // Built here rather than on the model, matching `ScheduleSection`: a
    // `Binding`'s closures are formed in the view's own isolation, and the
    // model stays a plain value plus mutation methods.

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { pane.settings.enabled },
            set: { pane.setEnabled($0) }
        )
    }

    private var excludeCachesBinding: Binding<Bool> {
        Binding(
            get: { pane.settings.excludeCaches },
            set: { pane.setExcludeCaches($0) }
        )
    }

    /// The checkbox and the field are two views of one optional: `nil` is
    /// "no cap", and turning the checkbox on seeds a valid default rather
    /// than an empty string that would fail to save.
    private var sizeCapEnabledBinding: Binding<Bool> {
        Binding(
            get: { pane.settings.excludeLargerThan != nil },
            set: { pane.setExcludeLargerThan($0 ? ExclusionsCopy.sizeCapDefault : nil) }
        )
    }

    private var sizeCapBinding: Binding<String> {
        Binding(
            get: { pane.settings.excludeLargerThan ?? "" },
            set: { pane.setExcludeLargerThan($0.isEmpty ? nil : $0) }
        )
    }

    private func groupBinding(_ group: GlobalExcludeGroup) -> Binding<Bool> {
        Binding(
            get: { pane.settings.isEnabled(group) },
            set: { pane.setGroup(group, enabled: $0) }
        )
    }

    private func extraPatternBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard pane.settings.extraPatterns.indices.contains(index) else { return "" }
                return pane.settings.extraPatterns[index]
            },
            set: { pane.setExtraPattern(at: index, to: $0) }
        )
    }
}

// MARK: - ExclusionsSettingsModel

/// Loads and persists `global-excludes.json` for the pane above.
///
/// Every edit saves immediately, the way the restic-path pane does: there is
/// no draft to lose and no compare-and-swap to honour, because the file is
/// host-local and has exactly one editor on a given machine. A save that
/// fails leaves the in-memory value as the user set it and says why, rather
/// than silently reverting a toggle.
@MainActor
final class ExclusionsSettingsModel: ObservableObject {
    @Published private(set) var settings = GlobalExcludeSettings.default
    /// Set when the file exists and this build cannot honour it. The pane
    /// stays read-write so the user can fix it, but the banner says backups
    /// refuse to run until it is fixed.
    @Published private(set) var loadFailure: String?
    @Published private(set) var saveFailure: String?

    private var store: GlobalExcludeStore?

    var settingsFilePath: String {
        store?.paths.globalExcludesFile.path ?? ""
    }

    func load(paths: AppPaths) {
        let store = GlobalExcludeStore(paths: paths)
        self.store = store
        do {
            settings = try store.load()
            loadFailure = nil
        } catch {
            loadFailure = "\(error)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        mutate { $0.enabled = enabled }
    }

    func setExcludeCaches(_ excludeCaches: Bool) {
        mutate { $0.excludeCaches = excludeCaches }
    }

    /// Held in memory while it is being typed — `500` is not a valid size
    /// until its `m` arrives — and written through the moment it is. The
    /// banner in the footer says why an in-between value has not saved.
    func setExcludeLargerThan(_ size: String?) {
        if let size, !GlobalExcludeSettings.isValidSize(size) {
            settings.excludeLargerThan = size
        } else {
            mutate { $0.excludeLargerThan = size }
        }
    }

    func setGroup(_ group: GlobalExcludeGroup, enabled: Bool) {
        mutate { settings in
            // Only decisions that differ from the built-in default are
            // recorded, so a group set back to its default drops out of the
            // file rather than pinning today's answer forever
            // (`docs/data-model.md` §global-excludes.json).
            if enabled == group.enabledByDefault {
                settings.groups.removeValue(forKey: group.id)
            } else {
                settings.groups[group.id] = enabled
            }
        }
    }

    func setExtraPattern(at index: Int, to pattern: String) {
        mutate { settings in
            guard settings.extraPatterns.indices.contains(index) else { return }
            settings.extraPatterns[index] = pattern
        }
    }

    func addExtraPattern() {
        // Not persisted yet: an empty pattern is refused by `validate()`, so
        // the blank row lives in memory until it has a value. Saving it
        // would turn "I clicked Add" into an error banner.
        settings.extraPatterns.append("")
    }

    func removeExtraPattern(at index: Int) {
        mutate { settings in
            guard settings.extraPatterns.indices.contains(index) else { return }
            settings.extraPatterns.remove(at: index)
        }
    }

    func restoreDefaults() {
        guard let store else { return }
        let file = store.paths.globalExcludesFile
        settings = .default
        guard FileManager.default.fileExists(atPath: file.path) else {
            saveFailure = nil
            loadFailure = nil
            return
        }
        do {
            try FileManager.default.removeItem(at: file)
            saveFailure = nil
            loadFailure = nil
        } catch {
            saveFailure = "Could not remove \(file.path): \(error)"
        }
    }

    private func mutate(_ change: (inout GlobalExcludeSettings) -> Void) {
        var updated = settings
        change(&updated)
        settings = updated
        guard let store else { return }
        // A blank row the user has not filled in yet is not an error to
        // report; it simply is not written until it has a value.
        var persistable = updated
        persistable.extraPatterns.removeAll { $0.isEmpty }
        do {
            try store.save(persistable)
            saveFailure = nil
            loadFailure = nil
        } catch {
            saveFailure = "Could not save \(store.paths.globalExcludesFile.path): \(error)"
        }
    }
}

// MARK: - Copy

/// Every user-visible string this pane pins from `docs/ui-spec.md`
/// §Settings, kept in one place for the same reason `SetsCopy` is.
enum ExclusionsCopy {
    static let enabledLabel = "Apply the global exclusion list"
    static let excludeCachesLabel = "Skip directories tagged CACHEDIR.TAG"
    static let sizeCapLabel = "Skip files larger than"
    static let sizeCapPlaceholder = "10G"
    static let sizeCapDefault = "10G"

    static let sizeCapFooter =
        "A size cap is off by default. Every other rule here names a folder of things that come "
        + "back on their own; a size cap can skip one irreplaceable file — a video, a disk image — "
        + "with nothing to point at afterwards."

    static let sizeCapInvalid =
        "Not saved: use a number followed by k, m, g or t — for example 500m or 10G."

    static let overviewFooter =
        "These patterns are skipped by every backup set unless the set turns off "
        + "“Apply global exclusions”. They only affect new snapshots — nothing already backed up "
        + "is removed."

    static let cacheDirTagFooter =
        "CACHEDIR.TAG is a marker some tools (Cargo, Go) write into their own cache directories to "
        + "say “do not back this up”."

    static let groupsFooter =
        "Turning a group off backs its paths up again from the next run. A newer version of Restic "
        + "Station can add a group, and it applies unless you turn it off here."

    static let extraPatternsEmptyState =
        "Only the built-in groups above are skipped on this machine."

    static let extraPatternsFooter =
        "Extra patterns for this machine only. Unlike the built-in list these may be absolute paths."

    static let scopeFooter =
        "This file is not shared between machines and is never included in an exported "
        + "configuration — a cache path belongs to a machine, not to a fleet."

    static let loadFailureFooter =
        "Backups refuse to run until this is fixed, rather than falling back to the built-in "
        + "defaults: the defaults may skip more than you had configured, which would quietly stop "
        + "backing up directories you had kept."

    /// Counted for **this** platform: the catalogue is scoped, so a macOS
    /// host never applies the Linux spellings and vice versa
    /// (`docs/data-model.md` §Platform scoping). Showing the total would
    /// promise exclusions this machine will not make.
    static func patternCount(_ count: Int) -> String {
        count == 1 ? "1 pattern" : "\(count) patterns"
    }
}
