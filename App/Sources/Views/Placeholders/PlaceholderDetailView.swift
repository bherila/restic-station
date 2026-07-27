import SwiftUI

/// Shared body for the not-yet-implemented detail panes (T14–T17). Lives in
/// `Views/Placeholders/`; the whole directory disappears as those tasks land.
struct PlaceholderDetailView<Extra: View>: View {
    let title: String
    let symbolName: String
    let message: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label(title, systemImage: symbolName)
            } description: {
                Text(message)
            }
            extra
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Restic Station")
        .navigationSubtitle(title)
    }
}

extension PlaceholderDetailView where Extra == EmptyView {
    init(title: String, symbolName: String, message: String) {
        self.init(title: title, symbolName: symbolName, message: message) { EmptyView() }
    }
}
