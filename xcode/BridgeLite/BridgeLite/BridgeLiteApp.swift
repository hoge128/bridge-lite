import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Delegate (Dock icon drop / Finder open)

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let target: URL
        if let folder = urls.first(where: { $0.hasDirectoryPath }) {
            target = folder
        } else if let file = urls.first {
            target = file.deletingLastPathComponent()
        } else { return }
        NotificationCenter.default.post(name: .bridgeLiteOpenURL, object: target)
    }
}

extension NSNotification.Name {
    static let bridgeLiteOpenURL = NSNotification.Name("BridgeLiteOpenURL")
}

// MARK: - FocusedValue key

private struct LibraryStoreFocusedKey: FocusedValueKey {
    typealias Value = LibraryStore
}

extension FocusedValues {
    var libraryStore: LibraryStore? {
        get { self[LibraryStoreFocusedKey.self] }
        set { self[LibraryStoreFocusedKey.self] = newValue }
    }
}

// MARK: - App

@main
struct BridgeLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            BridgeLiteCommands()
        }

        Settings {
            SettingsView()
                .environment(SettingsStore.shared)
        }
    }
}

struct BridgeLiteCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.libraryStore) private var store: LibraryStore?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                store?.requestOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(store == nil)
            Button("New Tab") {
                NSApp.sendAction(Selector("newWindowForTab:"), to: nil, from: nil)
            }
            .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit BridgeLite") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("View") {
            Toggle("Metadata", isOn: Binding(
                get: { store?.showSidebar ?? false },
                set: { store?.showSidebar = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(store == nil)
            Divider()
            Button("Enter Fullscreen Viewer") {
                store?.viewerMode = true
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(store?.selectedID == nil)
        }
        CommandMenu("Rate") {
            Button("Clear Rating") { store?.applyRating(0) }.keyboardShortcut("0", modifiers: [])
            ForEach(1...5, id: \.self) { n in
                Button("\(n) Star\(n == 1 ? "" : "s")") { store?.applyRating(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            Divider()
            Button("Pick")   { store?.togglePick()   }.keyboardShortcut("p", modifiers: [])
            Button("Reject") { store?.toggleReject() }.keyboardShortcut("x", modifiers: [])
            Divider()
            Button("Label Red")    { store?.applyLabel(1) }.keyboardShortcut("6", modifiers: [])
            Button("Label Yellow") { store?.applyLabel(2) }.keyboardShortcut("7", modifiers: [])
            Button("Label Green")  { store?.applyLabel(3) }.keyboardShortcut("8", modifiers: [])
            Button("Label Blue")   { store?.applyLabel(4) }.keyboardShortcut("9", modifiers: [])
        }
    }
}
