import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filters")
                    .font(.headline)
                    .padding(.horizontal)

                // Camera filter
                // TODO: Phase E で availableCameras をリスト表示してトグル
                Text("Camera")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Divider()

                // Rating filter
                Text("Rating")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                // TODO: Phase E で星数チェックボックス実装

                Divider()

                // Reset
                Button("Reset") { store.filter.reset() }
                    .disabled(!store.filter.isActive)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .frame(minWidth: 180)
    }
}
