import SwiftUI

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        @Bindable var settings = store.settings

        if !store.viewerMode && !store.compareMode {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { store.requestOpenFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
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

            if !store.viewerMode && !store.compareMode {
                Menu {
                    Picker("", selection: $settings.sortKey) {
                        Text("ファイル名 別").tag(SortKey.filename)
                        Text("作成日 別").tag(SortKey.createdDate)
                        Text("修正日 別").tag(SortKey.modifiedDate)
                        Text("サイズ 別").tag(SortKey.fileSize)
                        Text("レーティング 別").tag(SortKey.rating)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(settings.sortKey.localizedName) で並べ替え")
                }
                .onChange(of: settings.sortKey) { store.applyOrder() }

                Button(action: { settings.sortAscending.toggle() }) {
                    Image(systemName: settings.sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(settings.sortAscending ? "昇順" : "降順")
                .onChange(of: settings.sortAscending) { store.applyOrder() }

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
}
