import SwiftUI

/// The Runs section (`docs/ui-spec.md` §Runs). `MainWindow` routes to this
/// name; the screen itself is a history list that drills into one run.
///
/// A `NavigationStack` rather than a second split view: this is already the
/// detail column of the shell's `NavigationSplitView`, and the log viewer
/// wants all of its width. Pushing gives the standard back button and leaves
/// the history list at its natural column widths.
struct RunsRootView: View {
    /// Pushed `runId`s — a plain `[String]`, because a run is identified by
    /// nothing else.
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            RunListView()
                .navigationDestination(for: String.self) { runId in
                    RunDetailView(runId: runId)
                }
        }
    }
}
