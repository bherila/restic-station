import AppKit
import ResticStationCore
import SwiftUI

// MARK: - Sources

/// "**Sources**: list of absolute paths; add via `NSOpenPanel` (directories +
/// files, multi-select), remove; warn inline (yellow) on nested/duplicate
/// paths." (`docs/ui-spec.md` §Backup Sets)
struct SourcesSection: View {
    @Binding var sources: [String]
    let errorMessage: String?

    var body: some View {
        Section {
            if sources.isEmpty {
                Text("Nothing is being backed up yet.")
                    .foregroundStyle(.secondary)
            }

            ForEach(sources.indices, id: \.self) { index in
                row(at: index)
            }

            HStack {
                Button("Add…") { addSources() }
                Spacer()
            }

            if let errorMessage {
                InlineMessage(errorMessage)
            }
        } header: {
            Text("Sources")
        } footer: {
            Text("Folders and files are backed up exactly as listed — restic follows the paths, "
                + "not their enclosing volumes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func row(at index: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sources[index])
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sources[index])
                if let warning = Self.warning(for: index, in: sources) {
                    InlineMessage(warning, level: .warning)
                }
            }
            Spacer(minLength: 8)
            Button {
                sources.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this source")
        }
    }

    // MARK: Warnings

    /// Yellow inline warning for a duplicate or nested path. Duplicates are
    /// only flagged on the *later* entry so one message is shown per problem.
    static func warning(for index: Int, in sources: [String]) -> String? {
        let path = standardized(sources[index])
        for (otherIndex, other) in sources.enumerated() where otherIndex != index {
            let otherPath = standardized(other)
            if otherPath == path {
                return otherIndex < index ? "Already listed above — remove one of the two." : nil
            }
            if path.hasPrefix(otherPath + "/") {
                return "Inside “\(other)”, which is already a source — it is backed up either way."
            }
        }
        return nil
    }

    /// Trailing slashes and `.`/`..` components removed, so `/a/b/` and
    /// `/a/b` are recognized as the same source.
    private static func standardized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    // MARK: Add

    private func addSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false
        panel.message = "Choose the folders and files this backup set protects."
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !sources.contains(url.path) {
            sources.append(url.path)
        }
    }
}

// MARK: - Excludes

/// "**Excludes**: editable string list; caption linking restic
/// exclude-pattern syntax." (`docs/ui-spec.md` §Backup Sets)
struct ExcludesSection: View {
    @Binding var excludes: [String]

    var body: some View {
        Section {
            if excludes.isEmpty {
                Text("Everything under the sources is backed up.")
                    .foregroundStyle(.secondary)
            }

            ForEach(excludes.indices, id: \.self) { index in
                HStack {
                    TextField("Pattern", text: $excludes[index], prompt: Text("node_modules"))
                        .labelsHidden()
                    Button {
                        excludes.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this pattern")
                }
            }

            HStack {
                Button("Add Pattern") { excludes.append("") }
                Spacer()
            }
        } header: {
            Text("Excludes")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Each pattern is passed to restic as --exclude.")
                Link("restic exclude-pattern syntax", destination: SetsCopy.excludeSyntaxURL)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Schedule

/// "**Schedule**: picker for kind (Every N minutes / Hourly / Daily /
/// Weekly) with contextual fields (N stepper ≥5; minute; hour+minute;
/// weekday+hour+minute)." Ranges match `AppConfig.validate()`'s invariant 4
/// (`docs/data-model.md`), so the steppers cannot produce a config the
/// validator rejects.
struct ScheduleSection: View {
    @Binding var schedule: Schedule
    let errorMessage: String?

    enum Kind: String, CaseIterable, Identifiable {
        case everyMinutes
        case hourly
        case daily
        case weekly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyMinutes: return "Every N minutes"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            }
        }
    }

    var body: some View {
        Section {
            Picker("Runs", selection: kindBinding) {
                ForEach(Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }

            switch schedule {
            case .everyMinutes:
                Stepper(value: minutesBinding, in: 5...1440, step: 5) {
                    Text("Every \(minutesBinding.wrappedValue) minutes")
                }
            case .hourly:
                Stepper(value: minuteBinding, in: 0...59) {
                    Text(String(format: "At :%02d past the hour", minuteBinding.wrappedValue))
                }
            case .daily:
                timeOfDayFields
            case .weekly:
                Picker("On", selection: weekdayBinding) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(SetsCopy.weekdayName(weekday)).tag(weekday)
                    }
                }
                timeOfDayFields
            }

            if let errorMessage {
                InlineMessage(errorMessage)
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("The background agent decides when a set is actually due; a Mac that was asleep "
                + "at the scheduled time catches up on the next tick.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var timeOfDayFields: some View {
        HStack(spacing: 16) {
            Stepper(value: hourBinding, in: 0...23) {
                Text("Hour \(String(format: "%02d", hourBinding.wrappedValue))")
            }
            Stepper(value: minuteBinding, in: 0...59) {
                Text("Minute \(String(format: "%02d", minuteBinding.wrappedValue))")
            }
            Text("= \(SetsCopy.timeOfDay(hour: hourBinding.wrappedValue, minute: minuteBinding.wrappedValue))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: Bindings

    /// Switching kind keeps the time-of-day the user already picked where the
    /// new kind has somewhere to put it.
    private var kindBinding: Binding<Kind> {
        Binding(
            get: { currentKind },
            set: { newKind in
                let hour = currentHour
                let minute = currentMinute
                switch newKind {
                case .everyMinutes: schedule = .everyMinutes(30)
                case .hourly: schedule = .hourly(minute: minute)
                case .daily: schedule = .daily(hour: hour, minute: minute)
                case .weekly: schedule = .weekly(weekday: currentWeekday, hour: hour, minute: minute)
                }
            }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: {
                if case .everyMinutes(let minutes) = schedule { return minutes }
                return 30
            },
            set: { schedule = .everyMinutes($0) }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { currentMinute },
            set: { minute in
                switch schedule {
                case .everyMinutes: break
                case .hourly: schedule = .hourly(minute: minute)
                case .daily(let hour, _): schedule = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, let hour, _):
                    schedule = .weekly(weekday: weekday, hour: hour, minute: minute)
                }
            }
        )
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { currentHour },
            set: { hour in
                switch schedule {
                case .everyMinutes, .hourly: break
                case .daily(_, let minute): schedule = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, _, let minute):
                    schedule = .weekly(weekday: weekday, hour: hour, minute: minute)
                }
            }
        )
    }

    private var weekdayBinding: Binding<Int> {
        Binding(
            get: { currentWeekday },
            set: { weekday in
                schedule = .weekly(weekday: weekday, hour: currentHour, minute: currentMinute)
            }
        )
    }

    private var currentKind: Kind {
        switch schedule {
        case .everyMinutes: return .everyMinutes
        case .hourly: return .hourly
        case .daily: return .daily
        case .weekly: return .weekly
        }
    }

    private var currentHour: Int {
        switch schedule {
        case .everyMinutes, .hourly: return 2
        case .daily(let hour, _): return hour
        case .weekly(_, let hour, _): return hour
        }
    }

    private var currentMinute: Int {
        switch schedule {
        case .everyMinutes: return 30
        case .hourly(let minute): return minute
        case .daily(_, let minute): return minute
        case .weekly(_, _, let minute): return minute
        }
    }

    private var currentWeekday: Int {
        if case .weekly(let weekday, _, _) = schedule { return weekday }
        return 1
    }
}

// MARK: - Retention

/// "**Retention** (optional section, off = never forget) … default
/// suggestion when enabling: 7 daily / 4 weekly / 12 monthly / 2 yearly."
/// (`docs/ui-spec.md` §Backup Sets)
struct RetentionEditorSection: View {
    @Binding var retention: RetentionPolicy?

    /// The suggestion the spec pins, applied the moment the section is
    /// switched on.
    static let suggestion = RetentionPolicy(
        keepLast: nil,
        keepHourly: nil,
        keepDaily: 7,
        keepWeekly: 4,
        keepMonthly: 12,
        keepYearly: 2
    )

    var body: some View {
        Section {
            Toggle("Forget old snapshots automatically", isOn: enabledBinding)

            if retention != nil {
                keepRow("Keep last", keyPath: \.keepLast, suggested: 10)
                keepRow("Keep hourly", keyPath: \.keepHourly, suggested: 24)
                keepRow("Keep daily", keyPath: \.keepDaily, suggested: 7)
                keepRow("Keep weekly", keyPath: \.keepWeekly, suggested: 4)
                keepRow("Keep monthly", keyPath: \.keepMonthly, suggested: 12)
                keepRow("Keep yearly", keyPath: \.keepYearly, suggested: 2)

                if retention?.isEmpty == true {
                    InlineMessage(
                        "No rules are set, so nothing would be forgotten. Turn on at least one rule "
                            + "or switch retention off.",
                        level: .warning
                    )
                }
            }
        } header: {
            Text("Retention")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(SetsCopy.retentionFootnote)
                if retention == nil {
                    Text("Off: snapshots are kept forever.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { retention != nil },
            set: { isOn in retention = isOn ? Self.suggestion : nil }
        )
    }

    private func keepRow(
        _ title: String,
        keyPath: WritableKeyPath<RetentionPolicy, Int?>,
        suggested: Int
    ) -> some View {
        let isOn = Binding<Bool>(
            get: { retention?[keyPath: keyPath] != nil },
            set: { on in
                guard var policy = retention else { return }
                policy[keyPath: keyPath] = on ? suggested : nil
                retention = policy
            }
        )
        let value = Binding<Int>(
            get: { retention?[keyPath: keyPath] ?? suggested },
            set: { newValue in
                guard var policy = retention else { return }
                policy[keyPath: keyPath] = newValue
                retention = policy
            }
        )
        return HStack {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .frame(width: 150, alignment: .leading)
            Stepper(value: value, in: 1...9999) {
                Text(isOn.wrappedValue ? "\(value.wrappedValue)" : "—")
                    .monospacedDigit()
                    .foregroundStyle(isOn.wrappedValue ? Color.primary : .secondary)
            }
            .disabled(!isOn.wrappedValue)
            Spacer()
        }
    }
}

// MARK: - Integrity checks

/// "**Integrity checks** (optional): toggle + slice count (default 20)."
/// `readDataSubsetSlices` is bounded to 2...100 — invariant 5 in
/// `docs/data-model.md`.
struct CheckPolicySection: View {
    @Binding var checkPolicy: CheckPolicy?
    let errorMessage: String?

    var body: some View {
        Section {
            Toggle("Verify the repository weekly", isOn: enabledBinding)

            if checkPolicy != nil {
                Stepper(value: slicesBinding, in: 2...100) {
                    Text("Read one slice in \(slicesBinding.wrappedValue) each week")
                }
            }

            if let errorMessage {
                InlineMessage(errorMessage)
            }
        } header: {
            Text("Integrity checks")
        } footer: {
            Text(SetsCopy.checkFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { checkPolicy?.enabled == true },
            set: { isOn in
                checkPolicy = isOn
                    ? CheckPolicy(enabled: true, readDataSubsetSlices: checkPolicy?.readDataSubsetSlices ?? 20)
                    : nil
            }
        )
    }

    private var slicesBinding: Binding<Int> {
        Binding(
            get: { checkPolicy?.readDataSubsetSlices ?? 20 },
            set: { slices in
                checkPolicy = CheckPolicy(enabled: true, readDataSubsetSlices: slices)
            }
        )
    }
}
