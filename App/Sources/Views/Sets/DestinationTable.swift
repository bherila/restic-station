import ResticStationCore
import SwiftUI

/// The destination table inside the set editor (`docs/ui-spec.md` §Backup
/// Sets): "label, repo, kind badge, PRIMARY tag, status dot reachable /
/// offline / stale + 'last synced N days ago'. Exactly-one-primary enforced
/// by radio-style selection; changing primary shows an explanatory
/// confirmation".
///
/// Two rules this view exists to enforce:
///
/// 1. **Exactly one primary, always.** The primary is chosen with a
///    radio-style control that can only ever *move* the flag, never clear it
///    or set a second one — invariant 1 of `docs/data-model.md` cannot be
///    violated through this UI.
/// 2. **Removing a destination removes its secrets.** The confirmation says
///    so verbatim, so the removal persists the config first and deletes the
///    keychain items only after that save succeeded.
struct DestinationTable: View {
    @EnvironmentObject private var model: AppModel

    @Binding var set: BackupSet
    @Binding var configFingerprint: String
    @Binding var pendingSecretRollbacks: [AppModel.DestinationSecretsRollback]
    let errorMessage: String?

    @State private var sheet: DestinationSheetTarget?
    @State private var pendingPrimary: Destination?
    @State private var pendingRemoval: Destination?
    @State private var blockedRemoval: Destination?
    @State private var removalError: String?

    var body: some View {
        Section {
            if set.destinations.isEmpty {
                Text("No destinations yet. The first one you add becomes the primary — "
                    + "the repository backups are written to.")
                    .foregroundStyle(.secondary)
            }

            ForEach(set.destinations) { destination in
                row(destination)
            }

            addButtonRow

            if let removalError {
                InlineMessage(removalError)
            }
            if let errorMessage {
                InlineMessage(errorMessage)
            }
        } header: {
            Text("Destinations")
        } footer: {
            Text("The primary is where backups are written. Every other destination is a mirror, "
                + "copied from the primary after each backup.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// The sheet and the three confirmations hang off this row rather than
    /// off the enclosing `Section`: a `Section` is a container, and
    /// presentation modifiers want a view that is actually rendered.
    private var addButtonRow: some View {
        HStack {
            Button("Add Destination…") { addDestination() }
            Spacer()
        }
        .sheet(item: $sheet) { target in
            DestinationEditorView(
                set: $set,
                configFingerprint: $configFingerprint,
                pendingSecretRollbacks: $pendingSecretRollbacks,
                initialDestination: destination(for: target),
                isNew: target.isNew
            )
        }
        .alert(
            "Make “\(pendingPrimary?.label ?? "")” the primary?",
            isPresented: alertBinding($pendingPrimary),
            presenting: pendingPrimary
        ) { destination in
            Button("Make Primary") { makePrimary(destination) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SetsCopy.primaryChangeExplanation)
        }
        .alert(
            "Remove “\(pendingRemoval?.label ?? "")”?",
            isPresented: alertBinding($pendingRemoval),
            presenting: pendingRemoval
        ) { destination in
            Button("Remove", role: .destructive) { remove(destination) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SetsCopy.removeDestinationConfirmation)
        }
        .alert(
            "“\(blockedRemoval?.label ?? "")” is the primary destination",
            isPresented: alertBinding($blockedRemoval),
            presenting: blockedRemoval
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { _ in
            Text(SetsCopy.primaryRemovalBlocked)
        }
    }

    // MARK: - Row

    private func row(_ destination: Destination) -> some View {
        HStack(alignment: .top, spacing: 10) {
            primaryRadio(destination)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(destination.label)
                        .fontWeight(.medium)
                    KindBadge(kind: destination.kind)
                    if destination.isPrimary {
                        PrimaryTag()
                    }
                }

                Text(destination.repoURL)
                    .font(.callout)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(destination.repoURL)
                    .textSelection(.enabled)

                statusLine(destination)
            }

            Spacer(minLength: 8)

            Menu {
                Button("Edit…") { sheet = DestinationSheetTarget(id: destination.id, isNew: false) }
                if !destination.isPrimary {
                    Button("Make Primary…") { pendingPrimary = destination }
                }
                Divider()
                Button("Remove…", role: .destructive) { requestRemoval(destination) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 40)
            .help("Destination actions")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func primaryRadio(_ destination: Destination) -> some View {
        Button {
            guard !destination.isPrimary else { return }
            pendingPrimary = destination
        } label: {
            Image(systemName: destination.isPrimary ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(destination.isPrimary ? Color.accentColor : .secondary)
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .help(destination.isPrimary ? "This is the primary destination" : "Make this the primary destination")
        .accessibilityLabel("Primary destination")
        .accessibilityAddTraits(destination.isPrimary ? [.isSelected] : [])
    }

    private func statusLine(_ destination: Destination) -> some View {
        let status = model.destinationStatus(setId: set.id, destId: destination.id)
        let repoStatus = model.repoStatus(destId: destination.id)
        return HStack(spacing: 6) {
            StatusDot(status: status)
            Text(status.label)
            Text("·")
            Text(SetsCopy.lastSyncedText(repoStatus))
            if status == .notInitialized {
                Text("·")
                Text("never initialized")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(status == .error ? Color.red : .secondary)
    }

    // MARK: - Actions

    private func addDestination() {
        sheet = DestinationSheetTarget(id: UUID(), isNew: true)
    }

    /// The destination the sheet edits. For a new one this is a blank
    /// `Destination` carrying the id the sheet was opened with, so the
    /// keychain items it writes are keyed the same before and after the
    /// destination lands in the config.
    private func destination(for target: DestinationSheetTarget) -> Destination {
        if let existing = set.destinations.first(where: { $0.id == target.id }) {
            return existing
        }
        return Destination(
            id: target.id,
            label: "",
            repoURL: "",
            // The first destination of a set is necessarily the primary —
            // that is how invariant 1 stays satisfiable.
            isPrimary: set.destinations.isEmpty,
            nonSecretEnv: [:]
        )
    }

    /// Moves the primary flag. Radio-style: exactly one destination ends up
    /// primary, whatever the previous state was.
    private func makePrimary(_ destination: Destination) {
        pendingPrimary = nil
        for index in set.destinations.indices {
            set.destinations[index].isPrimary = (set.destinations[index].id == destination.id)
        }
    }

    private func requestRemoval(_ destination: Destination) {
        removalError = nil
        // "Deleting the primary destination is blocked with explanation while
        // secondaries exist" (T14 acceptance criteria).
        if destination.isPrimary && set.destinations.count > 1 {
            blockedRemoval = destination
        } else {
            pendingRemoval = destination
        }
    }

    /// Removes the destination, then its keychain items — in that order, and
    /// only if the config write succeeded, so a rejected save can never leave
    /// a configured destination without its password. When the set itself has
    /// never been saved there is nothing to persist and the draft edit is
    /// enough.
    private func remove(_ destination: Destination) {
        pendingRemoval = nil
        removalError = nil

        var updated = set
        updated.destinations.removeAll { $0.id == destination.id }

        // Removing the *only* destination leaves a set that
        // `AppConfig.validate()` rejects (invariant 1), so that one is kept
        // in the draft: the editor's Save then explains that the set needs a
        // primary destination, instead of a confusing failure right here.
        let isPersisted = model.config.sets.contains { $0.id == set.id }
        let staysValid = updated.destinations.contains(where: \.isPrimary)
        var persistedWholeDraft = false
        if isPersisted && staysValid {
            do {
                configFingerprint = try model.saveSet(
                    updated,
                    ifUnchangedFrom: configFingerprint
                )
                persistedWholeDraft = true
            } catch {
                removalError = SetsCopy.fieldMessage(for: error).message
                return
            }
        }
        set = updated
        if persistedWholeDraft {
            // saveSet wrote every destination in the parent draft, not just
            // the removal, so every retained secret edit is committed too.
            pendingSecretRollbacks.removeAll()
        } else {
            // The removed destination no longer participates in a future
            // config save. Its deletion is the intended secret outcome, so
            // an editor rollback must not recreate those items later.
            pendingSecretRollbacks.removeAll { $0.destId == destination.id }
        }

        Task { await model.deleteDestinationSecrets(destId: destination.id) }
    }

    /// `alert(_:isPresented:presenting:)` wants a `Bool` binding; every alert
    /// here is driven by an optional payload instead.
    private func alertBinding(_ value: Binding<Destination?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { value.wrappedValue = nil }
            }
        )
    }
}

// MARK: - DestinationSheetTarget

/// Identifies which destination the editor sheet is editing. New
/// destinations get their UUID here, before they exist in the set, because
/// the UUID is also the keychain account name (`docs/data-model.md`
/// §Keychain items) and must not change once secrets are written.
struct DestinationSheetTarget: Identifiable, Hashable, Sendable {
    let id: UUID
    let isNew: Bool
}
