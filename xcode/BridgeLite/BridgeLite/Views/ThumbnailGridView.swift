import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isDropTargeted = false
    @State private var lastDailyTap: (id: UInt64, time: Date)?
    @State private var rubberBandStart: CGPoint? = nil
    @State private var rubberBandEnd: CGPoint? = nil
    private var cellSize: CGFloat { store.settings.thumbnailSize }
    /// フィルムストリップの横一列ピッカーか（グリッド領域を 1 行分の高さに固定する）。
    private var isPickerRow: Bool { store.filmstripMode && store.filmstripPickerLayout == .row }

    private func handleDailyTap(id: UInt64) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let last = lastDailyTap,
           last.id == id,
           Date().timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
            store.selectEntry(id)
            if store.settings.gridOpenGesture == .spaceCompare {
                store.viewerMode = true
            } else {
                store.compareAnchorID = id
                store.compareMode = true
            }
            HintCenter.shared.fireOnce(.openGestureSwap)
            lastDailyTap = nil
            return
        }
        lastDailyTap = (id, Date())
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            store.toggleSelect(id)
        } else if flags.contains(.shift) {
            store.rangeSelect(to: id)
        } else {
            store.selectEntry(id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.filter.nameSearch.isEmpty {
                searchBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if store.filter.flatten {
                flattenBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if store.depthExceeded {
                depthExceededBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ZStack {
                if store.currentDirectoryURL == nil {
                    emptyStateContent
                } else if !store.filter.nameSearch.isEmpty && store.visibleIDs.isEmpty {
                    searchEmptyState
                } else if store.settings.viewMode == .daily {
                    dailyGrid
                } else if store.filmstripMode && store.filmstripPickerLayout == .row {
                    singleRowGrid
                } else {
                    strictGrid
                }

                if isDropTargeted {
                    Color.blue.opacity(0.15)
                        .allowsHitTesting(false)
                }

            }
            // 横一列は内容（＝1行）にフィット。バナーは上に積まれ高さを取り合わない＝ヘッダーと被らない。
            .frame(maxWidth: .infinity, maxHeight: isPickerRow ? nil : .infinity)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
            // フィルタ適用をデバウンス中（結果未反映）はシマーを流して「更新中」を示す。
            .shimmer(when: store.isFilterPending)
            // background に置くことでクリックは前面 SwiftUI ビューへ直行し、
            // ドラッグは登録型(.fileURL)を探す AppKit drag system が背後のビューも見つけてくれる
            .background {
                FolderDropTargetView(isTargeted: $isDropTargeted) { url in
                    store.loadFolder(url)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.filter.flatten)
        .animation(.easeInOut(duration: 0.2), value: store.filter.nameSearch.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: store.depthExceeded)
    }

    private var searchBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.blue)
            Text(String(localized: "Searching \"\(store.filter.nameSearch)\""))
                .font(.caption2.bold())
                .foregroundStyle(.blue)
            Text("— \(store.visibleIDs.count) results")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.setNameSearch("")
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Clear search"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.blue.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var flattenBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text("Flatten")
                .font(.caption2.bold())
                .foregroundStyle(.orange)
            Text("— showing all files individually")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.filter.flatten = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Turn off Flatten")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var depthExceededBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.questionmark")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text("Depth limit reached")
                .font(.caption2.bold())
                .foregroundStyle(.yellow)
            Text("— some images beyond 10 folder levels are not shown")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                store.depthExceeded = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.yellow.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Empty state

    private var emptyStateContent: some View {
        let recents = RecentFoldersStore.shared.recentURLs
        return VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)
            Text("Drop a folder to open")
                .font(.title3)
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)

            if !recents.isEmpty && !isDropTargeted {
                Divider()
                    .frame(width: 220)
                    .padding(.vertical, 4)
                Text("Recent Folders")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                VStack(spacing: 4) {
                    ForEach(recents, id: \.path) { url in
                        Button {
                            store.loadFolder(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(url.path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                        .frame(width: 220)
                        .padding(.top, 4)
                    Button(String(localized: "menu.open_recent.clear", defaultValue: "Clear Recent Folders")) {
                        RecentFoldersStore.shared.clear()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Color.secondary)
            Text(String(localized: "No files match \"\(store.filter.nameSearch)\""))
                .font(.title3)
                .foregroundStyle(Color.secondary)
            Button(String(localized: "Clear search")) {
                store.setNameSearch("")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.blue)
        }
    }

    // MARK: - Strict grid (square LazyVGrid)

    private var strictGrid: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / (cellSize + 8)))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: 8), count: cols)
            let rows = max(1, Int(ceil(Double(store.visibleIDs.count) / Double(cols))))
            let contentHeight = CGFloat(rows) * cellSize + CGFloat(max(0, rows - 1)) * 8 + 16
            // LazyVGrid は固定幅カラムを中央寄せするため、col0 の左端は中央寄せオフセット分ずれる。
            // 操作層へ実際の左インセットを渡し、左右余白を「セル外＝ラバーバンド可」に正しく扱う。
            let gridWidth = CGFloat(cols) * cellSize + CGFloat(max(0, cols - 1)) * 8
            let leadingInset = (geo.size.width - gridWidth) / 2
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(store.visibleIDs, id: \.self) { id in
                                if let entry = store.entries[id] {
                                    ThumbnailCellView(entry: entry)
                                        .id(id)
                                }
                            }
                        }
                        .padding(8)

                        GridInteractionView(
                            store: store,
                            visibleIDs: store.visibleIDs,
                            columns: cols,
                            cellSize: cellSize,
                            leadingInset: leadingInset,
                            rubberBandStart: $rubberBandStart,
                            rubberBandEnd: $rubberBandEnd
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: contentHeight)

                        if let start = rubberBandStart, let end = rubberBandEnd {
                            let rect = rubberBandRect(from: start, to: end)
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                                .frame(width: max(1, rect.width), height: max(1, rect.height))
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                }
                .onAppear { store.gridColumnCount = cols; scrollToFirstSelected(proxy) }
                .onChange(of: cols) { _, newCols in store.gridColumnCount = newCols }
                .onChange(of: store.viewerMode)  { _, isOn in if !isOn { scrollToPrimary(proxy) } }
                .onChange(of: store.compareMode) { _, isOn in if !isOn { scrollToPrimary(proxy) } }
                // ライブラリ↔フィルムストリップ遷移時、選択中で最も先頭のサムネを見せる。
                .onChange(of: store.filmstripMode) { _, _ in scrollToFirstSelected(proxy) }
                .onReceive(store.revealPrimaryRequest) { _ in scrollToPrimary(proxy) }
            }
        }
        .id(store.scanGeneration)
    }

    // MARK: - Single row (filmstrip picker, horizontal LazyHGrid)
    //
    // 全件を 1 行で横スクロール表示する。マウス操作の GridInteractionView は
    // columns = 全件数 を渡すことで「row=0 固定・index=col」の単一行として整合する
    // （cellID(at:) / updateRubberBand の row*columns+col 計算がそのまま成立）。

    private var singleRowGrid: some View {
        let count = store.visibleIDs.count
        let contentWidth = CGFloat(count) * cellSize + CGFloat(max(0, count - 1)) * 8 + 16
        let rowHeight = cellSize + 16
        // 水平スクロールバー用の帯。1 行の下に確保し、ステータスバーに被って見切れるのを防ぐ。
        let scrollbarBand: CGFloat = 14
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    LazyHGrid(rows: [GridItem(.fixed(cellSize), spacing: 8)], spacing: 8) {
                        ForEach(store.visibleIDs, id: \.self) { id in
                            if let entry = store.entries[id] {
                                ThumbnailCellView(entry: entry)
                                    .id(id)
                            }
                        }
                    }
                    .padding(8)

                    GridInteractionView(
                        store: store,
                        visibleIDs: store.visibleIDs,
                        columns: max(1, count),   // 単一行＝全件が 1 行（index = col, row = 0）
                        cellSize: cellSize,
                        rubberBandStart: $rubberBandStart,
                        rubberBandEnd: $rubberBandEnd
                    )
                    .frame(width: contentWidth, height: rowHeight)

                    if let start = rubberBandStart, let end = rubberBandEnd {
                        let rect = rubberBandRect(from: start, to: end)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                            .frame(width: max(1, rect.width), height: max(1, rect.height))
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: rowHeight, alignment: .topLeading)
                .clipped()
            }
            // 1 行分＋スクロールバー帯に固定（縦に伸びない＝バナーと取り合わない／バーが見切れない）。
            .frame(height: rowHeight + scrollbarBand)
            .onAppear { store.gridColumnCount = max(1, count); scrollToFirstSelected(proxy) }
            .onChange(of: count) { _, c in store.gridColumnCount = max(1, c) }
            .onChange(of: store.viewerMode)  { _, isOn in if !isOn { scrollToPrimary(proxy) } }
            .onChange(of: store.compareMode) { _, isOn in if !isOn { scrollToPrimary(proxy) } }
            // 横配列ピッカーでも、遷移時に選択中で最も先頭のサムネを水平スクロールで見せる。
            .onChange(of: store.filmstripMode) { _, _ in scrollToFirstSelected(proxy) }
            .onReceive(store.revealPrimaryRequest) { _ in scrollToPrimary(proxy) }
        }
        .id(store.scanGeneration)
    }

    // MARK: - Daily grid (grouped by shooting date)
    // [BETA DISABLED] ViewModePicker を非表示にしているため現在到達しない。
    // フリーズ修正後に ViewModePicker を ToolbarView に戻すことで再有効化できる。

    private var dailyGrid: some View {
        GeometryReader { geo in
            let cols = max(2, Int((geo.size.width - 16) / (cellSize + 8)))
            let gridColumns = Array(repeating: GridItem(.fixed(cellSize), spacing: 8), count: cols)

            ScrollViewReader { proxy in
                ScrollView {
                    // LazyVStack でセクション単位の遅延描画、内側の LazyVGrid で写真単位の遅延描画
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.dailyGroups) { group in
                            DailyGroupHeaderView(date: group.date, ids: group.ids)
                                .padding(.horizontal, 8)
                                .padding(.top, 20)
                                .padding(.bottom, 8)

                            LazyVGrid(columns: gridColumns, spacing: 8) {
                                ForEach(group.ids, id: \.self) { id in
                                    if let entry = store.entries[id] {
                                        ThumbnailCellView(entry: entry)
                                            .onTapGesture { handleDailyTap(id: id) }
                                            .id(id)
                                    }
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 16)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .onAppear {
                    store.gridColumnCount = cols
                    // モード切替直後やアプリ起動時にキャッシュが空の場合を補う
                    store.refreshDailyGroupsIfNeeded()
                }
                .onChange(of: cols) { _, c in store.gridColumnCount = c }
                .onChange(of: store.viewerMode)  { _, isOn in if !isOn { scrollToPrimary(proxy) } }
                .onChange(of: store.compareMode) { _, isOn in if !isOn { scrollToPrimary(proxy) } }
                .onReceive(store.revealPrimaryRequest) { _ in scrollToPrimary(proxy) }
            }
        }
        .id(store.scanGeneration)
    }

    private func rubberBandRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    /// ライブラリ↔フィルムストリップ遷移時に、選択中で最もリスト先頭のサムネイルを
    /// グリッド/ピッカー（縦・横どちらの配列でも）に見えるようスクロールする。
    private func scrollToFirstSelected(_ proxy: ScrollViewProxy) {
        guard let id = store.firstSelectedVisibleID else { return }
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    private func scrollToPrimary(_ proxy: ScrollViewProxy) {
        guard let id = store.primaryID else { return }
        // 遷移前のスクロール位置のまま戻るため、この時点の可視範囲＝遷移前の描画範囲。
        // primaryID のセルが既に完全に描画されているなら動かさない。範囲外のときだけ中央へ寄せる。
        if store.isPrimaryCellVisible?(id) == true { return }
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(id, anchor: .center) }
        }
    }

}

// MARK: - Grid interaction layer

private struct GridInteractionView: NSViewRepresentable {
    let store: LibraryStore
    let visibleIDs: [UInt64]
    let columns: Int
    let cellSize: CGFloat
    var leadingInset: CGFloat = 8    // セル col0 の左端（LazyVGrid の中央寄せオフセットを反映）
    @Binding var rubberBandStart: CGPoint?
    @Binding var rubberBandEnd: CGPoint?

    func makeNSView(context: Context) -> GridInteractionNSView {
        let view = GridInteractionNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: GridInteractionNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: GridInteractionNSView) {
        view.store = store
        view.visibleIDs = visibleIDs
        view.columns = columns
        view.cellSize = cellSize
        view.leadingInset = leadingInset
        view.onRubberBandChanged = { start, end in
            rubberBandStart = start
            rubberBandEnd = end
        }
        // 戻り時のスクロール判定用に、NSView の可視範囲問い合わせを store へ橋渡しする。
        store.isPrimaryCellVisible = { [weak view] id in
            view?.isCellFullyVisible(id: id) ?? false
        }
    }
}

@MainActor
private final class GridInteractionNSView: NSView {
    weak var store: LibraryStore?
    var visibleIDs: [UInt64] = []
    var columns = 1
    var cellSize: CGFloat = 120
    var leadingInset: CGFloat = 8
    var onRubberBandChanged: ((CGPoint?, CGPoint?) -> Void)?

    private let dragSource = CellDragSource()
    private var mouseDownPoint: CGPoint?
    private var mouseDownID: UInt64?
    private var isDragging = false
    private var isRubberBanding = false
    private var rubberBandBase: Set<UInt64> = []   // 選択モードのラバーバンド加算の起点選択
    private var suppressMouseUp = false
    private var lastClick: (id: UInt64, timestamp: TimeInterval)?
    private var lastMenuPoint: CGPoint = .zero   // 共有シートの anchor（右クリック位置）

    // AppKit はドラッグ開始時 beginDraggingSession 内で dispatch_apply を使い
    // バックグラウンドキューから NSViewGetTransformToAncestor → isFlipped を読む。
    // @MainActor 隔離のままだと main 以外で呼ばれ swift_task_checkIsolated が発火して
    // クラッシュするため nonisolated 化する（定数を返すだけで隔離状態に触れない）。
    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // SwiftUI の ScrollView に埋め込んだ AppKit ビューは、ビューポート外（スクロールで隠れた領域）でも
    // ヒットテストが残る。この NSView は contentHeight 全面サイズのため、ピッカーをスクロールすると
    // 隠れた部分がビューア領域・ステータスバーの上に被り、クリックを横取りしてしまう。
    // （フィルムストリップの ZStack/zIndex 入れ子では `visibleRect` が contentHeight 全面を返して
    // 効かないため、エンクロージング NSScrollView の可視内容矩形＝実際の画面上ビューポートで厳密に絞る。）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let scrollView = enclosingScrollView, let docView = scrollView.documentView {
            let viewport = convert(scrollView.documentVisibleRect, from: docView)
            guard viewport.contains(local) else { return nil }
        } else {
            guard visibleRect.contains(local) else { return nil }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        // フィルムストリップ中にピッカーを操作したら、アクティブ面をピッカーへ戻す
        if store?.filmstripMode == true { store?.filmstripPreviewActive = false }
        if event.modifierFlags.contains(.control) {
            suppressMouseUp = true
            showContextMenu(for: event)
            return
        }

        suppressMouseUp = false
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownID = cellID(at: point)
        isDragging = false
        isRubberBanding = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }

        if let id = mouseDownID {
            guard !isDragging else { return }
            isDragging = true
            beginFileDrag(id: id, event: event)
        } else {
            if !isRubberBanding {
                isRubberBanding = true
                // 選択モードは常に加算（既存選択を保持してドラッグ範囲を足す）。
                if store?.isSelectionModeActive == true {
                    rubberBandBase = store?.selectedIDs ?? []
                } else if !event.modifierFlags.contains(.shift),
                          !event.modifierFlags.contains(.command) {
                    rubberBandBase = []
                    store?.deselectAll()
                } else {
                    rubberBandBase = []
                }
            }
            updateRubberBand(from: start, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { resetPointerState() }
        guard !suppressMouseUp else { return }
        if isRubberBanding {
            onRubberBandChanged?(nil, nil)
            return
        }
        guard !isDragging, let start = mouseDownPoint else { return }

        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) < 4 else { return }
        guard let id = cellID(at: point), id == mouseDownID else {
            // 選択モードはセル外クリックで解除しない（クリアはボタンのみ）。
            if store?.isSelectionModeActive != true { store?.deselectAll() }
            return
        }
        handleClick(id: id, event: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(for: event)
    }

    private func resetPointerState() {
        mouseDownPoint = nil
        mouseDownID = nil
        isDragging = false
        isRubberBanding = false
        rubberBandBase = []
        suppressMouseUp = false
    }

    /// 指定 id のセルが、いまグリッドの可視範囲に「完全に」収まって描画されているか。
    /// cellID(at:) の逆変換（index→矩形）。strictGrid（縦）も singleRowGrid（columns=全件で
    /// row=0 固定）も同じ式で成立する。visibleRect は hitTest と同じく自分の座標系の可視部分。
    func isCellFullyVisible(id: UInt64) -> Bool {
        guard let index = visibleIDs.firstIndex(of: id), columns > 0 else { return false }
        let pad: CGFloat = 8
        let spacing: CGFloat = 8
        let col = index % columns
        let row = index / columns
        let cellRect = CGRect(
            x: leadingInset + CGFloat(col) * (cellSize + spacing),
            y: pad + CGFloat(row) * (cellSize + spacing),
            width: cellSize, height: cellSize
        )
        return visibleRect.contains(cellRect)
    }

    private func cellID(at point: CGPoint) -> UInt64? {
        let pad: CGFloat = 8       // 縦（行）の起点
        let spacing: CGFloat = 8
        // 横は leadingInset 起点（中央寄せの左右余白はセル外＝nil になりラバーバンド可）。
        guard point.x >= leadingInset, point.y >= pad else { return nil }
        let col = Int((point.x - leadingInset) / (cellSize + spacing))
        let row = Int((point.y - pad) / (cellSize + spacing))
        guard col >= 0, col < columns, row >= 0 else { return nil }

        let cellOrigin = CGPoint(
            x: leadingInset + CGFloat(col) * (cellSize + spacing),
            y: pad + CGFloat(row) * (cellSize + spacing)
        )
        let cellRect = CGRect(origin: cellOrigin, size: CGSize(width: cellSize, height: cellSize))
        let index = row * columns + col
        guard cellRect.contains(point), index < visibleIDs.count else { return nil }
        return visibleIDs[index]
    }

    private func handleClick(id: UInt64, event: NSEvent) {
        guard let store else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)

        // 選択モード: 粘着トグル選択。ダブルクリック起動は無効化し（再クリックで確実に解除）、
        // Shift は範囲を「加算」、Cmd は単クリックと同義（どちらもトグル）に揃える。
        if store.isSelectionModeActive {
            if event.modifierFlags.contains(.shift) {
                store.rangeSelectAdditive(to: id)
            } else {
                store.toggleSelect(id)
            }
            lastClick = nil
            return
        }

        if let lastClick,
           lastClick.id == id,
           event.timestamp - lastClick.timestamp < NSEvent.doubleClickInterval {
            store.selectEntry(id)
            if store.settings.gridOpenGesture == .spaceCompare {
                store.viewerMode = true
            } else {
                store.compareAnchorID = id
                store.compareMode = true
            }
            HintCenter.shared.fireOnce(.openGestureSwap)
            self.lastClick = nil
            return
        }
        lastClick = (id, event.timestamp)

        if event.modifierFlags.contains(.command) {
            store.toggleSelect(id)
        } else if event.modifierFlags.contains(.shift) {
            store.rangeSelect(to: id)
        } else {
            store.selectEntry(id)
        }
    }

    private func beginFileDrag(id: UInt64, event: NSEvent) {
        guard let store, store.entries[id] != nil else { return }
        // 標準挙動(Finder 等): 未選択セルからドラッグ開始 → 他の選択をクリアして
        // そのセルだけを選択し直す。選択済みセルからなら選択全部をドラッグ。
        // 選択モードでは粘着選択を壊さないよう、置換ではなく「追加」する。
        if !store.selectedIDs.contains(id) {
            if store.isSelectionModeActive { store.toggleSelect(id) }
            else { store.selectEntry(id) }
        }
        let ids = store.selectedIDs
        let scope = resolveDndScope(store: store, flags: event.modifierFlags)
        // RAW 等と一緒に存在する XMP サイドカーも同梱する（コピー/共有と挙動を揃える）。
        let urls = store.appendingSidecars(store.urlsFor(ids: ids, scope: scope))
        // スタックプレビュー用に先頭最大5枚のサムネを集める（先頭=ドラッグ中のセル、以降は可視順）
        var previewIDs: [UInt64] = [id]
        for vid in store.visibleIDs where vid != id && ids.contains(vid) {
            previewIDs.append(vid)
            if previewIDs.count >= 5 { break }
        }
        let images: [CGImage] = previewIDs.compactMap { pid in
            guard let url = store.entries[pid]?.url else { return nil }
            return ThumbnailDecodeCache.shared.peek(url: url)
                ?? ThumbnailDecodeCache.shared.decode(url: url, blob: store.thumbnailBlobs[pid])
        }
        let dragPoint = mouseDownPoint ?? convert(event.locationInWindow, from: nil)
        dragSource.begin(from: self, event: event, at: dragPoint,
                         urls: urls, cellSize: cellSize, images: images)
    }

    private func resolveDndScope(store: LibraryStore, flags: NSEvent.ModifierFlags) -> GroupScopeMode {
        let base: GroupScopeMode =
            store.settings.dndScopeMode == .allInGroup ? .allInGroup : .representative
        guard flags.contains(.option) else { return base }
        return base == .representative ? .allInGroup : .representative
    }

    private func updateRubberBand(from start: CGPoint, to end: CGPoint) {
        guard let store else { return }
        onRubberBandChanged?(start, end)
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        let pad: CGFloat = 8
        let spacing: CGFloat = 8
        var hits: Set<UInt64> = []
        for (index, id) in visibleIDs.enumerated() {
            let col = CGFloat(index % columns)
            let row = CGFloat(index / columns)
            let cellRect = CGRect(
                x: leadingInset + col * (cellSize + spacing),
                y: pad + row * (cellSize + spacing),
                width: cellSize,
                height: cellSize
            )
            if rect.intersects(cellRect) { hits.insert(id) }
        }
        if store.isSelectionModeActive {
            store.rubberBandSelect(hits, additiveBase: rubberBandBase)
        } else {
            store.rubberBandSelect(hits)
        }
    }

    private func showContextMenu(for event: NSEvent) {
        guard let store else { return }
        let point = convert(event.locationInWindow, from: nil)
        lastMenuPoint = point
        guard let id = cellID(at: point), let entry = store.entries[id] else {
            // 選択モードはセル外の操作で選択を解除しない。
            if !store.isSelectionModeActive { store.deselectAll() }
            return
        }
        if !store.selectedIDs.contains(id) {
            if store.isSelectionModeActive { store.toggleSelect(id) }
            else { store.selectEntry(id) }
        }
        let menu = makeContextMenu(entry: entry, id: id, store: store)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func makeContextMenu(entry: PhotoEntry, id: UInt64, store: LibraryStore) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(actionItem(String(localized: "Copy"), action: #selector(copySelection)))
        menu.addItem(actionItem(String(localized: "Show in Finder"), action: #selector(showInFinder(_:)),
                                representedObject: entry.url as NSURL))

        let targetURLs = store.selectedIDs.compactMap { store.entries[$0]?.url }
        let primaryURL = store.entries[store.primaryID ?? id]?.url ?? entry.url
        let openWith = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        openWith.submenu = makeOpenWithMenu(targetURLs: targetURLs, primaryURL: primaryURL)
        menu.addItem(openWith)

        // 共有（AirDrop/メール/メッセージ等）。XMP サイドカーも一緒に共有する。
        let shareURLs = store.appendingSidecars(targetURLs)
        menu.addItem(actionItem(String(localized: "Share"),
                                action: #selector(shareSelection(_:)),
                                representedObject: shareURLs as NSArray))
        menu.addItem(.separator())

        let rating = NSMenuItem(title: String(localized: "Rating"), action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu()
        let ratingModifiers = store.settings.ratingShortcutModifier.nsEventModifierFlags
        ratingMenu.addItem(actionItem(String(localized: "No Rating"), action: #selector(applyRating(_:)),
                                      representedObject: NSNumber(value: 0),
                                      keyEquivalent: "0",
                                      modifiers: ratingModifiers))
        for value in 1...5 {
            ratingMenu.addItem(actionItem(
                String(repeating: "★", count: value),
                action: #selector(applyRating(_:)),
                representedObject: NSNumber(value: value),
                keyEquivalent: String(value),
                modifiers: ratingModifiers
            ))
        }
        rating.submenu = ratingMenu
        menu.addItem(rating)

        let label = NSMenuItem(title: String(localized: "Label"), action: nil, keyEquivalent: "")
        let labelMenu = NSMenu()
        for value in [XmpLabel.red, .yellow, .green, .blue, .purple] {
            labelMenu.addItem(actionItem(
                value.name,
                action: #selector(applyLabel(_:)),
                representedObject: NSNumber(value: value.rawValue),
                keyEquivalent: value == .purple ? "" : String(Int(value.rawValue) + 5),
                modifiers: ratingModifiers
            ))
        }
        labelMenu.addItem(.separator())
        labelMenu.addItem(actionItem(String(localized: "Clear Label"), action: #selector(clearLabel)))
        label.submenu = labelMenu
        menu.addItem(label)

        let flag = NSMenuItem(title: String(localized: "Flag"), action: nil, keyEquivalent: "")
        let flagMenu = NSMenu()
        for value in [XmpFlag.pick, .reject] {
            flagMenu.addItem(actionItem(
                value.name,
                action: #selector(applyFlag(_:)),
                representedObject: NSNumber(value: value.rawValue),
                keyEquivalent: value == .pick ? "p" : "x"
            ))
        }
        flag.submenu = flagMenu
        menu.addItem(flag)
        menu.addItem(.separator())

        let swapped = store.settings.gridOpenGesture == .spaceCompare
        let compareTitle = swapped
            ? String(localized: "thumbnail.context.move_to_compare.plain",
                     defaultValue: "Move to Compare")
            : String(localized: "thumbnail.context.move_to_compare",
                     defaultValue: "Move to Compare (Double-click)")
        let viewerTitle = swapped
            ? String(localized: "thumbnail.context.move_to_viewer.dblclick",
                     defaultValue: "Move to Viewer (Double-click)")
            : String(localized: "thumbnail.context.move_to_viewer",
                     defaultValue: "Move to Viewer")
        menu.addItem(actionItem(
            compareTitle,
            action: #selector(moveToCompare(_:)),
            representedObject: NSNumber(value: id),
            keyEquivalent: swapped ? " " : ""
        ))
        menu.addItem(actionItem(
            viewerTitle,
            action: #selector(moveToViewer(_:)),
            representedObject: NSNumber(value: id),
            keyEquivalent: swapped ? "" : " "
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            String(localized: "Move to Trash"),
            action: #selector(moveToTrash),
            keyEquivalent: "\u{8}",
            modifiers: store.settings.deleteShortcutKey == .delete ? [] : .command
        ))
        return menu
    }

    private func makeOpenWithMenu(targetURLs: [URL], primaryURL: URL) -> NSMenu {
        let menu = NSMenu()
        let defaultApp = OpenWithService.defaultApplicationURL(for: primaryURL)
        if let defaultApp {
            let title = String(
                format: String(localized: "%@ (Default)"),
                OpenWithService.applicationName(at: defaultApp)
            )
            menu.addItem(openWithItem(title: title, appURL: defaultApp, targetURLs: targetURLs))
            menu.addItem(.separator())
        }

        let favorites = SettingsStore.shared.favoriteApps
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { $0 != defaultApp }
        for appURL in favorites {
            menu.addItem(openWithItem(
                title: OpenWithService.applicationName(at: appURL),
                appURL: appURL,
                targetURLs: targetURLs
            ))
        }
        if !favorites.isEmpty { menu.addItem(.separator()) }
        menu.addItem(actionItem(String(localized: "Add Application…"), action: #selector(addOpenWithApplication)))
        menu.addItem(actionItem(String(localized: "Manage Applications…"), action: #selector(manageOpenWithApplications)))
        return menu
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        representedObject: Any? = nil,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = representedObject
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func openWithItem(title: String, appURL: URL, targetURLs: [URL]) -> NSMenuItem {
        let item = actionItem(title, action: #selector(openWith(_:)))
        item.image = OpenWithService.applicationIcon(at: appURL)
        item.representedObject = OpenWithAction(appURL: appURL, targetURLs: targetURLs)
        return item
    }

    @objc private func copySelection() {
        store?.triggerCopy()
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? NSURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url as URL])
    }

    @objc private func applyRating(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        store?.triggerRating(value.intValue)
    }

    @objc private func applyLabel(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        store?.applyLabel(value.uint8Value)
    }

    @objc private func clearLabel() {
        store?.clearLabel()
    }

    @objc private func applyFlag(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? NSNumber else { return }
        store?.applyFlag(value.uint8Value)
    }

    @objc private func moveToCompare(_ sender: NSMenuItem) {
        guard let store, let value = sender.representedObject as? NSNumber else { return }
        let id = value.uint64Value
        store.selectEntry(id)
        store.compareAnchorID = id
        store.compareMode = true
    }

    @objc private func moveToViewer(_ sender: NSMenuItem) {
        guard let store, let value = sender.representedObject as? NSNumber else { return }
        store.selectEntry(value.uint64Value)
        store.viewerMode = true
    }

    @objc private func moveToTrash() {
        store?.triggerDelete()
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? OpenWithAction else { return }
        OpenWithService.open(action.targetURLs, with: action.appURL)
    }

    @objc private func shareSelection(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL], !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        // ゼロサイズ矩形だと show(relativeTo:) が退化矩形を無視して既定位置
        // （スクロール済み巨大ビューの原点付近＝可視外）に出てしまうため、
        // 右クリック位置に小さな非ゼロ矩形を置いてアンカーする。
        let rect = NSRect(x: lastMenuPoint.x - 1, y: lastMenuPoint.y - 1, width: 2, height: 2)
        picker.show(relativeTo: rect, of: self, preferredEdge: .minY)
    }

    @objc private func addOpenWithApplication() {
        guard let app = OpenWithService.presentAddApplicationPanel(),
              !SettingsStore.shared.favoriteApps.contains(app) else { return }
        SettingsStore.shared.favoriteApps.append(app)
    }

    @objc private func manageOpenWithApplications() {
        NotificationCenter.default.post(name: .bridgeLiteOpenManageApplications, object: nil)
    }
}

private final class OpenWithAction: NSObject {
    let appURL: URL
    let targetURLs: [URL]

    init(appURL: URL, targetURLs: [URL]) {
        self.appURL = appURL
        self.targetURLs = targetURLs
    }
}

@MainActor
private final class CellDragSource: NSObject, NSDraggingSource {
    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func begin(
        from view: NSView,
        event: NSEvent,
        at point: NSPoint,
        urls: [URL],
        cellSize: CGFloat,
        images: [CGImage]
    ) {
        guard !urls.isEmpty else { return }
        let preview = makeStackPreview(images: images, cellSize: cellSize)
        // ドラッグ開始地点にプレビュー中心を置く（画面左上からスライドして来るのを防ぐ）。
        let origin = NSPoint(x: point.x - preview.size.width / 2,
                             y: point.y - preview.size.height / 2)
        let frame = NSRect(origin: origin, size: preview.size)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(frame, contents: preview)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: self)
        // 解除/失敗時に元位置へ戻すアニメーション（スナップバック/フェードアウト）を無効化＝即消える。
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    /// ドラッグプレビュー: 先頭最大5枚の「実サムネ」を背後にずらして重ねたカード。
    /// 先頭(最前面)=ドラッグ中のセル、以降は可視順。数字バッジに加えて複数枚ドラッグ中だと
    /// 一目で分かる。カードサイズは先頭画像のアスペクト比基準で統一し、各カードは自分の
    /// 画像をアスペクトフィル（クロップ）で描く。
    private func makeStackPreview(images: [CGImage], cellSize: CGFloat) -> NSImage {
        let cards = max(min(images.count, 5), 1)   // 1〜5 枚
        let base = cellSize * 0.5
        var cardW = base
        var cardH = base * 0.66
        if let first = images.first, first.width > 0, first.height > 0 {
            let ar = CGFloat(first.width) / CGFloat(first.height)
            if ar >= 1 { cardW = base; cardH = base / ar } else { cardH = base; cardW = base * ar }
        }
        let layers = cards - 1
        let off: CGFloat = 5                       // 1枚ごとのずらし量
        let totalW = cardW + CGFloat(layers) * off
        let totalH = cardH + CGFloat(layers) * off
        let nsImages: [NSImage?] = (0..<cards).map { idx in
            idx < images.count
                ? NSImage(cgImage: images[idx], size: NSSize(width: images[idx].width, height: images[idx].height))
                : nil
        }
        let result = NSImage(size: NSSize(width: totalW, height: totalH))
        result.lockFocus()
        // 奥（大きい i）から手前（i=0＝左上＝ドラッグ中のセル）へ。bottom-left 原点。
        for i in stride(from: layers, through: 0, by: -1) {
            let rect = NSRect(
                x: CGFloat(i) * off,
                y: totalH - cardH - CGFloat(i) * off,
                width: cardW, height: cardH
            )
            drawCard(in: rect, image: nsImages[i])
        }
        result.unlockFocus()
        return result
    }

    private func drawCard(in rect: NSRect, image: NSImage?) {
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(white: 0.15, alpha: 1).setFill()
        clip.fill()
        clip.addClip()
        if let image {
            image.draw(in: aspectFillRect(imageSize: image.size, in: rect),
                       from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 5, yRadius: 5
        )
        NSColor.white.setStroke()
        border.lineWidth = 1.5
        border.stroke()
    }

    /// rect を覆うようにアスペクトフィル（はみ出しは clip でクロップ）した描画矩形。
    private func aspectFillRect(imageSize: NSSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return rect }
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

// MARK: - Daily group header
// [BETA DISABLED] ViewModePicker 非表示中は到達しない。削除しないこと。

private struct DailyGroupHeaderView: View {
    let date: Date
    let ids: [UInt64]
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private enum SelectionState { case none, partial, all }

    private var selectionState: SelectionState {
        let count = ids.filter { store.selectedIDs.contains($0) }.count
        if count == 0 { return .none }
        return count == ids.count ? .all : .partial
    }

    private var showCheckbox: Bool { isHovered || selectionState != .none }

    var body: some View {
        HStack(spacing: 8) {
            if showCheckbox {
                checkboxButton
                    .transition(.opacity)
            }
            Text(Self.dayFormatter.string(from: date))
                .font(.title3.bold())
                .foregroundStyle(.primary)
        }
        .animation(.easeInOut(duration: 0.12), value: showCheckbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var checkboxButton: some View {
        let state = selectionState
        return Button {
            if state == .all { store.deselectGroupIDs(ids) }
            else { store.selectGroupIDs(ids) }
        } label: {
            Image(systemName: state == .all ? "checkmark.circle.fill"
                           : state == .partial ? "minus.circle.fill"
                           : "circle")
                .foregroundStyle(state != .none ? Color.accentColor : Color.secondary)
                .font(.system(size: 20))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppKit drop target

private struct FolderDropTargetView: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: (URL) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.onDropURL = onDrop
        v.onTargetChanged = { isTargeted = $0 }
        return v
    }

    func updateNSView(_ nsView: DropView, context: Context) {
        nsView.onDropURL = onDrop
        nsView.onTargetChanged = { isTargeted = $0 }
    }

    final class DropView: NSView {
        var onDropURL: ((URL) -> Void)?
        var onTargetChanged: ((Bool) -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }
        required init?(coder: NSCoder) { fatalError() }

        private func firstFolderURL(from info: NSDraggingInfo) -> URL? {
            let pb = info.draggingPasteboard
            guard let items = pb.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  let url = items.first else { return nil }
            return url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        }

        private func isSelfDrag(_ sender: NSDraggingInfo) -> Bool {
            sender.draggingSource is CellDragSource
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            if isSelfDrag(sender) { return [] }
            guard firstFolderURL(from: sender) != nil else { return [] }
            DispatchQueue.main.async { self.onTargetChanged?(true) }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            isSelfDrag(sender) ? [] : .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
            if isSelfDrag(sender) { return false }
            guard let url = firstFolderURL(from: sender) else { return false }
            DispatchQueue.main.async { self.onDropURL?(url) }
            return true
        }
    }
}
