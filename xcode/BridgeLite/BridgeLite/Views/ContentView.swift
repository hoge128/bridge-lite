import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        if store.viewerMode {
            ViewerView()
                .environment(store)
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                if store.showFilters {
                    FilterPanelView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                }
            } content: {
                ThumbnailGridView()
            } detail: {
                if store.showSidebar {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
                }
            }
            .toolbar {
                ToolbarView()
            }
            .navigationTitle(store.currentDirectoryURL?.lastPathComponent ?? "BridgeLite")
        }
    }
}
