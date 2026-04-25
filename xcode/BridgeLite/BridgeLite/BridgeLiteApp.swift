import SwiftUI

@main
struct BridgeLiteApp: App {
    @State private var libraryStore = LibraryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(libraryStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            BridgeLiteCommands(store: libraryStore)
        }

        Settings {
            SettingsView()
                .environment(libraryStore.settings)
        }
    }
}

struct BridgeLiteCommands: Commands {
    let store: LibraryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                store.requestOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("View") {
            Toggle("Filters", isOn: Binding(
                get: { store.showFilters },
                set: { store.showFilters = $0 }
            ))
            .keyboardShortcut("f", modifiers: [.command, .option])
            Toggle("Metadata", isOn: Binding(
                get: { store.showSidebar },
                set: { store.showSidebar = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Button("Enter Fullscreen Viewer") {
                store.viewerMode = true
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(store.selectedID == nil)
        }
        CommandMenu("Rate") {
            Button("Clear Rating") { store.applyRating(0) }.keyboardShortcut("0", modifiers: [])
            ForEach(1...5, id: \.self) { n in
                Button("\(n) Star\(n == 1 ? "" : "s")") { store.applyRating(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            Divider()
            Button("Pick")   { store.togglePick()   }.keyboardShortcut("p", modifiers: [])
            Button("Reject") { store.toggleReject() }.keyboardShortcut("x", modifiers: [])
            Divider()
            Button("Label Red")    { store.applyLabel(1) }.keyboardShortcut("6", modifiers: [])
            Button("Label Yellow") { store.applyLabel(2) }.keyboardShortcut("7", modifiers: [])
            Button("Label Green")  { store.applyLabel(3) }.keyboardShortcut("8", modifiers: [])
            Button("Label Blue")   { store.applyLabel(4) }.keyboardShortcut("9", modifiers: [])
        }
    }
}
