import ResticStationCore
import SwiftUI

/// The Backup Sets section (`docs/ui-spec.md` §Backup Sets). `MainWindow`
/// routes to this name, which is why the file still lives here after T14
/// replaced its placeholder body.
///
/// Structure: the section's detail pane is a `NavigationStack` whose root is
/// the set list and whose one destination is the set editor. A push (rather
/// than a third split-view column) is what gives the editor the full width it
/// needs — sources, excludes, schedule *and* the destination table are all on
/// one form.
struct BackupSetsRootView: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection: UUID?
    @State private var editorTarget: SetEditorTarget?
    /// A set created by the toolbar's "+" but not yet saved: it is not in
    /// `config` until the editor's Save succeeds (a set needs a source and a
    /// primary destination before `AppConfig.validate()` will accept it).
    @State private var pendingNewSet: BackupSet?

    var body: some View {
        NavigationStack {
            SetListView(
                selection: $selection,
                onCreate: createSet,
                onEdit: { setId in editorTarget = SetEditorTarget(id: setId, isNew: false) }
            )
            .navigationDestination(item: $editorTarget) { target in
                editor(for: target)
            }
        }
        .onAppear {
            model.start()
            model.refresh()
        }
    }

    @ViewBuilder
    private func editor(for target: SetEditorTarget) -> some View {
        if target.isNew, let pendingNewSet, pendingNewSet.id == target.id {
            SetEditorView(initialSet: pendingNewSet, isNew: true)
        } else if let set = model.config.sets.first(where: { $0.id == target.id }) {
            SetEditorView(initialSet: set, isNew: false)
        } else {
            ContentUnavailableView(
                "This backup set was deleted",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("Go back to the list to pick another one.")
            )
        }
    }

    private func createSet() {
        let draft = model.newSetTemplate()
        pendingNewSet = draft
        editorTarget = SetEditorTarget(id: draft.id, isNew: true)
    }
}

// MARK: - SetEditorTarget

/// What the editor is editing. A new set is identified by id like any other,
/// but its draft lives in `BackupSetsRootView.pendingNewSet` until it is
/// saved — `navigationDestination(item:)` needs a `Hashable` value, and
/// `BackupSet` deliberately is not one.
struct SetEditorTarget: Identifiable, Hashable, Sendable {
    let id: UUID
    let isNew: Bool
}
