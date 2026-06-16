import SwiftUI
import AppKit

// MARK: - FilmstripView
//
// 任意の写真2〜4枚を並べて比較する独立ビュー。
// レイアウトは上下分割：
//   上 = 選択中（先頭4枚）の大プレビュー（GroupCompareView の CompareMemberColumn を再利用）
//   下 = 写真を選ぶサムネイルグリッド（ThumbnailGridView をそのまま埋め込み）
//   右 = （任意）メタデータバー（store.filmstripShowMeta、デフォルト OFF）
//
// 比較対象は既存の複数選択 (store.selectedIDs) を流用する。GroupCompareView と異なり
// 同一ショットグループに限定しない（visibleIDs 全体から任意に選べる）。
// プレビュー背景は比較ビュー（黒）とは別に、フィルムストリップ専用で白にする。

struct FilmstripView: View {
    @Environment(LibraryStore.self) private var store

    /// プレビューに一度に表示する最大枚数（全枚数を領域内にフィットさせる）。
    private var maxCompare: Int { LibraryStore.filmstripMaxCompare }
    /// ダウンサンプル目標（高品質・メモリ安全）。
    private let previewMaxPixels = 2048

    // ピッカー（下グリッド）の高さ。仕切りドラッグで可変。値が小さいほどプレビューが拡大する。
    @State private var pickerHeight: CGFloat = 280
    @State private var dragStartPicker: CGFloat? = nil
    // ドラッグ中に push 済みのリサイズカーソル方向（帯から外れても追従＆限界で方向を切替）。
    @State private var pushedDir: ResizeDir? = nil
    // 仕切りの上にポインタがあるか（ドラッグ終了時にカーソルを正しく戻すために保持）。
    @State private var dividerHovering = false
    private let pickerMinHeight: CGFloat = 140   // ここまで縮めるとプレビュー最大（＝上限）
    private let pickerMaxHeight: CGFloat = 600

    /// プレビューに並べる比較対象（store と共有：表示順の先頭 maxCompare 件）。
    private var compareIDs: [UInt64] { store.filmstripCompareIDs }

    private var selectedCount: Int { store.selectedIDs.count }

    /// フィルムストリップ表示中か（welcome＝フォルダ未読込時は false でライブラリ表示）。
    private var inFilmstrip: Bool { store.filmstripMode && store.currentDirectoryURL != nil }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // 案A: ThumbnailGridView は無条件・同一位置に保ち、モード切替で破棄/再生成しない。
                // フィルムストリップ時のみ、その「上に」プレビュー領域を差し込む。
                if inFilmstrip {
                    // ビュワー = ヘッダー＋プレビューを 1 枚のカードとして浮かせる。
                    // 案2: アクティブ側が手前に浮く（境界＝下辺へ向けた柔らかい影＋前面 z 順）。
                    VStack(spacing: 0) {
                        viewerHeader
                        previewArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .elevation(active: store.filmstripPreviewActive, towardBottom: true)
                    .zIndex(store.filmstripPreviewActive ? 1 : 0)

                    // ビュワーとピッカーの境界＝リサイズ分割線。
                    resizeDivider

                    // ピッカーのヘッダー。グリッドは identity 維持のため外側 VStack 最下段に保つので、
                    // ピッカー側の「浮き」は境界に接するこのヘッダー（上辺へ向けた影）で表現する。
                    pickerHeader
                        .elevation(active: !store.filmstripPreviewActive, towardBottom: false)
                        .zIndex(!store.filmstripPreviewActive ? 1 : 0)
                }

                ThumbnailGridView()
                    .frame(maxWidth: .infinity)
                    // フィルムストリップ時は pickerHeight 固定、ライブラリ時はフル高さ。
                    // 同一の .frame に条件値を渡すことで View の identity を保つ（再生成しない）。
                    .frame(minHeight: inFilmstrip ? pickerHeight : nil,
                           maxHeight: inFilmstrip ? pickerHeight : .infinity)
                    .zIndex(inFilmstrip && !store.filmstripPreviewActive ? 1 : 0)
            }

            // 右: メタデータバー。フィルムストリップは専用フラグ、ライブラリは showSidebar。
            if inFilmstrip ? store.filmstripShowMeta : store.showSidebar {
                Divider()
                SidebarView()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                    .background(Color(.windowBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.filmstripPreviewActive)
        .animation(.easeInOut(duration: 0.2), value: store.showSidebar)
        .animation(.easeInOut(duration: 0.2), value: store.filmstripShowMeta)
        .animation(.easeInOut(duration: 0.2), value: inFilmstrip)
        .background(Color(.windowBackgroundColor))
        .background {
            // Esc でライブラリへ戻る（フィルムストリップ時のみ）
            if inFilmstrip {
                Button("") { store.filmstripMode = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Pane headers（ビュワー / ピッカーの見出し＝奥行きの対象を明示）
    //
    // 先頭の ◯ がフォーカス状態を表す（アクティブ＝青塗り / 非アクティブ＝灰）。
    // ヘッダーをクリックするとその面にフォーカスを移せる。

    /// フォーカス状態を示す ◯。
    private func paneDot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(width: 10, height: 10)
            .animation(.easeInOut(duration: 0.15), value: active)
    }

    /// ビュワー（プレビュー）のヘッダー。比較中の枚数を表示。
    private var viewerHeader: some View {
        let active = store.filmstripPreviewActive
        return HStack(spacing: 10) {
            paneDot(active: active)
            Text(String(localized: "filmstrip.pane.viewer", defaultValue: "Viewer"))
                .font(.callout.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)

            if selectedCount > maxCompare {
                Label(
                    String(localized: "filmstrip.hint.max",
                           defaultValue: "Up to \(maxCompare) photos can be compared"),
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Spacer()

            if selectedCount > 0 {
                Text("\(min(selectedCount, maxCompare)) / \(maxCompare)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { store.filmstripPreviewActive = true }
        // 上辺：標準ツールバーと同じ .bar 材質が地続きに見えるのを防ぐ区切り線。
        // 下辺：プレビュー（白背景）との境界。
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    /// ピッカー（グリッド）のヘッダー。現在フィルタ済み＝表示中サムネイルの総数を表示。
    private var pickerHeader: some View {
        let active = !store.filmstripPreviewActive
        return HStack(spacing: 10) {
            paneDot(active: active)
            Text(String(localized: "filmstrip.pane.picker", defaultValue: "Picker"))
                .font(.callout.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)

            Spacer()

            Text(String(localized: "filmstrip.picker.count",
                        defaultValue: "\(store.visibleIDs.count) photos"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { store.filmstripPreviewActive = false }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Preview area（フィルムストリップ専用の白背景）

    @ViewBuilder
    private var previewArea: some View {
        let ids = compareIDs
        ZStack {
            // 写真は常に純白背景で正確に提示する（フォーカス信号は奥行き＋ディバイダーのバーに集約）。
            Color.white

            if ids.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "filmstrip.empty",
                                defaultValue: "Select photos to compare"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 全枚数を領域内にフィット（スクロールなし・行列でぴったり割り付け）。
                GeometryReader { geo in
                    let n = ids.count
                    let (rows, cols) = optimalGrid(memberCount: n, viewportSize: geo.size)
                    let spacing: CGFloat = 8
                    let cellW = max(40, (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols))
                    let cellH = max(40, (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows))

                    VStack(spacing: spacing) {
                        ForEach(Array(0..<rows), id: \.self) { r in
                            HStack(spacing: spacing) {
                                ForEach(Array(0..<cols), id: \.self) { c in
                                    let idx = r * cols + c
                                    if idx < n {
                                        let id = ids[idx]
                                        CompareMemberColumn(
                                            memberID: id,
                                            isFocused: store.filmstripFocusID == id,             // プレビューのフォーカス
                                            lightBackground: true,                               // 白背景向けの暗色文字
                                            compact: true,                                       // 大レーティング行は隠す
                                            downsampleMaxPixels: previewMaxPixels,               // 高品質ダウンサンプル
                                            isSelected: store.filmstripPreviewSelectedIDs.contains(id)
                                        )
                                        .frame(width: cellW, height: cellH)
                                        // グリッド同等の選択: クリック / Shift範囲 / ⌘トグル（ピッカーとは独立）
                                        .onTapGesture {
                                            let m = NSEvent.modifierFlags
                                            if m.contains(.shift) { store.previewRangeSelect(to: id) }
                                            else if m.contains(.command) { store.previewToggle(id) }
                                            else { store.previewSelect(id) }
                                        }
                                    } else {
                                        Color.clear.frame(width: cellW, height: cellH)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(spacing)
                    // 上下矢印ナビ用に現在の列数を store へ反映
                    .onAppear { store.filmstripPreviewCols = cols }
                    .onChange(of: cols) { _, newCols in store.filmstripPreviewCols = newCols }
                }
            }
        }
        // 白背景に合わせて常にライト配色（アプリがダークでも文字が黒で見えるように）
        .environment(\.colorScheme, .light)
    }

    // MARK: - Resizable divider（プレビュー領域を上限まで拡大縮小）

    private var resizeDivider: some View {
        // ピッカー／ビュワーのどちらにも属さない独立した帯。背景を敷かず（窓背景が透ける）
        // 上下に余白を確保し、横バー（カプセル）ハンドルだけを中央に浮かせて完全に分離する。
        // 可動方向の限界はマウスカーソル（▲▼ / ▲ / ▼）で表現する。
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
        .gesture(
            // 座標空間は .global。仕切り自身が動いても translation が歪まず、移動量が 1:1 になる。
            DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    if dragStartPicker == nil { dragStartPicker = pickerHeight }
                    let base = dragStartPicker ?? pickerHeight
                    // 下へドラッグ（translation.height > 0）でピッカー縮小＝プレビュー拡大
                    let newHeight = min(max(base - v.translation.height, pickerMinHeight), pickerMaxHeight)
                    pickerHeight = newHeight
                    // 限界をまたいだら push 済みカーソルを差し替え（▲▼ ⇄ ▲ ⇄ ▼）。
                    // push したカーソルは pop するまで持続するので、帯から外れても追従する。
                    let d = resizeDir(for: newHeight)
                    if pushedDir != d {
                        if pushedDir != nil { NSCursor.pop() }
                        Self.cursor(for: d).push()
                        pushedDir = d
                    }
                }
                .onEnded { _ in
                    dragStartPicker = nil
                    if pushedDir != nil { NSCursor.pop(); pushedDir = nil }
                    // pop 直後はまだ帯の上でも hover の再 enter が来ないので、明示的に戻す。
                    if dividerHovering { Self.cursor(for: resizeDir).set() } else { NSCursor.arrow.set() }
                }
        )
        .onHover { hovering in
            dividerHovering = hovering
            // ドラッグ中（push 済み）は hover の set で上書きしない。
            guard pushedDir == nil else { return }
            if hovering { Self.cursor(for: resizeDir).set() } else { NSCursor.arrow.set() }
        }
    }

    // MARK: - リサイズカーソル（標準 NSCursor。可動方向に応じて resizeUpDown / resizeUp / resizeDown を出し分け）

    /// 仕切りの可動方向。両方可＝both、下限（プレビュー最大）＝up のみ可、上限（グリッド最大）＝down のみ可。
    enum ResizeDir { case both, up, down }

    private var resizeDir: ResizeDir { resizeDir(for: pickerHeight) }

    private func resizeDir(for height: CGFloat) -> ResizeDir {
        let atMin = height <= pickerMinHeight + 0.5   // これ以上プレビューを広げられない＝上へのみ可
        let atMax = height >= pickerMaxHeight - 0.5   // これ以上グリッドを広げられない＝下へのみ可
        if atMin && !atMax { return .up }
        if atMax && !atMin { return .down }
        return .both
    }

    private static func cursor(for dir: ResizeDir) -> NSCursor {
        switch dir {
        case .both: return .resizeUpDown   // 上下どちらにもリサイズ可
        case .up:   return .resizeUp       // 上方向（グリッド拡大）にのみ可
        case .down: return .resizeDown     // 下方向（プレビュー拡大）にのみ可
        }
    }

    // GroupCompareView と同等の最適グリッド算出（1〜4 枚を viewport に応じて配置）。
    private func optimalGrid(memberCount n: Int, viewportSize size: CGSize) -> (rows: Int, cols: Int) {
        guard n > 0 else { return (1, 1) }
        let viewportAspect = max(0.1, size.width / max(size.height, 1))
        let imageAspect: CGFloat = 1.5
        let rawCols = (Double(n) * Double(viewportAspect) / Double(imageAspect)).squareRoot()
        let cols = min(max(Int(rawCols.rounded()), 1), n)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        return (rows, cols)
    }
}

// MARK: - Elevation（奥行きでフォーカスを示す）
//
// 非アクティブ側を灰色で減算するのではなく、アクティブ側を「手前に浮かせる」加算的な表現。
// 共有する境界（プレビューとピッカーの間）に向けて柔らかい影を落とすことで、
// どちらが操作対象かを色・明るさに依存せず depth で伝える。写真には色をかぶせない。
private extension View {
    /// - Parameters:
    ///   - active: フォーカスがこの領域にあるか（true で浮く）。
    ///   - towardBottom: 影を下辺（=境界）へ落とすなら true（上ペイン）、上辺へなら false（下ペイン）。
    func elevation(active: Bool, towardBottom: Bool) -> some View {
        self.shadow(
            color: Color.black.opacity(active ? 0.20 : 0),
            radius: active ? 16 : 0,
            y: active ? (towardBottom ? 8 : -8) : 0
        )
    }
}
