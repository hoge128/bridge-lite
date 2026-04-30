import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Delegate (Dock icon drop / Finder open)

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

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

// MARK: - Window state monitor

final class WindowStateMonitor: ObservableObject {
    @Published var isFullScreen = false

    init() {
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isFullScreen = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isFullScreen = false
        }
    }
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
    @StateObject private var windowState = WindowStateMonitor()

    private static let _bootstrap: Void = {
        let lang = UserDefaults.standard.string(forKey: "language") ?? "en"
        if lang == "ja" || lang == "en" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
    }()

    init() { _ = Self._bootstrap }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .focusedSceneObject(windowState)
        }
        .commands {
            BridgeLiteCommands()
        }

        Window("About BridgeLite", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(SettingsStore.shared)
        }
    }
}

struct BridgeLiteCommands: Commands {
    @FocusedValue(\.libraryStore) private var store: LibraryStore?
    @FocusedObject private var windowState: WindowStateMonitor?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About BridgeLite") {
                openWindow(id: "about")
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                store?.requestOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(store == nil)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit BridgeLite") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
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
            .disabled(store?.selectedID == nil)
            Divider()
            Button(windowState?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("Rate") {
            Button("Clear Rating") { store?.applyRating(0) }.keyboardShortcut("0", modifiers: [])
            ForEach(1...5, id: \.self) { n in
                Button("\(n) Star\(n == 1 ? "" : "s")") { store?.applyRating(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            Divider()
            Button("Label Red")    { store?.applyLabel(1) }.keyboardShortcut("6", modifiers: [])
            Button("Label Yellow") { store?.applyLabel(2) }.keyboardShortcut("7", modifiers: [])
            Button("Label Green")  { store?.applyLabel(3) }.keyboardShortcut("8", modifiers: [])
            Button("Label Blue")   { store?.applyLabel(4) }.keyboardShortcut("9", modifiers: [])
        }
        CommandGroup(replacing: .help) {
            Button("BridgeLite Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}
