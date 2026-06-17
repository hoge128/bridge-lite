import SwiftUI

// MARK: - Liquid Glass style view mode picker
// [BETA DISABLED] デイリーモードはスキャン中のフリーズが未解決のため非表示。
// 再有効化する場合は ToolbarView.principal ブロックに ViewModePicker を戻す。

private struct ViewModePicker: View {
    @Binding var selection: ViewMode

    var body: some View {
        HStack(spacing: 2) {
            pill(String(localized: "All Photos"), mode: .all)
            pill(String(localized: "Daily"), mode: .daily)
        }
        .padding(3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.10)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
        .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
    }

    private func pill(_ label: String, mode: ViewMode) -> some View {
        let isSelected = selection == mode
        return Text(label)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.70), .white.opacity(0.20)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
            }
    }
}

// MARK: - Native search field (NSSearchField wrapper)

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 最近の検索履歴ドロップダウンを無効化（矢印アイコンが消える）
        field.searchMenuTemplate = nil
        field.maximumRecents = 0
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusSearch),
            name: .bridgeLiteFocusSearch,
            object: nil
        )
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField

        init(_ parent: NativeSearchField) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        // cancelButton（✕）クリック時
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            parent.text = ""
        }

        @objc func focusSearch(_ notification: Notification) {
            guard let window = NSApp.keyWindow else { return }
            if let sf = window.contentView?.findFirstSearchField() {
                window.makeFirstResponder(sf)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return true
            }
            return false
        }
    }
}

// NSView ツリーから最初の NSSearchField を探すユーティリティ
private extension NSView {
    func findFirstSearchField() -> NSSearchField? {
        if let sf = self as? NSSearchField { return sf }
        for sub in subviews {
            if let found = sub.findFirstSearchField() { return found }
        }
        return nil
    }
}

// MARK: - Search field container

private struct SearchFieldContainer: View {
    @Environment(LibraryStore.self) private var store
    @State private var localText: String = ""

    var body: some View {
        NativeSearchField(
            text: $localText,
            placeholder: String(localized: "Search filename or caption")
        )
        .frame(minWidth: 160, maxWidth: 260)
        .onChange(of: localText) { _, new in store.setNameSearch(new) }
        .onChange(of: store.filter.nameSearch) { _, new in
            if new != localText { localText = new }
        }
    }
}

// MARK: -

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        @Bindable var settings = store.settings

        ToolbarItemGroup(placement: .navigation) {
            if !store.viewerMode && !store.compareMode {
                Button(action: { store.requestOpenFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
            }
            Button(action: { store.undoManager.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .help(store.undoActionTitle ?? String(localized: "Undo (⌘Z)"))
        }

        ToolbarItemGroup(placement: .principal) {
            if let msg = store.undoMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            } else if !store.viewerMode && !store.compareMode {
                Picker("", selection: Binding(
                    get: { store.filmstripMode },
                    set: { store.filmstripMode = $0 }
                )) {
                    Text(String(localized: "Library")).tag(false)
                    Text(String(localized: "Filmstrip")).tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(store.currentDirectoryURL == nil)
                .help(String(localized: "filmstrip.toggle.help",
                             defaultValue: "Switch between the library grid and filmstrip comparison"))
            }
        }

        // グループ1: 検索 — ライブラリのみ（フィルムストリップ/ビューア/比較では非表示）
        if !store.viewerMode && !store.compareMode && !store.filmstripMode {
            ToolbarItemGroup(placement: .primaryAction) {
                SearchFieldContainer()
            }
        }

        // グループ2: 並び替え + 昇順降順
        if !store.viewerMode && !store.compareMode {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("", selection: $settings.sortKey) {
                        Text(SortKey.filename.localizedName).tag(SortKey.filename)
                        Text(SortKey.exifDate.localizedName).tag(SortKey.exifDate)
                        Text(SortKey.createdDate.localizedName).tag(SortKey.createdDate)
                        Text(SortKey.modifiedDate.localizedName).tag(SortKey.modifiedDate)
                        Text(SortKey.fileSize.localizedName).tag(SortKey.fileSize)
                        Text(SortKey.rating.localizedName).tag(SortKey.rating)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(String(localized: "Sort by \(settings.sortKey.localizedName)"))
                }
                .onChange(of: settings.sortKey) { store.applyOrder() }

                Button(action: { settings.sortAscending.toggle() }) {
                    Image(systemName: settings.sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(settings.sortAscending
                      ? String(localized: "Ascending")
                      : String(localized: "Descending"))
                .onChange(of: settings.sortAscending) { store.applyOrder() }
            }
        }

        // グループ3: メタデータ + キーボードショートカット
        if !store.viewerMode && !store.compareMode {
            ToolbarItemGroup(placement: .primaryAction) {
                // デコード処理量を「エンジン回転数」に見立てたタコメーター（設定で ON/OFF・既定 OFF）
                if store.settings.showDecodeTachometer {
                    DecodeTachometerView()
                }
                // メタデータ — ライブラリは showSidebar、フィルムストリップは専用フラグ（デフォルト OFF）
                Toggle(isOn: store.filmstripMode
                       ? Binding(get: { store.filmstripShowMeta },
                                 set: { store.filmstripShowMeta = $0 })
                       : $store.showSidebar) {
                    Label("Metadata", systemImage: "sidebar.right")
                }

                Button {
                    NotificationCenter.default.post(name: .bridgeLiteShowShortcuts, object: nil)
                } label: {
                    Label(String(localized: "shortcut.sheet.title", defaultValue: "Keyboard Shortcuts"),
                          systemImage: "keyboard")
                }
                .help(String(localized: "shortcut.sheet.title", defaultValue: "Keyboard Shortcuts"))
            }
        }
    }
}

// MARK: - Decode Tachometer
//
// サムネイルの実デコード処理量（枚/秒）を自動車のタコメーターに見立てて表示する。
// アイドル時は低速、メモリ解放後に再デコードが走ると針が吹け上がる。
// 警告灯: 発熱(thermalState) / 省電力(LowPowerMode) で点灯（スループットが OS に
// 抑制されているサイン）。針＝アプリ自身のデコードスループット（OS 優先度の生値は
// 公開 API が無いため、最も意味のある“どれだけ働けているか”を可視化）。
struct DecodeTachometerView: View {
    /// レッドゾーン（フルスケール）の 枚/秒。実機の体感に合わせて調整可。
    private let redline: Double = 48
    private let sampleInterval: Double = 0.3

    @State private var lastTotal = 0
    @State private var seeded = false
    @State private var rate: Double = 0   // 平滑化済み 枚/秒

    private let tick = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    private var fraction: Double { min(1, max(0, rate / redline)) }
    // 針の回転角。-135°(=0%) 〜 +135°(=100%)。rotationEffect で高 fps 補間する。
    private var needleAngle: Double { -135 + fraction * 270 }

    private enum Warn { case none, thermal, lowPower }
    private var warn: Warn {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .thermal
        default: return .none
        }
    }

    var body: some View {
        TachoDial(angle: needleAngle, zone: zoneColor)
            .frame(width: 22, height: 22)
            .overlay(alignment: .topTrailing) {
                switch warn {
                case .thermal:
                    Image(systemName: "thermometer.high")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.red)
                        .offset(x: 2, y: -2)
                case .lowPower:
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.yellow)
                        .offset(x: 2, y: -2)
                case .none:
                    EmptyView()
                }
            }
            .onReceive(tick) { _ in sample() }
            .help(helpText)
            .accessibilityLabel(Text(String(localized: "tacho.label",
                                            defaultValue: "Thumbnail decode activity")))
    }

    private var zoneColor: Color {
        switch fraction {
        case ..<0.5: return .green
        case ..<0.8: return .orange
        default:     return .red
        }
    }

    // 静的文言（毎ティックの ICU 生成を避ける）。
    private let helpText = String(localized: "tacho.help",
        defaultValue: "Thumbnail decode tachometer. Revs up while thumbnails are (re)decoded — e.g. after memory was reclaimed during idle.")

    private func sample() {
        let total = ThumbnailDecodeCache.shared.totalDecodes
        if !seeded { lastTotal = total; seeded = true; return }
        let delta = max(0, total - lastTotal)
        lastTotal = total
        let instant = Double(delta) / sampleInterval
        // 立ち上がりは速く、減衰はやや緩やかに（針が暴れすぎないよう EMA）
        let a = instant >= rate ? 0.6 : 0.3
        // withAnimation で囲うと needleAngle の変化を rotationEffect が
        // 表示リフレッシュレート（60/120fps）で補間し、サンプル間も滑らかに動く。
        withAnimation(.easeOut(duration: sampleInterval + 0.05)) {
            rate = rate * (1 - a) + instant * a
            if rate < 0.05 { rate = 0 }
        }
    }
}

/// タコメーターの文字盤（目盛り＋ハブは静的、針は rotationEffect で高 fps 補間）。
/// 270° スイープ・下に開口。針角は -135°(0%)〜+135°(100%)。
private struct TachoDial: View {
    let angle: Double   // 針の回転角(度)
    let zone: Color

    var body: some View {
        ZStack {
            // 目盛り＋ハブ（静的）
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 1.5
                func pt(_ deg: Double, _ rad: Double) -> CGPoint {
                    let a = deg * .pi / 180
                    return CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
                }
                for i in 0...4 {
                    let f = Double(i) / 4
                    let col: Color = f < 0.5 ? .green : (f < 0.8 ? .orange : .red)
                    var t = Path()
                    t.move(to: pt(135 + f * 270, r * 0.74))
                    t.addLine(to: pt(135 + f * 270, r))
                    ctx.stroke(t, with: .color(col.opacity(0.55)), lineWidth: 1.4)
                }
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)),
                         with: .color(zone))
            }
            // 針（中心から上向きに描き、rotationEffect で中心まわりに回す＝アニメ補間で滑らか）
            GeometryReader { g in
                let s = min(g.size.width, g.size.height)
                Path { p in
                    p.move(to: CGPoint(x: g.size.width / 2, y: g.size.height / 2))
                    p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height / 2 - s * 0.42))
                }
                .stroke(zone, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            .rotationEffect(.degrees(angle), anchor: .center)
        }
    }
}
