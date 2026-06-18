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
    // 選択モードの説明ポップオーバー。
    @State private var showSelectionHelp = false

    // ビュワー（プレビュー）のドラッグ矩形選択（ラバーバンド）。座標は previewArea ローカル。
    @State private var previewBandActive = false
    @State private var previewBandStart: CGPoint? = nil
    @State private var previewBandCurrent: CGPoint? = nil
    @State private var previewBandBase: Set<UInt64> = []   // Shift/⌘ 併用時の元選択
    @State private var previewDropTargeted = false          // バリエーションのドロップ受け中ハイライト
    @State private var reorderingID: UInt64? = nil           // ビュワー内ドラッグ並べ替えで持ち上げ中のタイル
    @State private var reorderDragLocation: CGPoint? = nil    // 追従中の掴んだタイルの中心座標（previewGrid 空間）
    @State private var reorderStartCenter: CGPoint? = nil     // ドラッグ開始時のタイル中心（掴みズレを防ぐ基準）
    private let pickerMinHeight: CGFloat = 140   // ここまで縮めるとプレビュー最大（＝上限）
    private let pickerMaxHeight: CGFloat = 600

    /// プレビューに並べる比較対象（store と共有：表示順の先頭 maxCompare 件）。
    private var compareIDs: [UInt64] { store.filmstripCompareIDs }

    private var selectedCount: Int { store.selectedIDs.count }

    /// フィルムストリップ表示中か（welcome＝フォルダ未読込時は false でライブラリ表示）。
    private var inFilmstrip: Bool { store.filmstripMode && store.currentDirectoryURL != nil }

    /// ピッカーが横一列レイアウトか。
    private var pickerRowMode: Bool { inFilmstrip && store.filmstripPickerLayout == .row }
    // ピッカー（グリッド）の高さ制約。
    // ・ライブラリ: 下限なし／上限 .infinity（フル高さ）
    // ・フィルムストリップ・グリッド: pickerHeight 固定（リサイズ可）
    // ・フィルムストリップ・横一列: 制約なし＝ThumbnailGridView 側が「バナー＋1行」の内容高さに
    //   フィット（伸びない／フラット化バナーが上に積まれてもヘッダーと被らない）。
    private var pickerMinHeightFrame: CGFloat? { (inFilmstrip && !pickerRowMode) ? pickerHeight : nil }
    private var pickerMaxHeightFrame: CGFloat? {
        guard inFilmstrip else { return .infinity }
        return pickerRowMode ? nil : pickerHeight
    }

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
                    // 横一列時はピッカー高さが固定なのでリサイズ不可＝分割線は隠す。
                    if !pickerRowMode { resizeDivider }

                    // ピッカーのヘッダー。グリッドは identity 維持のため外側 VStack 最下段に保つので、
                    // ピッカー側の「浮き」は境界に接するこのヘッダー（上辺へ向けた影）で表現する。
                    pickerHeader
                        // 一度平面化してから影を落とす＝内部要素（選択モードのスイッチ／クリア等）
                        // に個別の影が乗らず、浮きはヘッダー外枠のみが表現する。
                        .compositingGroup()
                        .elevation(active: !store.filmstripPreviewActive, towardBottom: false)
                        .zIndex(!store.filmstripPreviewActive ? 1 : 0)
                }

                ThumbnailGridView()
                    .frame(maxWidth: .infinity)
                    // 高さ制約は pickerMin/MaxHeightFrame に集約（横一列は内容フィット）。
                    // 同一の .frame に条件値を渡すことで identity を保つ（再生成しない）。
                    .frame(minHeight: pickerMinHeightFrame, maxHeight: pickerMaxHeightFrame)
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

            // 並べ替えをライブラリ/既定順へ戻す。並べ替え中のみ表示。
            if store.filmstripHasCustomOrder {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        store.resetFilmstripCompareOrder()
                    }
                } label: {
                    Label(String(localized: "filmstrip.order.reset", defaultValue: "Reset order"),
                          systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(String(localized: "filmstrip.order.reset.help",
                             defaultValue: "Restore the library order"))
            }

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
        let selectionMode = Binding(
            get: { store.filmstripSelectionMode },
            set: { store.filmstripSelectionMode = $0 }
        )
        return HStack(spacing: 10) {
            paneDot(active: active)
            Text(String(localized: "filmstrip.pane.picker", defaultValue: "Picker"))
                .font(.callout.weight(.medium))
                .foregroundStyle(active ? .primary : .secondary)

            Divider().frame(height: 14)

            // 選択モード ON/OFF（トグルスイッチ）
            Toggle(isOn: selectionMode) {
                Text(String(localized: "filmstrip.selectmode.toggle", defaultValue: "Selection Mode"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(String(localized: "filmstrip.selectmode.toggle.help",
                         defaultValue: "Sticky multi-select for building the compare set"))

            // モード説明（はてなボタン）
            Button { showSelectionHelp.toggle() } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "filmstrip.selectmode.help.button",
                         defaultValue: "What is Selection Mode?"))
            .popover(isPresented: $showSelectionHelp, arrowEdge: .bottom) {
                selectionModeHelp
            }

            // ON のときだけクリアボタン
            if store.filmstripSelectionMode {
                Button(String(localized: "filmstrip.selectmode.clear", defaultValue: "Clear")) {
                    store.deselectAll()
                }
                .controlSize(.small)
                .disabled(store.selectedIDs.isEmpty)
            }

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

    /// 選択モードを有効にしたときの挙動説明（はてなボタンのポップオーバー）。
    private var selectionModeHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "filmstrip.selectmode.toggle", defaultValue: "Selection Mode"),
                  systemImage: "checkmark.circle")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "filmstrip.selectmode.help.1",
                            defaultValue: "Click a thumbnail to focus it; clicking empty space does not clear your selection."))
                Text(String(localized: "filmstrip.selectmode.help.2",
                            defaultValue: "Click a focused thumbnail again to remove it."))
                Text(String(localized: "filmstrip.selectmode.help.3",
                            defaultValue: "Focused photos are shown with a translucent blue fill — distinct from normal selection."))
                Text(String(localized: "filmstrip.selectmode.help.4",
                            defaultValue: "Drag to add a range; Shift-click extends the range. Double-click to open is disabled."))
                Text(String(localized: "filmstrip.selectmode.help.5",
                            defaultValue: "Use Clear to deselect everything at once."))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Preview area（フィルムストリップ専用の白背景）

    @ViewBuilder
    private var previewArea: some View {
        let ids = compareIDs
        GeometryReader { geo in
            // 全枚数を領域内にフィット（スクロールなし・行列でぴったり割り付け）。
            // ドラッグ中は「追加後（n+1 枚）」のレイアウトで割り付け、末尾に追加先スロット
            //（次に描画される写真と同じ大きさ）の D&D 促進エリアを置く。
            let n = ids.count
            let dragging = store.filmstripMemberDragActive
            let slotCount = max(1, n + (dragging ? 1 : 0))
            let (rows, cols) = optimalGrid(memberCount: slotCount, viewportSize: geo.size)
            let spacing: CGFloat = 8
            let cellW = max(40, (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols))
            let cellH = max(40, (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows))

            ZStack(alignment: .topLeading) {
                // 写真は常に純白背景で正確に提示する（フォーカス信号は奥行き＋ディバイダーのバーに集約）。
                // 背景（＝セル以外の空白）クリックでもフォーカス（アクティブ面）はビュワーに保持し、
                // グリッド同様に空クリックは選択解除する。セルのタップはセル側 onTapGesture が優先。
                Color.white
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.filmstripPreviewActive = true
                        store.previewDeselectAll()
                    }

                // タイルの中心座標（行列を領域中央に割り付け）。並べ替え/バンド選択/ドロップ先で共用。
                let gridW = CGFloat(cols) * cellW + CGFloat(max(0, cols - 1)) * spacing
                let gridH = CGFloat(rows) * cellH + CGFloat(max(0, rows - 1)) * spacing
                let originX = (geo.size.width - gridW) / 2
                let originY = (geo.size.height - gridH) / 2
                let centerAt: (Int) -> CGPoint = { i in
                    let r = i / cols, c = i % cols
                    return CGPoint(x: originX + CGFloat(c) * (cellW + spacing) + cellW / 2,
                                   y: originY + CGFloat(r) * (cellH + spacing) + cellH / 2)
                }

                if ids.isEmpty && !dragging {
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
                    // 位置ベース配置: ForEach(id) + .position。並べ替えで各 id の位置が
                    // アニメーションで滑らかに移動する（長押し→ドラッグで持ち上げて入れ替え）。
                    ForEach(Array(ids.enumerated()), id: \.element) { pair in
                        let index = pair.offset
                        let id = pair.element
                        let lifted = reorderingID == id
                        CompareMemberColumn(
                            memberID: id,
                            isFocused: store.filmstripFocusID == id,
                            lightBackground: true,
                            compact: true,
                            downsampleMaxPixels: previewMaxPixels,
                            isSelected: store.filmstripPreviewSelectedIDs.contains(id)
                        )
                        .frame(width: cellW, height: cellH)
                        .overlay(alignment: .topTrailing) {
                            if store.filmstripFocusID == id {
                                Button {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                        store.removeFromFilmstripCompare(id)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.black.opacity(0.55))
                                }
                                .buttonStyle(.plain)
                                .padding(5)
                                .help(String(localized: "filmstrip.remove.from.compare",
                                             defaultValue: "Remove from comparison"))
                            }
                        }
                        // 並べ替えドラッグ中は影だけ付けて「浮き」を表現（拡大はしない）。
                        .shadow(color: .black.opacity(lifted ? 0.30 : 0), radius: lifted ? 14 : 0, y: lifted ? 5 : 0)
                        .zIndex(lifted ? 2 : 1)
                        // 掴んでいるタイルはマウスに追従、その他はスロット中心（spring で寄る）。
                        .position((lifted ? reorderDragLocation : nil) ?? centerAt(index))
                        // クリック選択（ピッカーとは独立）。ドラッグは並べ替え（高優先で矩形選択より先）。
                        .onTapGesture {
                            let m = NSEvent.modifierFlags
                            if m.contains(.shift) { store.previewRangeSelect(to: id) }
                            else if m.contains(.command) { store.previewToggle(id) }
                            else { store.previewSelect(id) }
                        }
                        .highPriorityGesture(reorderGesture(id: id, centerAt: centerAt))
                    }

                    // 追加先スロット（メタデータバーからのドロップ中）＝次に描画される写真と同サイズ。
                    if dragging {
                        dropPromptOverlay(active: previewDropTargeted)
                            .frame(width: cellW, height: cellH)
                            .position(centerAt(n))
                            .allowsHitTesting(false)
                    }

                    // ドラッグ矩形選択（ラバーバンド）のバンド表示。
                    if previewBandActive, let s = previewBandStart, let e = previewBandCurrent {
                        let rect = rectFrom(s, e)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                            .frame(width: max(1, rect.width), height: max(1, rect.height))
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .coordinateSpace(name: "previewGrid")
            .onAppear { store.filmstripPreviewCols = cols }
            .onChange(of: cols) { _, newCols in store.filmstripPreviewCols = newCols }
            // 並び変化のアニメーションは各操作側で withAnimation を明示する
            //（掴んだタイルの追従は非アニメ＝即マウス追従にするため、ここでは暗黙アニメを付けない）。
            // ドラッグ矩形選択。空白からのドラッグで範囲選択、Shift/⌘ で追加選択。
            // 並べ替え中（reorderingID）は抑止。
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        guard !ids.isEmpty, reorderingID == nil else { return }
                        store.filmstripPreviewActive = true
                        if !previewBandActive {
                            previewBandActive = true
                            previewBandStart = v.startLocation
                            let m = NSEvent.modifierFlags
                            previewBandBase = (m.contains(.shift) || m.contains(.command))
                                ? store.filmstripPreviewSelectedIDs : []
                        }
                        previewBandCurrent = v.location
                        let band = rectFrom(previewBandStart ?? v.startLocation, v.location)
                        var hits = previewBandBase
                        for idx in 0..<n {
                            let ctr = centerAtForBand(idx, cols: cols, cellW: cellW, cellH: cellH,
                                                      spacing: spacing, size: geo.size, rows: rows)
                            let cr = CGRect(x: ctr.x - cellW / 2, y: ctr.y - cellH / 2, width: cellW, height: cellH)
                            if band.intersects(cr) { hits.insert(ids[idx]) }
                        }
                        store.filmstripPreviewSelectedIDs = hits
                    }
                    .onEnded { _ in
                        previewBandActive = false
                        previewBandStart = nil
                        previewBandCurrent = nil
                        previewBandBase = []
                    }
            )
            // メタデータバーのバリエーションをここへドロップして比較セットに追加。
            // 受けは AppKit（NSDraggingDestination）。SwiftUI コンテンツの背面に敷く（ビュワー全体が
            // ドロップを受け付ける＝掴みやすい）。促進エリアの見た目は「追加先スロット」を上のグリッドに表示。
            .background {
                CompareDropTargetView(
                    isTargeted: $previewDropTargeted,
                    currentDragID: { store.filmstripDraggingMemberID },
                    onDropPhoto: { id in
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            store.addToFilmstripCompare(id)
                        }
                    },
                    onDragEnded: { store.filmstripDraggingMemberID = nil }
                )
            }
            .animation(.easeInOut(duration: 0.18), value: store.filmstripMemberDragActive)
            .animation(.easeInOut(duration: 0.12), value: previewDropTargeted)
        }
        // 白背景に合わせて常にライト配色（アプリがダークでも文字が黒で見えるように）
        .environment(\.colorScheme, .light)
    }

    /// メタデータバーのバリエーションをドラッグ中にビュワーへ出す「ここへドロップで追加」促進エリア。
    /// active=true（カーソルがビュワー上）で強調表示。
    @ViewBuilder
    private func dropPromptOverlay(active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(active ? 0.16 : 0.07))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(active ? 1.0 : 0.55),
                              style: StrokeStyle(lineWidth: active ? 3 : 2, dash: [9, 6]))
            VStack(spacing: 8) {
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: active ? 40 : 34, weight: .regular))
                Text(String(localized: "filmstrip.drop.prompt",
                            defaultValue: "Drop here to add to comparison"))
                    .font(.callout.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
            .scaleEffect(active ? 1.05 : 1.0)
        }
        .padding(6)
        .allowsHitTesting(false)   // ドロップ判定は背面の AppKit ビューが担う
    }

    /// 2 点から正規化した矩形を作る（ラバーバンド用）。
    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - ビュワー内ドラッグ並べ替え

    /// ドラッグでタイルを並べ替えるジェスチャ。ピッカー（selectedIDs）は変更せず、
    /// ビュワーの表示順 (filmstripCompareOrder) のみ更新する。位置アニメーションで滑らかに移動。
    /// 矩形選択より先に取るため呼び出し側は .highPriorityGesture で適用する。
    /// minimumDistance>0 でタップ（選択）とは区別する。
    private func reorderGesture(id: UInt64, centerAt: @escaping (Int) -> CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("previewGrid"))
            .onChanged { drag in
                let cur = store.filmstripCompareIDs
                guard let from = cur.firstIndex(of: id) else { return }
                if reorderingID != id {
                    reorderingID = id
                    store.filmstripPreviewActive = true
                    // 開始時のタイル中心を基準にして「中心＋移動量」で追従＝掴みズレでジャンプしない。
                    reorderStartCenter = centerAt(from)
                }
                // 掴んだタイルはマウスへ即追従（アニメーションなし）。
                let base = reorderStartCenter ?? drag.location
                let follow = CGPoint(x: base.x + drag.translation.width,
                                     y: base.y + drag.translation.height)
                reorderDragLocation = follow
                let to = nearestIndex(to: follow, count: cur.count, centerAt: centerAt)
                if to != from {
                    var newOrder = cur
                    newOrder.remove(at: from)
                    newOrder.insert(id, at: min(to, newOrder.count))
                    // 他タイルだけ spring で寄せる（追従位置の更新は上で確定済み＝非アニメ）。
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        store.setFilmstripCompareOrder(newOrder)
                    }
                }
            }
            .onEnded { _ in
                // 放したら最終スロットへ収める（マウス位置→中心へアニメーション）。
                reorderStartCenter = nil
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    reorderingID = nil
                    reorderDragLocation = nil
                }
            }
    }

    /// 点に最も近いタイルのインデックス。
    private func nearestIndex(to p: CGPoint, count: Int, centerAt: (Int) -> CGPoint) -> Int {
        guard count > 0 else { return 0 }
        var best = 0
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in 0..<count {
            let c = centerAt(i)
            let d = (p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    /// バンド選択用のタイル中心（previewArea の centerAt クロージャと同一の式。スコープ外用）。
    private func centerAtForBand(_ i: Int, cols: Int, cellW: CGFloat, cellH: CGFloat,
                                 spacing: CGFloat, size: CGSize, rows: Int) -> CGPoint {
        let gridW = CGFloat(cols) * cellW + CGFloat(max(0, cols - 1)) * spacing
        let gridH = CGFloat(rows) * cellH + CGFloat(max(0, rows - 1)) * spacing
        let originX = (size.width - gridW) / 2
        let originY = (size.height - gridH) / 2
        let r = i / cols, c = i % cols
        return CGPoint(x: originX + CGFloat(c) * (cellW + spacing) + cellW / 2,
                       y: originY + CGFloat(r) * (cellH + spacing) + cellH / 2)
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

// MARK: - ビュワーのドロップ先（メタデータバーのバリエーション → 比較セット追加）
//
// プロジェクト方針に従い、ドロップ受けは SwiftUI onDrop ではなく
// NSViewRepresentable + NSDraggingDestination で実装する。アプリ内独自タイプのみ受け付ける。
struct CompareDropTargetView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    /// ドラッグ中のメンバー ID をストアから取得（ペイロードは pasteboard ではなくストア経由）。
    let currentDragID: () -> UInt64?
    let onDropPhoto: (UInt64) -> Void
    var onDragEnded: () -> Void = {}

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.currentDragID = currentDragID
        v.onDropPhoto = onDropPhoto
        v.onTargetChanged = { isTargeted = $0 }
        v.onDragEnded = onDragEnded
        return v
    }
    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.currentDragID = currentDragID
        nsView.onDropPhoto = onDropPhoto
        nsView.onTargetChanged = { isTargeted = $0 }
        nsView.onDragEnded = onDragEnded
    }

    final class DropView: NSView {
        var currentDragID: (() -> UInt64?)?
        var onDropPhoto: ((UInt64) -> Void)?
        var onTargetChanged: ((Bool) -> Void)?
        var onDragEnded: (() -> Void)?
        private let dragType = NSPasteboard.PasteboardType(LibraryStore.filmstripPhotoDragType)

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([dragType])
        }
        required init?(coder: NSCoder) { fatalError() }

        /// 自前のメンバードラッグか。この NSView は dragType のみ登録しているため、
        /// draggingEntered が来る時点で対象のドラッグ。ストアにペイロードがあれば受理する。
        private func isMemberDrag(_ sender: NSDraggingInfo) -> Bool {
            currentDragID?() != nil
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard isMemberDrag(sender) else { return [] }
            DispatchQueue.main.async { self.onTargetChanged?(true) }
            return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            isMemberDrag(sender) ? .copy : []
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            isMemberDrag(sender)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
            guard let id = currentDragID?() else { return false }
            DispatchQueue.main.async { self.onDropPhoto?(id) }
            return true
        }
        // ドラッグ操作の終了（ドロップ/キャンセル問わず）。促進エリアの表示を畳む。
        // ビュワーを通過したドラッグでは確実に呼ばれる。
        override func draggingEnded(_ sender: NSDraggingInfo) {
            DispatchQueue.main.async {
                self.onTargetChanged?(false)
                self.onDragEnded?()
            }
        }
    }
}
