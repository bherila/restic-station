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

    var body: some View {
        NavigationStack {
            SetListView(
                selection: $selection,
                onCreate: createSet,
                onEdit: { setId in
                    guard let set = model.config.sets.first(where: { $0.id == setId }) else {
                        return
                    }
                    editorTarget = SetEditorTarget(
                        initialSet: set,
                        isNew: false,
                        configFingerprint: model.configFingerprint
                    )
                }
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
        SetEditorView(
            initialSet: target.initialSet,
            isNew: target.isNew,
            configFingerprint: target.configFingerprint
        )
    }

    private func createSet() {
        let draft = model.newSetTemplate()
        editorTarget = SetEditorTarget(
            initialSet: draft,
            isNew: true,
            configFingerprint: model.configFingerprint
        )
    }
}

// MARK: - SetEditorTarget

/// Captures the draft and its revision in one main-actor turn. The manual
/// Hashable conformance intentionally keys navigation identity on the scalar
/// revision metadata; BackupSet itself remains a value model without an
/// artificial Hashable requirement.
struct SetEditorTarget: Identifiable, Hashable, Sendable {
    let initialSet: BackupSet
    let isNew: Bool
    let configFingerprint: String

    var id: UUID { initialSet.id }

    static func == (lhs: SetEditorTarget, rhs: SetEditorTarget) -> Bool {
        lhs.id == rhs.id
            && lhs.isNew == rhs.isNew
            && lhs.configFingerprint == rhs.configFingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isNew)
        hasher.combine(configFingerprint)
    }
}
