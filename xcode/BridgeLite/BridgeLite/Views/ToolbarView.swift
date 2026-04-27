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
            } else if let msg = store.undoMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { store.performUndo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .help(store.performUndoTitle ?? "Undo (⌘Z)")

            Picker("Layout", selection: $settings.gridMode) {
                Image(systemName: "square.grid.3x3").tag(GridMode.strict)
                Image(systemName: "rectangle.grid.3x2").tag(GridMode.dense)
            }
            .pickerStyle(.segmented)
            .help("Grid layout")
            Toggle(isOn: $store.showSidebar) {
                Label("Metadata", systemImage: "sidebar.right")
            }
        }
    }
}
