import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ContentView (one per native tab/window)

struct ContentView: View {
    @State private var store = LibraryStore()
    @State private var nsWindow: NSWindow?

    var body: some View {
        FolderView()
            .environment(store)
            .focusedValue(\.libraryStore, store)
            .background(WindowAccessor(window: $nsWindow))
            .onReceive(NotificationCenter.default.publisher(for: .bridgeLiteOpenURL)) { notif in
                guard let url = notif.object as? URL,
                      nsWindow?.isKeyWindow == true else { return }
                Task { await store.openDirectory(url) }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
                guard (notif.object as? NSWindow) === nsWindow else { return }
                store.resume()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notif in
                guard (notif.object as? NSWindow) === nsWindow else { return }
                store.suspend()
            }
    }
}

// MARK: - FolderView

struct FolderView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ZStack {
            // Main layout: NavigationSplitView (filter | thumbnails) + metadata panel + status bar
            VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: $store.columnVisibility) {
                    FilterPanelView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
                } detail: {
                    ThumbnailGridView()
                }
                .toolbar {
                    ToolbarView()
                }
                .navigationTitle({
                    let base = store.currentDirectoryURL?.lastPathComponent ?? "BridgeLite"
                    guard !store.statusMessage.isEmpty else { return base }
                    return "\(base) (\(store.statusMessage))"
                }())
                .onDrop(of: [.folder, .fileURL], isTargeted: nil) { providers in
                    Task { @MainActor in
                        for provider in providers {
                            let url: URL? = await withCheckedContinuation { cont in
                                _ = provider.loadObject(ofClass: URL.self) { item, _ in
                                    cont.resume(returning: item)
                                }
                            }
                            if let url {
                                let target = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
                                await store.openDirectory(target)
                                break
                            }
                        }
                    }
                    return true
                }
                .onKeyPress(.leftArrow) {
                    if store.viewerMode || store.compareMode { return .ignored }
                    store.navigatePrev(); return .handled
                }
                .onKeyPress(.rightArrow) {
                    if store.viewerMode || store.compareMode { return .ignored }
                    store.navigateNext(); return .handled
                }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    if store.viewerMode || store.compareMode { return .ignored }
                    store.cyclePairVariant(reverse: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.space) {
                    if store.viewerMode || store.compareMode { return .ignored }
                    if store.primaryID != nil { store.viewerMode = true }
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "012345"), phases: .down) { press in
                    if store.viewerMode { return .ignored }
                    if let n = Int(press.characters) { store.triggerRating(n); return .handled }
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
                .background {
                    Group {
                        Button("") { store.selectAll() }
                            .keyboardShortcut("a", modifiers: .command)
                        Button("") { store.deselectAll() }
                            .keyboardShortcut("a", modifiers: [.command, .option])
                        Button("") { store.triggerCopy() }
                            .keyboardShortcut("c", modifiers: .command)
                        Button("") { store.performUndo() }
                            .keyboardShortcut("z", modifiers: .command)
                        Button("") { if !store.viewerMode { store.triggerDelete() } }
                            .keyboardShortcut(.delete, modifiers: [])
                        Button("") { if !store.viewerMode { store.triggerDelete() } }
                            .keyboardShortcut("d", modifiers: .control)
                        Button("") {
                            if !store.viewerMode && !store.compareMode, let pid = store.primaryID {
                                store.compareAnchorID = pid
                                store.compareMode = true
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [])
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                }

                // Metadata panel — outside NavigationSplitView to avoid empty column artifact
                if store.showSidebar {
                    Divider()
                    SidebarView()
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: store.showSidebar)

            StatusBarView()
            } // VStack

            if store.compareMode, let anchorID = store.compareAnchorID {
                GroupCompareView(initialID: anchorID)
                    .environment(store)
            }

            if store.viewerMode {
                ViewerView()
                    .environment(store)
            }
        }
    }
}

// MARK: - StatusBarView

private struct StatusBarView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        HStack(spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Slider(value: $settings.thumbnailSize, in: 60...360)
                .frame(width: 120)
                .controlSize(.small)
            Image(systemName: "photo")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        let total = store.visibleIDs.count
        let selected = store.selectedIDs.count
        if selected > 1 {
            return "\(total) items, \(selected) selected"
        } else if selected == 1 {
            return "\(total) items, 1 selected"
        }
        return "\(total) items"
    }
}

// MARK: - WindowAccessor

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        window = nsView.window
    }
}
