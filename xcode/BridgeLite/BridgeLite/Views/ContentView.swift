import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store

        ZStack {
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
            // Key handlers live here so they fire regardless of which column has focus.
            // Guard against viewerMode to avoid double-firing with ViewerView's keyboardShortcuts.
            .onKeyPress(.leftArrow)  {
                if store.viewerMode { return .ignored }
                store.navigatePrev(); return .handled
            }
            .onKeyPress(.rightArrow) {
                if store.viewerMode { return .ignored }
                store.navigateNext(); return .handled
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                if store.viewerMode { return .ignored }
                store.cyclePairVariant(reverse: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.space) {
                if store.viewerMode { return .ignored }
                if store.selectedID != nil { store.viewerMode = true }
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "012345"), phases: .down) { press in
                if store.viewerMode { return .ignored }
                if let n = Int(press.characters) { store.applyRating(n); return .handled }
                return .ignored
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "6789"), phases: .down) { press in
                if store.viewerMode { return .ignored }
                let labelMap: [Character: UInt8] = ["6": 1, "7": 2, "8": 3, "9": 4]
                if let ch = press.characters.first, let raw = labelMap[ch] {
                    store.applyLabel(raw); return .handled
                }
                return .ignored
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "pPxX"), phases: .down) { press in
                if store.viewerMode { return .ignored }
                switch press.characters.lowercased() {
                case "p": store.togglePick();   return .handled
                case "x": store.toggleReject(); return .handled
                default:  return .ignored
                }
            }

            if store.viewerMode {
                ViewerView()
                    .environment(store)
            }
        }
    }
}
