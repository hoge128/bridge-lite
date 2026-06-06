import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Delegate (Dock icon drop / Finder open)

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder / Dock-drop で渡された URL を一時保持する。
    /// nsWindow が nil のうちに通知が届いた場合、onChange(of: nsWindow) で消費する。
    var pendingOpenURL: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "BridgeLiteMain" }) {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let target: URL
        if let folder = urls.first(where: { $0.hasDirectoryPath }) {
            target = folder
        } else if let file = urls.first {
            target = file.deletingLastPathComponent()
        } else { return }
        // 既存のメインウィンドウを前面に出す。
        // onReceive の win === front 判定と、onChange の防波堤で既存ウィンドウを正しく
        // 選ばせるための前処理。
        if let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "BridgeLiteMain" }) {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        }
        pendingOpenURL = target
        // 次の runloop サイクルで notification を発火させることで、
        // SwiftUI が WindowAccessor 経由で nsWindow をセットし終えるのを待つ。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .bridgeLiteOpenURL, object: target)
        }
    }
}

extension NSNotification.Name {
    static let bridgeLiteOpenURL = NSNotification.Name("BridgeLiteOpenURL")
    static let bridgeLiteRegroup = NSNotification.Name("BridgeLiteRegroup")
    static let bridgeLiteFocusSearch = NSNotification.Name("BridgeLiteFocusSearch")
    static let bridgeLiteCacheCleared = NSNotification.Name("BridgeLiteCacheCleared")
    static let bridgeLiteShowShortcuts = NSNotification.Name("BridgeLiteShowShortcuts")
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

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastVersion = UserDefaults.standard.string(forKey: "lastLaunchVersion") ?? ""
        if lastVersion != currentVersion {
            let dbURL = LibraryStore.cacheDBURL()
            try? FileManager.default.removeItem(at: dbURL)
            UserDefaults.standard.set(currentVersion, forKey: "lastLaunchVersion")
        }
    }()

    init() {
        _ = Self._bootstrap
        #if !APPSTORE
        // Start Sparkle on launch (Direct/DMG build only; App Store handles updates).
        _ = UpdaterController.shared
        #endif
    }

    var body: some Scene {
        Window("BridgeLite", id: "main") {
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
        #if !APPSTORE
        // Mac App Store builds update via the App Store; no manual check menu.
        CommandGroup(after: .appInfo) {
            Button(String(localized: "menu.check_for_updates",
                          defaultValue: "Check for Updates…")) {
                UpdaterController.shared.checkForUpdates()
            }
        }
        #endif
        CommandGroup(replacing: .undoRedo) {
            Button(store?.undoActionTitle ?? String(localized: "Undo")) {
                let fr = NSApp.keyWindow?.firstResponder
                if fr is NSTextView || fr is NSTextField {
                    NSApp.sendAction(Selector("undo:"), to: nil, from: nil)
                } else {
                    store?.undoManager.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(store?.canUndo ?? false))

        }
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") {
                store?.requestOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(store == nil)

            let recents = RecentFoldersStore.shared.recentURLs
            Menu(String(localized: "menu.open_recent", defaultValue: "Open Recent")) {
                if recents.isEmpty {
                    Text(String(localized: "menu.open_recent.empty", defaultValue: "No Recent Folders"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recents, id: \.path) { url in
                        Button((url.path as NSString).abbreviatingWithTildeInPath) {
                            store?.loadFolder(url)
                        }
                    }
                    Divider()
                    Button(String(localized: "menu.open_recent.clear", defaultValue: "Clear Recent Folders")) {
                        RecentFoldersStore.shared.clear()
                    }
                }
            }
            .disabled(store == nil)

            Button("Rescan") {
                store?.triggerRescan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store?.currentDirectoryURL == nil)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit BridgeLite") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        CommandMenu("View") {
            Button(String(localized: "shortcut.sheet.title", defaultValue: "Keyboard Shortcuts")) {
                NotificationCenter.default.post(name: .bridgeLiteShowShortcuts, object: nil)
            }
            .keyboardShortcut("/", modifiers: .command)
            Divider()
            Toggle("Metadata", isOn: Binding(
                get: { store?.showSidebar ?? false },
                set: { store?.showSidebar = $0 }
            ))
            .keyboardShortcut("i", modifiers: [.command, .option])
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
            let mods = store?.settings.ratingShortcutModifier.swiftUIModifiers ?? []
            Button("Clear Rating") { store?.triggerRating(0) }
                .keyboardShortcut("0", modifiers: mods)
                .disabled(store == nil)
            ForEach(1...5, id: \.self) { n in
                Button("\(n) Star\(n == 1 ? "" : "s")") { store?.triggerRating(n) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: mods)
                    .disabled(store == nil)
            }
            Divider()
            Button("Label Red")    { store?.applyLabel(1) }
                .keyboardShortcut("6", modifiers: mods)
                .disabled(store == nil)
            Button("Label Yellow") { store?.applyLabel(2) }
                .keyboardShortcut("7", modifiers: mods)
                .disabled(store == nil)
            Button("Label Green")  { store?.applyLabel(3) }
                .keyboardShortcut("8", modifiers: mods)
                .disabled(store == nil)
            Button("Label Blue")   { store?.applyLabel(4) }
                .keyboardShortcut("9", modifiers: mods)
                .disabled(store == nil)
        }
        CommandGroup(replacing: .help) {
            Button("BridgeLite Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}
