import SwiftUI

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store

        ToolbarItemGroup(placement: .navigation) {
            Button(action: { store.requestOpenFolder() }) {
                Label("Open Folder", systemImage: "folder")
            }
        }

        ToolbarItemGroup(placement: .principal) {
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $store.showFilters) {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            Toggle(isOn: $store.showSidebar) {
                Label("Metadata", systemImage: "sidebar.right")
            }
        }
    }
}
