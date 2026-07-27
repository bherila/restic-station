import ResticStationCore
import SwiftUI

/// Integrity (`docs/ui-spec.md` §Maintenance): the last check result and date
/// per destination, the slice cursor progress ("verified slices 7/20"), and
/// **Check now**.
///
/// The results come from the run history — `runs/index.jsonl` entries with
/// `kind == .check` — not from a separate state file: a check *is* a run, so
/// the run record is the single source of truth about what it found, and the
/// Runs screen shows the same outcome with its full log.
struct IntegritySection: View {
    @EnvironmentObject private var model: AppModel
    let backupSet: BackupSet
    @ObservedObject var maintenance: MaintenanceModel

    private var totalSlices: Int {
        backupSet.checkPolicy?.readDataSubsetSlices ?? 20
    }

    /// `checkSliceCursor` records the **most recently used** `n` (1-based;
    /// absent = never checked), so it doubles as "how many slices of the
    /// current sweep are verified" (`docs/data-model.md`
    /// §schedule-state.json).
    private var verifiedSlices: Int {
        MaintenanceLookup.checkSliceCursor(model, setId: backupSet.id) ?? 0
    }

    private var nextSlice: Int {
        ScheduleMath.nextCheckSlice(cursor: verifiedSlices, totalSlices: totalSlices).n
    }

    private var isChecking: Bool {
        maintenance.isBusy(.check(setId: backupSet.id))
    }

    var body: some View {
        MaintenanceSection(
            "Integrity",
            systemImage: "checkmark.seal",
            caption: "A check re-reads the repository's structure and metadata. Each check also reads and "
                + "verifies one slice of the actual data, rotating through every slice so the whole "
                + "repository is verified over \(totalSlices) checks.",
            accessory: {
                Button {
                    maintenance.checkNow(for: backupSet, in: model)
                } label: {
                    if isChecking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check now", systemImage: "stethoscope")
                    }
                }
                .disabled(isChecking || model.isBusy(setId: backupSet.id))
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    sliceProgress
                    checkDepth
                    Divider()
                    ForEach(backupSet.destinations) { destination in
                        LastCheckRow(
                            destination: destination,
                            entry: MaintenanceLookup.lastCheck(model, setId: backupSet.id, destId: destination.id)
                        )
                    }
                    if backupSet.checkPolicy?.enabled != true {
                        Text("Scheduled weekly checks are turned off for this backup set. "
                            + "Turn them on in the set editor, or use Check now whenever you want one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        )
    }

    // MARK: - Slice cursor

    private var sliceProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The spec's wording, verbatim.
                Text("verified slices \(verifiedSlices)/\(totalSlices)")
                    .font(.body)
                    .monospacedDigit()
                ProgressView(value: Double(verifiedSlices), total: Double(totalSlices))
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Verified slices")
            }
            Text(verifiedSlices >= totalSlices
                ? "Every data slice of the primary has been read and verified at least once. "
                    + "The next check starts the sweep again at slice 1."
                : "The next check verifies slice \(nextSlice) of \(totalSlices) of the primary's data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Depth

    /// `docs/ui-spec.md` §Maintenance asks for a "structure-only toggle vs
    /// with-data-slice" here.
    ///
    /// The control is shown, and shown fixed, because the helper has exactly
    /// one manual-check entry point today — `run-set --kind check`, which
    /// always verifies the primary's next data slice as well
    /// (`BackupEngine.runCheck`). Rendering an enabled picker whose
    /// structure-only position silently ran a data-slice check anyway would
    /// be worse than saying so; wiring it through is a helper change
    /// (`--structure-only` on `run-set`) outside this screen's scope.
    private var checkDepth: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Check now runs", selection: $maintenance.checkReadsDataSlice) {
                Text("Structure and metadata only").tag(false)
                Text("Structure, metadata and the next data slice").tag(true)
            }
            .pickerStyle(.radioGroup)
            .disabled(true)
            Text("Mirrors get the structure-only check automatically, every fourth check. "
                + "A manual check of the primary always reads a data slice too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - LastCheckRow

/// "Last check result + date per destination". A destination with no check
/// run yet says so plainly rather than showing an empty badge.
struct LastCheckRow: View {
    let destination: Destination
    let entry: RunIndexEntry?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            DestinationTitle(destination: destination)
                .frame(minWidth: 160, alignment: .leading)
            if let entry {
                Image(systemName: entry.status.symbolName)
                    .foregroundStyle(entry.status.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: entry))
                    if let errorSummary = entry.errorSummary, !errorSummary.isEmpty {
                        Text(errorSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Never checked")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// A successful `check` means literally "no errors were found"
    /// (`docs/restic-cli.md` §check), which is worth saying in those words.
    private func label(for entry: RunIndexEntry) -> String {
        let when = MaintenanceFormat.absoluteAndRelative(entry.end ?? entry.start)
        switch entry.status {
        case .success:
            return "No errors found — \(when)"
        default:
            return "\(entry.status.label) — \(when)"
        }
    }
}
