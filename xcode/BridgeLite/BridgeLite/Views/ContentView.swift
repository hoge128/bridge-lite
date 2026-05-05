import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ContentView (one per native tab/window)

struct ContentView: View {
    @State private var store = LibraryStore()
    @State private var nsWindow: NSWindow?
    @State private var showingManageApplicationsSheet = false

    private func consumePendingOpenURL() {
        guard let win = nsWindow,
              let pending = (NSApp.delegate as? AppDelegate)?.pendingOpenURL else { return }
        let front = NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) }
        guard win === front else { return }
        (NSApp.delegate as? AppDelegate)?.pendingOpenURL = nil
        // onChange(of: nsWindow) が遅れて発火するため、ここで store.window を確実に設定。
        // でないと OpenFolderRegistry への登録が漏れる。
        store.window = win
        store.loadFolder(pending)
    }

    private func applyWindowTitle(_ window: NSWindow?) {
        guard let window else { return }
        window.title = store.currentDirectoryURL?.lastPathComponent ?? "BridgeLite"
    }

    var body: some View {
        FolderView()
            .environment(store)
            .focusedSceneValue(\.libraryStore, store)
            .background(WindowAccessor(window: $nsWindow))
            .task {
                await BridgeCore.pruneCache(
                    dbPath: LibraryStore.cacheDBURL(),
                    maxAgeDays: store.settings.cacheTTLDays
                )
            }
            .onAppear {
                // application(_:open:) が onAppear より先に走ったケースを拾う。
                consumePendingOpenURL()
            }
            .onReceive(NotificationCenter.default.publisher(for: .bridgeLiteOpenURL)) { notif in
                guard let url = notif.object as? URL, let win = nsWindow else { return }
                let front = NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) }
                guard win === front else { return }
                (NSApp.delegate as? AppDelegate)?.pendingOpenURL = nil
                // onChange(of: nsWindow) が遅れて発火するため、ここで store.window を確実に設定。
                store.window = win
                store.loadFolder(url)
            }
            .onChange(of: nsWindow) { _, newWindow in
                // OpenFolderRegistry の照合に使うため store にウィンドウ参照を持たせる。
                store.window = newWindow
                // viewDidMoveToWindow 経由で nsWindow がセットされた直後に
                // pendingOpenURL が残っていれば回収する（fresh launch の補完経路）。
                consumePendingOpenURL()
                // SwiftUI が外部 URL 起動時に作る新規ウィンドウは
                // representedURL がデフォルトで効いて navigationTitle が上書きされる。
                // representedURL を nil にしてタイトルバーがフォルダ名のみになるようにする。
                newWindow?.representedURL = nil
                applyWindowTitle(newWindow)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notif in
                guard (notif.object as? NSWindow) === nsWindow else { return }
                if let url = store.currentDirectoryURL {
                    OpenFolderRegistry.shared.unregister(url: url)
                }
            }
            .onChange(of: store.currentDirectoryURL) { _, _ in
                applyWindowTitle(nsWindow)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bridgeLiteRegroup)) { _ in
                Task { await store.regroup() }
            }
            .onChange(of: store.settings.folderWatchEnabled) { _, _ in
                store.applyFolderWatchSetting()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // アプリ全体がアクティブになったときのみ resume。
                // ウィンドウ間切替では発火させない（ThumbnailDecodeCache はシングルトンで
                // 両ウィンドウの状態を巻き込んで wipe してしまうため）。
                store.resume()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                store.suspend()
            }
            .sheet(isPresented: $showingManageApplicationsSheet) {
                ManageApplicationsSheet()
                    .environment(SettingsStore.shared)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .bridgeLiteOpenManageApplications)) { _ in
                showingManageApplicationsSheet = true
            }
    }
}

// MARK: - FolderView

struct FolderView: View {
    @Environment(LibraryStore.self) private var store
    @State private var spaceKeyMonitor: Any?
    // class ベースの可変参照。@State<NSWindow?> をクロージャでキャプチャすると
    // 初期値 nil で固定されてしまうため、参照型のホルダー経由で動的に読む。
    @State private var windowRef = WindowRef()

    private func isTextFieldActive() -> Bool {
        let fr = NSApp.keyWindow?.firstResponder
        return fr is NSTextView || fr is NSTextField
    }

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
                .toolbar(store.viewerMode || store.compareMode ? .hidden : .visible, for: .windowToolbar)
                .navigationTitle(store.currentDirectoryURL?.lastPathComponent ?? "BridgeLite")
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    if store.viewerMode || store.compareMode { return .ignored }
                    store.cyclePairVariant(reverse: press.modifiers.contains(.shift))
                    return .handled
                }
                .background {
                    Group {
                        Button("") {
                            guard !isTextFieldActive() else { return }
                            store.selectAll()
                        }
                        .keyboardShortcut("a", modifiers: .command)
                        Button("") {
                            guard !isTextFieldActive() else { return }
                            store.deselectAll()
                        }
                        .keyboardShortcut("a", modifiers: [.command, .option])
                        Button("") { store.triggerCopy() }
                            .keyboardShortcut("c", modifiers: .command)
                        Button("") { store.performUndo() }
                            .keyboardShortcut("z", modifiers: .command)
                        Button("") {
                            guard !isTextFieldActive() else { return }
                            if !store.viewerMode { store.triggerDelete() }
                        }
                        .keyboardShortcut(.delete, modifiers: [])
                        Button("") {
                            guard !isTextFieldActive() else { return }
                            if !store.viewerMode { store.triggerDelete() }
                        }
                        .keyboardShortcut("d", modifiers: .control)
                        Button("") {
                            guard !isTextFieldActive() else { return }
                            if !store.viewerMode && !store.compareMode, let pid = store.primaryID {
                                store.compareAnchorID = pid
                                store.compareMode = true
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        Button("") {
                            NotificationCenter.default.post(name: .bridgeLiteFocusSearch, object: nil)
                        }
                        .keyboardShortcut("f", modifiers: .command)
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
        .background(WindowAccessor(window: Binding(
            get: { windowRef.window },
            set: { windowRef.window = $0 }
        )))
        .onAppear {
            guard spaceKeyMonitor == nil else { return }
            let s = store
            let ref = windowRef
            spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 複数ウィンドウ環境で全モニタが同じイベントを受け取って二重発火するのを防ぐ。
                // 自分のウィンドウ宛てでなければスルー。
                guard event.window === ref.window else { return event }
                // Space → viewer mode
                if event.keyCode == 49,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                   !s.viewerMode, !s.compareMode,
                   s.primaryID != nil {
                    s.viewerMode = true
                    return nil
                }
                // 0-9 rating / label keys (works in all modes: grid, viewer, compare)
                let fr0 = NSApp.keyWindow?.firstResponder
                if !(fr0 is NSTextView), !(fr0 is NSTextField),
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
                let fr1 = NSApp.keyWindow?.firstResponder
                guard !(fr1 is NSTextView), !(fr1 is NSTextField),
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

                if store.scanPhase == .loading && store.preScanImageFiles > 0 {
                    // total は preScan で発見した全画像数。orderedIDs.count を使うと
                    // フィルタ適用時に value > total になり ProgressView が警告を出す。
                    let total = store.preScanImageFiles
                    let value = min(store.loadedThumbnailCount, total)
                    ProgressView(value: Double(value), total: Double(total))
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

// MARK: - WindowRef

/// クロージャから NSWindow への動的参照を持つためのホルダー。
/// `@State<NSWindow?>` をクロージャでキャプチャすると初期 nil が固定される問題の回避用。
final class WindowRef {
    weak var window: NSWindow?
}

// MARK: - WindowAccessor

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeCoordinator() -> Coordinator { Coordinator(window: $window) }

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] newWindow in
            coordinator?.windowChanged(newWindow)
        }
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {}

    // class にすることで weak 参照・retain cycle 回避が可能になる。
    // updateNSView 内で binding を直接書き換えると SwiftUI の render cycle と
    // 衝突して onChange(of:) が発火しない。viewDidMoveToWindow + DispatchQueue.main.async
    // でレンダーパスの外から binding を更新することで確実に onChange を発火させる。
    final class Coordinator {
        var binding: Binding<NSWindow?>
        init(window: Binding<NSWindow?>) { binding = window }

        func windowChanged(_ newWindow: NSWindow?) {
            guard let newWindow else { return }
            // self をキャプチャせず value type の Binding を直接キャプチャすることで
            // Swift 6 のデータレース警告を回避する。
            let binding = self.binding
            DispatchQueue.main.async {
                binding.wrappedValue = newWindow
            }
        }
    }
}

final class WindowObserverView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
