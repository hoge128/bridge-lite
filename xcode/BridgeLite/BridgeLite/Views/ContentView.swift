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
            .task {
                await BridgeCore.pruneCache(
                    dbPath: LibraryStore.cacheDBURL(),
                    maxAgeDays: store.settings.cacheTTLDays
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .bridgeLiteOpenURL)) { notif in
                guard let url = notif.object as? URL,
                      nsWindow?.isKeyWindow == true else { return }
                store.loadFolder(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bridgeLiteRegroup)) { _ in
                Task { await store.regroup() }
            }
            .onChange(of: store.settings.folderWatchEnabled) { _, _ in
                store.applyFolderWatchSetting()
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
    @State private var spaceKeyMonitor: Any?

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
                .toolbar(store.viewerMode ? .hidden : .visible, for: .windowToolbar)
                .navigationTitle(store.currentDirectoryURL?.lastPathComponent ?? "BridgeLite")
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    if store.viewerMode || store.compareMode { return .ignored }
                    store.cyclePairVariant(reverse: press.modifiers.contains(.shift))
                    return .handled
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
        .onAppear {
            guard spaceKeyMonitor == nil else { return }
            let s = store
            spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Space → viewer mode
                if event.keyCode == 49,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                   !s.viewerMode, !s.compareMode,
                   s.primaryID != nil {
                    s.viewerMode = true
                    return nil
                }
                // 0-9 rating / label keys (works in all modes: grid, viewer, compare)
                if !(NSApp.keyWindow?.firstResponder is NSTextView),
                   let ch = event.charactersIgnoringModifiers?.first,
                   ch >= "0" && ch <= "9" {
                    let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
                    let required = s.settings.ratingShortcutModifier.nsEventModifierFlags
                    if mods == required {
                        let labelMap: [Character: UInt8] = ["6": 1, "7": 2, "8": 3, "9": 4]
                        if let n = Int(String(ch)), n <= 5 {
                            s.triggerRating(n)
                        } else if let raw = labelMap[ch] {
                            s.applyLabel(raw)
                        }
                        return nil
                    }
                }
                // Arrow keys — text view がフォーカスを持っている場合はスルー
                guard !(NSApp.keyWindow?.firstResponder is NSTextView),
                      !s.viewerMode, !s.compareMode else { return event }
                // 矢印キーには .numericPad / .function が常に付く。関心のある modifier のみ抽出する
                let mods = event.modifierFlags.intersection([.shift, .command, .control, .option])
                let shift = mods.contains(.shift)
                let cmd   = mods.contains(.command)
                guard mods.subtracting([.shift, .command]).isEmpty else { return event }
                switch event.keyCode {
                case 123: // ←
                    guard !cmd else { return event }
                    shift ? s.rangeNavigatePrev() : s.navigatePrev()
                    return nil
                case 124: // →
                    guard !cmd else { return event }
                    shift ? s.rangeNavigateNext() : s.navigateNext()
                    return nil
                case 126: // ↑
                    if shift && cmd { s.rangeNavigateFirst() }
                    else if shift   { s.rangeNavigateUp() }
                    else if cmd     { s.navigateFirst() }
                    else            { s.navigateUp() }
                    return nil
                case 125: // ↓
                    if shift && cmd { s.rangeNavigateLast() }
                    else if shift   { s.rangeNavigateDown() }
                    else if cmd     { s.navigateLast() }
                    else            { s.navigateDown() }
                    return nil
                default: return event
                }
            }
        }
        .onDisappear {
            if let m = spaceKeyMonitor { NSEvent.removeMonitor(m); spaceKeyMonitor = nil }
        }
    }
}

// MARK: - StatusBarView

private struct StatusBarView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        HStack(spacing: 8) {
            if store.isLoading {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)

                if store.scanPhase == .loading && store.orderedIDs.count > 0 {
                    ProgressView(
                        value: Double(store.loadedThumbnailCount),
                        total: Double(store.orderedIDs.count)
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .controlSize(.mini)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                        .controlSize(.mini)
                }

                Button { store.cancelLoading() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Cancel scanning"))
            } else {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

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
