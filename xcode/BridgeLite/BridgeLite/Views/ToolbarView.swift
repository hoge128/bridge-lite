import SwiftUI

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        @Bindable var settings = store.settings

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
            Picker("Layout", selection: $settings.gridMode) {
                Image(systemName: "square.grid.3x3").tag(GridMode.strict)
                Image(systemName: "rectangle.grid.3x2").tag(GridMode.dense)
            }
            .pickerStyle(.segmented)
            .help("Grid layout")
            Toggle(isOn: $store.showFilters) {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            Toggle(isOn: $store.showSidebar) {
                Label("Metadata", systemImage: "sidebar.right")
            }
        }
    }
}
