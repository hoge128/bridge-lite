import SwiftUI
import UIKit

/// 可視セルの実フレーム（global 座標）を保持する参照型ストア。
/// @State の辞書に書くとスクロールのたびに再レンダーが走るため、
/// SwiftUI が観測しない plain class に書き込む（読むのはタップ時のみ）。
private final class CellFrameStore {
    var frames: [ShotGroup.ID: CGRect] = [:]
}

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
    @State private var selectedSourceRect: CGRect?
    @State private var selectedCellDimOpacity: Double = 0
    /// セル黒オーバーレイの対象。selectedGroup と分離する理由:
    /// selectedGroup を条件にすると overlay 除去（selectedGroup = nil）と同じ
    /// コミットでセル黒も構造的に消え、フェードが transaction の滲み頼みになる。
    @State private var dimmedGroupID: ShotGroup.ID?
    /// 閉じアニメーションの飛行体（開いたセルの代表サムネイル）。presentDetail で確定。
    @State private var flyingImage: UIImage?
    /// 可視セルの実フレーム。タップ位置から合成した矩形ではなく
    /// 実セル矩形を開閉アニメーションの起点・着地点に使う。
    @State private var cellFrames = CellFrameStore()
    @State private var preferRendered: Bool

    init(scanStore: ScanStore, ratingStore: RatingStore) {
        self._scanStore = State(initialValue: scanStore)
        self._ratingStore = State(initialValue: ratingStore)
        self._preferRendered = State(initialValue: scanStore.autoRenderRawDetail)
    }
    @State private var selectedFilterCategory: FilterCategory?
    @State private var showFolderPicker = false
    @State private var showSettings = false
    @State private var showPhaseDetail = false
    @AppStorage("scanFirstRunPromptShown") private var scanFirstRunPromptShown = false
    @State private var showScanStartPrompt = false
    @State private var showShareWarning = false
    @State private var pendingShareURLs: [URL] = []
    @State private var pendingSharePreview: UIImage? = nil
    @State private var groupPendingDelete: ShotGroup?

    private static let shareWarningThreshold = 20
    private let gridSpacing: CGFloat = 1

    private func columnCount(for size: CGSize) -> Int {
        // iPad: 幅から目標セル幅（~165pt）で逆算。Stage Manager / Split View で
        // ウィンドウがリサイズされても geo.size 追従で列数が変わる。3〜10 列にクランプ。
        if UIDevice.current.userInterfaceIdiom == .pad {
            let targetCellWidth: CGFloat = 148
            let cols = Int((size.width / targetCellWidth).rounded())
            return max(3, min(cols, 10))
        }
        // iPhone は従来どおり縦3列 / 横5列。
        return size.width > size.height ? 5 : 3
    }

    private var shareNeedsWarning: Bool {
        filteredGroups.count > Self.shareWarningThreshold
    }

    @ViewBuilder
    private var filterOverlay: some View {
        if selectedFilterCategory != nil {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilterCategory = nil
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if scanStore.groups.isEmpty && scanStore.isScanning {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "Scanning…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scanStore.groups.isEmpty {
                emptyState
            } else {
                grid
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if scanStore.isScanning {
                            scanProgressBanner
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: scanStore.isScanning)
            }

            filterOverlay
        }
        .animation(.easeInOut(duration: 0.2), value: selectedFilterCategory)
        .navigationTitle(scanStore.folderURL?.lastPathComponent ?? "BridgeLite")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavigationBar()
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { filterBottomBar }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                showFolderPicker = false
                scanStore.scan(url: url)
                if !scanFirstRunPromptShown {
                    showScanStartPrompt = true
                    scanFirstRunPromptShown = true
                }
            }
        }
        .alert(
            String(localized: "scan.prompt.title", defaultValue: "Scanning Library"),
            isPresented: $showScanStartPrompt
        ) {
            Button(String(localized: "scan.prompt.ok", defaultValue: "Got It")) { }
        } message: {
            Text(String(localized: "scan.prompt.message",
                        defaultValue: "Your photo library is being scanned for the first time. This may take a few minutes depending on library size.\n\nFilters and search will be available after scanning completes. You can browse photos, but loading may be slower while scanning. Processing continues in the background."))
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(scanStore: scanStore) { showSettings = false }
        }
        .onChange(of: scanStore.entries) { _, newEntries in
            let all = Array(newEntries.values)
            Task { await ratingStore.loadAll(entries: all, jpgWriteMode: scanStore.jpgWriteMode) }
        }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        detailPresenter
        .confirmationDialog(
            String(localized: "export.warning.title", defaultValue: "Too Many Photos"),
            isPresented: $showShareWarning,
            titleVisibility: .visible
        ) {
            Button(String(localized: "export.guide.continue")) {
                let urls = pendingShareURLs
                let preview = pendingSharePreview
                pendingShareURLs = []
                pendingSharePreview = nil
                presentActivityController(urls: urls, preview: preview, count: urls.count)
            }
            Button(String(localized: "export.warning.filter_first", defaultValue: "Filter First")) { }
            Button(String(localized: "Cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "export.warning.body \(pendingShareURLs.count)"))
        }
        .confirmationDialog(
            String(localized: "delete.ios.confirm.title", defaultValue: "Move to Trash?"),
            isPresented: Binding(
                get: { groupPendingDelete != nil },
                set: { if !$0 { groupPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let group = groupPendingDelete {
                    scanStore.deleteGroup(group)
                    groupPendingDelete = nil
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { groupPendingDelete = nil }
        } message: {
            Text(String(localized: "delete.ios.confirm.message", defaultValue: "This cannot be undone."))
        }
        // DetailView 表示中は自動一時解放を保留する。詳細画面のページング・レーティングは
        // グリッド側のリセット経路を通らないため、保留しないとセレクト作業の最中に
        // enterAutoRelease が発火してウェルカム画面へ戻されてしまう。
        .onChange(of: selectedGroup?.id) { _, newID in
            if newID != nil {
                scanStore.suspendAutoReleaseTimer()
            } else {
                scanStore.resumeAutoReleaseTimer()
            }
        }
    }

    // MARK: - Detail presentation

    /// iPad は ZStack オーバーレイ、iPhone は sheet。
    /// fullScreenCover は dismiss 時に UIKit の transition frame が発生し flash するため、
    /// iPad は ZStack で直接重ねる方式に変更。UIKit presentation layer が存在しないため
    /// transition flash が構造的に起きない。
    @ViewBuilder
    private var detailPresenter: some View {
        if isPad {
            ZStack {
                NavigationStack { mainContent }
                if let group = selectedGroup {
                    ExpandFromCellFullScreenCover(
                        sourceRect: selectedSourceRect,
                        flyingImage: flyingImage,
                        // 着地先は閉じる瞬間に解決する。開いた時点の矩形・画像は
                        // DetailView 内のページング・回転・削除で古くなるため。
                        closeTargetProvider: {
                            guard let id = dimmedGroupID,
                                  let g = filteredGroups.first(where: { $0.id == id }),
                                  let rect = cellFrames.frames[id] else { return (nil, nil) }
                            let repID = g.representativeID ?? g.memberIDs.first
                            let img = repID
                                .flatMap { scanStore.thumbnails[$0] }
                                .flatMap { UIImage(data: $0) }
                            return (rect, img)
                        },
                        onCloseAnimationStarted: nil, // セルは閉じアニメーション中は黒のまま保持
                        onCloseAnimationFinished: {
                            finishDetailDismissal()
                            // セルの黒は【即時】解除する（withAnimation 禁止:
                            // overlay 除去と同一コミットのグローバル transaction は
                            // teardown 中の NavigationStack ホストに滲んで全画面ベールになる）。
                            // 飛行サムネイルがセルとピクセル一致で着地しているため、
                            // 飛行イメージ→実セルの瞬間スワップはシームレス。
                            // ここでフェードを掛けると「写真→黒→写真」の瞬きがセル内に見える。
                            selectedCellDimOpacity = 0
                            dimmedGroupID = nil
                        }
                    ) { triggerClose, dismissDragOffset in
                        NavigationStack {
                            detailView(group: group, onClose: triggerClose, dismissDragOffset: dismissDragOffset)
                                // SwiftUI は state 更新のたびに NavigationStack の
                                // ホスティングビューへ systemBackground を再アサートする。
                                // UIKit 階層を歩いて clear にするワークアラウンド
                                // (ClearHostingBackground) はそのたびに巻き戻されるため、
                                // SwiftUI 自身に「このナビゲーションコンテナの背景は透明」と
                                // 宣言させて再アサート自体を clear にする (iOS 18+)。
                                .containerBackground(Color.clear, for: .navigation)
                        }
                    }
                    .ignoresSafeArea()
                    // 除去時に transaction が滲んでも opacity フェードさせない保険。
                    .transition(.identity)
                }
            }
        } else {
            // iPhone: ios/v0.1.4 と同じ sheet 提示。DetailViewPhone が自前の
            // NavigationStack を持つため、ここではラップしない。
            NavigationStack { mainContent }
                .sheet(item: $selectedGroup) { group in
                    DetailViewPhone(
                        groups: filteredGroups,
                        initialGroup: group,
                        entries: scanStore.entries,
                        ratings: Binding(
                            get: { ratingStore.ratings },
                            set: { ratingStore.ratings = $0 }
                        ),
                        db: scanStore.db,
                        jpgWriteMode: scanStore.jpgWriteMode,
                        scanStore: scanStore,
                        preferRendered: $preferRendered
                    )
                }
        }
    }

    private func detailView(group: ShotGroup, onClose: @escaping () -> Void,
                            dismissDragOffset: Binding<CGSize> = .constant(.zero)) -> some View {
        DetailView(
            groups: filteredGroups,
            initialGroup: group,
            entries: scanStore.entries,
            ratings: Binding(
                get: { ratingStore.ratings },
                set: { ratingStore.ratings = $0 }
            ),
            db: scanStore.db,
            jpgWriteMode: scanStore.jpgWriteMode,
            scanStore: scanStore,
            preferRendered: $preferRendered,
            dismissDragOffset: dismissDragOffset,
            onCurrentGroupChanged: { g in
                // 黒い穴（dim）を現在の写真のセルへ移す。グリッドのスクロール追従は
                // dimmedGroupID の onChange 側で「セルが実体化されていないときだけ」行う。
                // 閉じアニメーションの着地矩形は closeTargetProvider が閉じる瞬間に解決する。
                dimmedGroupID = g.id
            },
            onClose: onClose
        )
    }

    private func presentDetail(group: ShotGroup, sourceRect: CGRect?) {
        // タップ座標から合成した矩形はセルの実位置と最大セル半分ズレるため、
        // 記録済みの実セルフレームを優先する（着地点ズレの修正）。
        selectedSourceRect = cellFrames.frames[group.id] ?? sourceRect
        dimmedGroupID = group.id
        // 閉じアニメーション用の飛行体。セルと同じ代表サムネイルを使うことで
        // 着地時にセル描画とピクセル一致する。
        let repID = group.representativeID ?? group.memberIDs.first
        flyingImage = repID
            .flatMap { scanStore.thumbnails[$0] }
            .flatMap { UIImage(data: $0) }
        selectedCellDimOpacity = 1.0
        // ZStack 方式: UIKit アニメーションの抑制は不要。
        // SwiftUI の transition を無効化して ExpandFromCellFullScreenCover の
        // 独自開くアニメーションだけを使う。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedGroup = group
        }
    }

    private func finishDetailDismissal() {
        // selectedCellDimOpacity は onCloseAnimationFinished 内でアニメーションして 0 にする。
        // ここでは即時リセットしない（アニメーションを上書きするため）。
        selectedSourceRect = nil
        // ZStack 方式: UIKit transition が存在しないため flash なし。
        // transition を無効化して SwiftUI がデフォルトアニメーションを掛けないようにする。
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedGroup = nil
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size)
            let n = CGFloat(cols)
            let cellSize = (geo.size.width - gridSpacing * (n + 1)) / n
            let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: cols)
            // filteredGroups を一度だけ評価してローカルに保持することで、
            // ForEach 内・各セルで重複計算しない。
            let groups = filteredGroups

            ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(groups) { group in
                        let repID = group.representativeID ?? group.memberIDs.first
                        ThumbnailCellView(
                            group: group,
                            thumbnailData: repID.flatMap { scanStore.thumbnails[$0] },
                            xmp: repID.flatMap { ratingStore.ratings[$0] },
                            kind: scanStore.representativeKind(for: group, xmps: ratingStore.ratings),
                            squareCellSize: cellSize,
                            // iPhone: v0.1.4 と同じ accentColor 枠線で選択を表現。
                            // iPad は黒オーバーレイ（dimmedGroupID）で表現するため常に false。
                            isSelected: !isPad && selectedGroup?.id == group.id,
                            previewUnavailable: repID.map { scanStore.isPreviewUnavailable($0) } ?? false,
                            onTap: {
                                scanStore.resetAutoReleaseTimer()
                                // iPhone のみ: iPad は simultaneousGesture で処理。
                                if !isPad { selectedGroup = group }
                            },
                            onDelete: { groupPendingDelete = group }
                        )
                        .overlay {
                            // DetailView 表示中、開いているセルを黒くする（Photos.app の
                            // 「写真が抜けた穴」表現）。飛行サムネイルがこの黒セルの上に
                            // ピクセル一致で着地するため、カバー除去時は即時解除でシームレス。
                            // フェードは掛けない（着地後の黒い瞬きになる）。
                            if group.id == dimmedGroupID {
                                Color.black
                                    .opacity(selectedCellDimOpacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .id(group.id)
                        // セルの実フレームを記録（plain class への書き込みなので
                        // スクロール中も再レンダーは発生しない）。
                        // iPad のズーム遷移専用のため iPhone では記録しない。
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .global)
                        } action: { newFrame in
                            if isPad { cellFrames.frames[group.id] = newFrame }
                        }
                        // リサイクルされたセルのフレームを辞書から除去する。
                        // これにより frames の有無が「セルが実体化されているか」を表し、
                        // ①不要な scrollTo のスキップ判定、②閉じアニメーションが
                        // 古い矩形へ着地する事故の防止、の両方に使える。
                        .onDisappear {
                            if isPad { cellFrames.frames.removeValue(forKey: group.id) }
                        }
                        // iPad: SpatialTapGesture は tap 専用（pan ではない）のため
                        // ScrollView の pan ジェスチャーと競合せずスクロールを妨げない。
                        // simultaneousGesture で Button と同時発火させタップ座標を取得。
                        .simultaneousGesture(
                            SpatialTapGesture(coordinateSpace: .global)
                                .onEnded { value in
                                    guard isPad else { return }
                                    let loc = value.location
                                    let sourceRect = CGRect(x: loc.x - cellSize / 2,
                                                            y: loc.y - cellSize / 2,
                                                            width: cellSize, height: cellSize)
                                    presentDetail(group: group, sourceRect: sourceRect)
                                }
                        )
                        .task(id: group.representativeID ?? group.id) {
                            guard let repID = group.representativeID ?? group.memberIDs.first,
                                  let entry = scanStore.entries[repID],
                                  scanStore.thumbnails[repID] == nil else { return }
                            await scanStore.requestThumbnail(for: entry)
                        }
                    }
                }
                .padding(gridSpacing)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in scanStore.resetAutoReleaseTimer() }
            )
            // DetailView 内のページングに追従して現在セルを実体化させる
            //（LazyVGrid は画面外セルを破棄するため、スクロールしないと
            // cellFrames に新しい着地矩形が記録されない）。カバーの背後なので
            // ユーザーには見えず、閉じたとき Photos.app と同じく現在の写真の
            // セルが見える位置にいる。
            // ⚠️ scrollTo は LazyVGrid の位置解決で大量レイアウトを誘発しうる
            // 重い操作のため、セルが既に実体化されている（= cellFrames に最新
            // フレームがある）場合は呼ばない。開いた直後のセルや隣接ページングの
            // 大半はこれに該当し、scrollTo が走るのは遠くまでページしたときだけ。
            .onChange(of: dimmedGroupID) { _, id in
                guard let id, cellFrames.frames[id] == nil else { return }
                proxy.scrollTo(id)
            }
            // 回転・Split View リサイズでセルがリサイクルされ実体化が外れた
            // 場合のみ、サイズ変化時に追従し直す。
            .onChange(of: geo.size) { _, _ in
                guard let id = dimmedGroupID, cellFrames.frames[id] == nil else { return }
                proxy.scrollTo(id)
            }
            }
        }
    }

    /// フィルタ済みグループを一度だけ評価する。
    /// grid・navigationDestination・detailView で共通参照し重複計算を排除する。
    private var filteredGroups: [ShotGroup] {
        scanStore.filteredGroups(ratings: ratingStore.ratings)
    }

    // MARK: - Phase status

    private enum PhaseDetailStatus { case done, active, pending }

    private var scanProgressBanner: some View {
        // 実行中の最も番号が小さい Phase をバナーに表示する。
        // 後のフェーズが並行して先に終わっていても前のフェーズが完了するまでは前を表示し、
        // 前が完了した瞬間に後もすでに終わっていればその先へ即ジャンプする。
        let phase2Active = scanStore.scanTotalCount == 0 || scanStore.scanLoadedCount < scanStore.scanTotalCount
        let phase3Active = !phase2Active && scanStore.exifIndexTotal == 0 && !scanStore.exifIndexTaskDone
        let phase4Active = !phase2Active && scanStore.exifIndexTotal > 0 && !scanStore.exifIndexTaskDone

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showPhaseDetail.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Group {
                        if phase2Active {
                            phaseLabel(2) {
                                if scanStore.scanTotalCount > 0 {
                                    Text(String(format: String(localized: "Loading %d / %d"),
                                                scanStore.scanLoadedCount, scanStore.scanTotalCount))
                                } else {
                                    Text(String(localized: "Scanning…"))
                                }
                            }
                        } else if phase3Active {
                            phaseLabel(3) {
                                if scanStore.exifPrecheckTotal > 0 &&
                                   scanStore.exifPrecheckProgress < scanStore.exifPrecheckTotal {
                                    Text(String(format: String(localized: "scan.exif.precheck %d %d",
                                                               defaultValue: "Checking EXIF cache %1$d / %2$d"),
                                                scanStore.exifPrecheckProgress, scanStore.exifPrecheckTotal))
                                } else {
                                    Text(String(localized: "scan.exif.preparing",
                                                defaultValue: "Preparing EXIF index…"))
                                }
                            }
                        } else if phase4Active {
                            phaseLabel(4) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(format: String(localized: "scan.exif.progress %d %d",
                                                               defaultValue: "Indexing EXIF %1$d / %2$d"),
                                                scanStore.exifIndexProgress, scanStore.exifIndexTotal))
                                    if let secs = scanStore.exifIndexRemainingSeconds {
                                        Text(String(format: String(localized: "scan.exif.remaining %d",
                                                                   defaultValue: "Est. %d sec remaining"),
                                                    secs))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        } else {
                            phaseLabel(5) {
                                Text(String(localized: "scan.phase5",
                                            defaultValue: "Generating thumbnails…"))
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showPhaseDetail ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .shimmer()

            if showPhaseDetail {
                scanPhaseDetailView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(.secondarySystemBackground))
        .animation(.easeInOut(duration: 0.2), value: showPhaseDetail)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var scanPhaseDetailView: some View {
        let p2Done = scanStore.scanTotalCount > 0 && scanStore.scanLoadedCount >= scanStore.scanTotalCount
        let p3Done = scanStore.exifIndexTotal > 0 || scanStore.exifIndexTaskDone
        let p4Done = scanStore.exifIndexTaskDone
        let p3Status: PhaseDetailStatus = p3Done ? .done : (scanStore.exifPrecheckProgress > 0 ? .active : .pending)
        let p4Status: PhaseDetailStatus = p4Done ? .done : (p3Done ? .active : .pending)
        let p5Status: PhaseDetailStatus = p4Done ? .active : .pending

        return VStack(alignment: .leading, spacing: 0) {
            Divider()
            phaseDetailRow(.done, number: 1) {
                Text(String(localized: "scan.detail.p1", defaultValue: "Directory scan"))
            }
            phaseDetailRow(p2Done ? .done : .active, number: 2) {
                if p2Done {
                    Text(String(format: String(localized: "scan.detail.p2.done %d",
                                               defaultValue: "Loaded %d files"),
                                scanStore.scanTotalCount))
                } else {
                    Text(String(format: String(localized: "Loading %d / %d"),
                                scanStore.scanLoadedCount, scanStore.scanTotalCount))
                }
            }
            phaseDetailRow(p3Status, number: 3) {
                if p3Done {
                    if scanStore.exifIndexTaskDone && scanStore.exifIndexTotal == 0 {
                        Text(String(localized: "scan.detail.p3.cached", defaultValue: "All EXIF cached"))
                    } else {
                        Text(String(localized: "scan.detail.p3.done", defaultValue: "Precheck done"))
                    }
                } else if scanStore.exifPrecheckTotal > 0 && scanStore.exifPrecheckProgress < scanStore.exifPrecheckTotal {
                    Text(String(format: String(localized: "scan.exif.precheck %d %d",
                                               defaultValue: "Checking EXIF cache %1$d / %2$d"),
                                scanStore.exifPrecheckProgress, scanStore.exifPrecheckTotal))
                } else {
                    Text(String(localized: "scan.exif.preparing", defaultValue: "Preparing EXIF index…"))
                }
            }
            phaseDetailRow(p4Status, number: 4) {
                if p4Done {
                    if scanStore.exifIndexTotal > 0 {
                        Text(String(format: String(localized: "scan.detail.p4.done %d",
                                                   defaultValue: "Indexed %d files"),
                                    scanStore.exifIndexTotal))
                    } else {
                        Text(String(localized: "scan.detail.p4.cached", defaultValue: "Skipped (all cached)"))
                    }
                } else if scanStore.exifIndexTotal > 0 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: String(localized: "scan.exif.progress %d %d",
                                                   defaultValue: "Indexing EXIF %1$d / %2$d"),
                                    scanStore.exifIndexProgress, scanStore.exifIndexTotal))
                        if let secs = scanStore.exifIndexRemainingSeconds {
                            Text(String(format: String(localized: "scan.exif.remaining %d",
                                                       defaultValue: "Est. %d sec remaining"),
                                        secs))
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text(String(localized: "scan.detail.pending", defaultValue: "Pending"))
                }
            }
            phaseDetailRow(p5Status, number: 5) {
                if p4Done {
                    Text(String(localized: "scan.phase5", defaultValue: "Generating thumbnails…"))
                } else {
                    Text(String(localized: "scan.detail.pending", defaultValue: "Pending"))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func phaseDetailRow(_ status: PhaseDetailStatus, number: Int,
                                 @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Group {
                switch status {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active:
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .frame(width: 14, alignment: .center)
            content()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func phaseLabel<Content: View>(_ phase: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            Text(String(format: String(localized: "scan.phase %d",
                                       defaultValue: "Phase %d/5"),
                        phase))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(String(localized: "grid.empty", defaultValue: "No photos found"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showFolderPicker = true } label: {
                Image(systemName: "folder")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            Button {
                let groups = filteredGroups
                let urls = ExportService.urlsForGroups(groups, scanStore: scanStore, xmps: ratingStore.ratings)
                guard !urls.isEmpty else { return }
                var preview: UIImage? = nil
                if let firstGroup = groups.first,
                   let repID = firstGroup.representativeID,
                   let data = scanStore.thumbnails[repID] {
                    preview = UIImage(data: data)
                }
                if urls.count > Self.shareWarningThreshold {
                    pendingShareURLs = urls
                    pendingSharePreview = preview
                    showShareWarning = true
                } else {
                    presentActivityController(urls: urls, preview: preview, count: urls.count)
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .opacity(shareNeedsWarning ? 0.4 : 1.0)
            }
            .disabled(scanStore.groups.isEmpty)
        }
    }

    private func presentActivityController(urls: [URL], preview: UIImage?, count: Int) {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) else { return }
        var topVC = window.rootViewController
        while let presented = topVC?.presentedViewController { topVC = presented }
        guard let topVC else { return }

        // 先頭 URL にサムネイルプレビューを添付し、残りは URL のまま渡す
        var items: [Any]
        if let preview, let first = urls.first {
            let title = count == 1
                ? String(localized: "export.preview.single", defaultValue: "1 file")
                : String(localized: "export.preview.multiple \(count)")
            items = [ActivityURLWithPreview(url: first, previewImage: preview, title: title)]
                + Array(urls.dropFirst())
        } else {
            items = urls
        }

        let actVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = actVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX,
                                        y: topVC.view.bounds.midY,
                                        width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        topVC.present(actVC, animated: true)
    }

    @ViewBuilder
    private var filterBottomBar: some View {
        VStack(spacing: 0) {
            if let category = selectedFilterCategory {
                FilterOptionsPanelView(
                    category: category,
                    scanStore: scanStore,
                    ratings: ratingStore.ratings
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { }
            }
            FilterBarView(selectedCategory: $selectedFilterCategory, scanStore: scanStore)
                .padding(.vertical, 8)
        }
        // タッチを遮断するため不可視な背景を置く（glass が壊れないよう opacity を最小化）
        .background(Color(UIColor.systemBackground).opacity(0.001))
        .animation(.easeInOut(duration: 0.2), value: selectedFilterCategory)
    }
}


// DetailView の imageViewport がグローバル座標を報告するための PreferenceKey。
// internal（private でない）にすることで DetailView.swift からも使用できる。
struct DetailImageViewportFrameKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if !n.isEmpty { value = n }
    }
}

private struct ExpandFromCellFullScreenCover<Content: View>: View {
    let sourceRect: CGRect?
    /// 閉じアニメーション用の飛行体（セルの代表サムネイル）。
    /// DetailView 全体を scaleEffect で縮小する方式は、UIScrollView ベースの
    /// ZoomableImageView（プラットフォームビュー）が SwiftUI のレンダー変換補間に
    /// 追従せず 1 フレームで終端へジャンプするため、純 SwiftUI の Image を飛ばす。
    let flyingImage: UIImage?
    /// 閉じ開始時に着地先（現在表示中グループのセル矩形と飛行体画像）を解決するクロージャ。
    /// 開いた時点の sourceRect / flyingImage は DetailView 内のページング・回転・削除で
    /// 古くなるため、閉じる瞬間に毎回解決する。rect が nil のとき（セルがグリッドに
    /// 存在しない: 削除・フィルタ脱落）は中央へ縮小するフォールバックで閉じる。
    let closeTargetProvider: (() -> (rect: CGRect?, image: UIImage?))?
    let onCloseAnimationStarted: (() -> Void)?
    let onCloseAnimationFinished: () -> Void
    /// content は triggerClose クロージャを受け取る ViewBuilder。
    /// DetailView の閉じるボタンがこのクロージャを直接呼ぶことで、
    /// ThumbnailGridView を経由するフレーム遅延をなくす。
    let content: (_ triggerClose: @escaping () -> Void, _ dismissDragOffset: Binding<CGSize>) -> Content

    @State private var isExpanded = false
    @State private var isContentVisible = false
    @State private var dismissDragOffset: CGSize = .zero
    @State private var dismissMagPeak: Double = 0
    @State private var swipeReleasedOffset: CGSize = .zero
    /// 閉じ開始時点の背景黒の不透明度。閉じ中は
    /// closingStartBackground * (1 - closingProgress) で連続フェードする。
    @State private var closingStartBackground: Double = 0
    @State private var isDismissing = false
    /// 閉じアニメーションを「飛行サムネイル」で行うフラグ。
    /// withAnimation の【外】で立てる（無アニメーションでライブコンテンツを
    /// 即時非表示にし、飛行体を即時表示するため）。
    @State private var isFlightActive = false
    /// DetailView の imageViewport から受け取ったグローバル座標フレーム。
    @State private var capturedImageFrame: CGRect = .zero
    /// 閉じるアニメーション中、マスクを使ってコンテンツを縮小するフラグ。
    @State private var showClosingMask = false
    /// 0 = imageFrame、1 = sourceRect（セル位置）へ補間する閉じ進捗。
    @State private var closingProgress: CGFloat = 0
    /// closeTargetProvider で閉じ開始時に解決した着地矩形・飛行体画像。
    @State private var closeRect: CGRect?
    @State private var closeImage: UIImage?
    /// 着地先を解決済みかどうか。解決後は closeRect が nil でも sourceRect へ
    /// フォールバックしない（古いセルへ飛ぶより中央縮小の方が正しいため）。
    @State private var didResolveCloseTarget = false

    /// 閉じアニメーションの着地矩形。未解決（provider なし）の間は開いた時点の sourceRect。
    private var effectiveCloseRect: CGRect? { didResolveCloseTarget ? closeRect : sourceRect }
    private var effectiveCloseImage: UIImage? { didResolveCloseTarget ? closeImage : flyingImage }

    private let animationDuration: TimeInterval = 0.22

    init(
        sourceRect: CGRect?,
        flyingImage: UIImage? = nil,
        closeTargetProvider: (() -> (rect: CGRect?, image: UIImage?))? = nil,
        onCloseAnimationStarted: (() -> Void)? = nil,
        onCloseAnimationFinished: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ triggerClose: @escaping () -> Void, _ dismissDragOffset: Binding<CGSize>) -> Content
    ) {
        self.sourceRect = sourceRect
        self.flyingImage = flyingImage
        self.closeTargetProvider = closeTargetProvider
        self.onCloseAnimationStarted = onCloseAnimationStarted
        self.onCloseAnimationFinished = onCloseAnimationFinished
        self.content = content
    }

    /// 閉じるボタン / スワイプディスミスから直接呼ばれる。ThumbnailGridView を経由しない。
    private func triggerClose() {
        guard !isDismissing else { return }
        startClosingAnimation()
    }

    var body: some View {
        GeometryReader { coverGeo in
            let coverRect = coverGeo.frame(in: .global)

            ZStack {
                let dismissMag = sqrt(Double(dismissDragOffset.width * dismissDragOffset.width
                                            + dismissDragOffset.height * dismissDragOffset.height))
                // ピーク値を使うことで指を戻しても背景が戻らないようにする
                let effectiveMag = max(dismissMag, dismissMagPeak)
                let dismissProgress = min(max(effectiveMag / 400, 0), 1)
                Color.black
                    // 閉じ中: 閉じ開始時点の不透明度 (closingStartBackground) から
                    // closingProgress 駆動で連続的に 0 へフェードする。
                    // - ボタン閉じ: 1.0 → 0（黒がフェードしながら写真がセルへ飛ぶ）
                    // - 深いスワイプ閉じ: すでに ~0 → 0 のまま
                    // Bool 分岐で値を切り替えると、withAnimation の外で設定した
                    // フラグと中で設定したフラグの transaction 帰属が不定になり
                    // 1 フレームの瞬時透明化（フラッシュ）が起きる。
                    // closingProgress（アニメーション補間される値）だけで駆動すれば
                    // 切替フレームで値が連続するためフラッシュしない。
                    .opacity(showClosingMask
                             ? closingStartBackground * Double(1 - closingProgress)
                             : isExpanded
                                 ? max(0.0, 1.0 - dismissProgress * 1.5)
                                 : 0)
                    .ignoresSafeArea()

                // ブランチ切り替えを廃止し content の View identity を維持する。
                // openingContent / closingContent で if-else 分岐すると SwiftUI が
                // content(triggerClose, $dismissDragOffset) を別 View と見なし、
                // dismissDragOffset のアニメーションが引き継がれず瞬間移動が起きる。
                unifiedContent(coverRect: coverRect)

                // 閉じアニメーション用の飛行サムネイル（常時マウント・通常は透明）。
                // 閉じ開始の同一コミットで挿入すると初期値からの補間が効かないため、
                // View identity を維持したまま opacity で出し入れする。
                flightView(coverRect: coverRect)
            }
            .frame(width: coverRect.width, height: coverRect.height)
            .background(Color.clear)
            .onAppear { startOpenAnimation() }
            .onChange(of: dismissDragOffset) { _, newOffset in
                let mag = sqrt(Double(newOffset.width * newOffset.width + newOffset.height * newOffset.height))
                if mag > dismissMagPeak { dismissMagPeak = mag }
                if newOffset == .zero { dismissMagPeak = 0 }
            }
            .onPreferenceChange(DetailImageViewportFrameKey.self) { frame in
                // isContentVisible でゲートしない。onPreferenceChange は値が変化した
                // ときしか発火せず、viewport のグローバル座標は初回レイアウトで一度
                // 報告されたきり変わらない（scaleEffect / offset はレンダー変換で
                // レイアウト座標に影響しない）。初回は isContentVisible == false
                // (+0.28s まで) のため、ゲートすると capturedImageFrame が永遠に
                // 空のままになり、閉じアニメーションがフォールバック経路に落ちる。
                if !isDismissing, !frame.isEmpty {
                    capturedImageFrame = frame
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
    }

    // MARK: - Unified content（opening + closing を単一 View で処理）
    //
    // SwiftUI は if-else ブランチを異なる View として扱うため、
    // openingContent / closingContent でブランチを切り替えると
    // content(triggerClose, $dismissDragOffset) が別 View として再生成される。
    // その結果、dismissDragOffset のアニメーション状態が引き継がれず
    // スワイプ位置から自然位置への連続アニメーションが壊れる（瞬間移動フラッシュ）。
    //
    // 解決: content を常に同一 View として保ち、modifier の値を
    //        showClosingMask で切り替える。Clip shape も CoverClip 単一型で統一し
    //        型切り替えによる View 再生成を防ぐ。

    @ViewBuilder
    private func unifiedContent(coverRect: CGRect) -> some View {
        // ── Opening 用パラメータ ──────────────────────────────────
        let t = openTransform(coverRect: coverRect)
        let openProgress: CGFloat = isExpanded ? 1 : 0
        let openScale    = t.scale   + (1 - t.scale)   * openProgress
        let openClipW    = t.clipW   + (coverRect.width  - t.clipW)  * openProgress
        let openClipH    = t.clipH   + (coverRect.height - t.clipH)  * openProgress
        let openOffX     = t.offsetX * (1 - openProgress)
        let openOffY     = t.offsetY * (1 - openProgress)

        // ── Closing 用パラメータ ─────────────────────────────────
        let target = effectiveCloseRect ?? CGRect(x: coverRect.midX - 75, y: coverRect.midY - 75,
                                                  width: 150, height: 150)
        let start  = capturedImageFrame.isEmpty ? coverRect : capturedImageFrame
        let sX = coverRect.width  / 2
        let sY = coverRect.height / 2
        let closingScale     = max(min(target.width  / max(start.width,  1),
                                       target.height / max(start.height, 1)), 0.01)
        let currentScale     = 1 + (closingScale - 1) * closingProgress
        let imageMidX  = start.midX  - coverRect.minX
        let imageMidY  = start.midY  - coverRect.minY
        let cellMidX   = target.midX - coverRect.minX
        let cellMidY   = target.midY - coverRect.minY
        let sFinalX    = sX + (imageMidX - sX) * closingScale
        let sFinalY    = sY + (imageMidY - sY) * closingScale
        let releasedX = swipeReleasedOffset.width
        let releasedY = swipeReleasedOffset.height
        let imageLocalRect = CGRect(x: start.minX - coverRect.minX + releasedX,
                                    y: start.minY - coverRect.minY + releasedY,
                                    width: start.width, height: start.height)
        // DetailView 側のドラッグ offset は閉じ終端まで固定する。
        // その分を最終スケール後の画像中心に加味し、外側の移動だけでセル中心へ戻す。
        let releasedFinalX = sFinalX + releasedX * closingScale
        let releasedFinalY = sFinalY + releasedY * closingScale
        let adjustedTargetOffX = cellMidX - releasedFinalX
        let adjustedTargetOffY = cellMidY - releasedFinalY
        let combinedOffX = adjustedTargetOffX * closingProgress
        let combinedOffY = adjustedTargetOffY * closingProgress

        // ── 統合パラメータ ───────────────────────────────────────
        // 飛行サムネイル方式のときはライブコンテンツを動かさない
        //（opacity 0 で即時非表示にし、飛行体に任せる）。
        let contentClosing   = showClosingMask && !isFlightActive
        let effectiveScale   = contentClosing ? currentScale  : openScale
        let effectiveOffX    = contentClosing ? combinedOffX  : openOffX
        let effectiveOffY    = contentClosing ? combinedOffY  : openOffY
        let effectiveOpacity = isFlightActive ? 0.0
            : (showClosingMask ? 1.0 : (sourceRect == nil ? Double(openProgress) : 1.0))
        let isInteractive    = !showClosingMask && isExpanded && !isDismissing

        content(triggerClose, $dismissDragOffset)
            .environment(\.isDetailClosing, showClosingMask || !isContentVisible)
            .frame(width: coverRect.width, height: coverRect.height)
            // CoverClip 単一型: showClosingMask が変わっても型が同じなので View が再生成されない
            //
            // クリップは必ず scaleEffect の【前】に適用する（knowledge/ipad-detail-transition-
            // investigation.md の最重要ポイント）。後に置くとクリップ窓がコンテンツと一緒に
            // 縮小されず、閉じアニメーション中に写真が固定窓から脱出して 1 フレームで
            // 消えたように見える（ドラッグ量が大きいほど顕著）。
            // 前に置けば窓は imageLocalRect でコンテンツ座標に固定され、
            // scaleEffect で写真と窓が一体で縮小・移動する。
            // open 用クリップ寸法は pre-scale 座標系に合わせて openScale で割る。
            .clipShape(CoverClip(
                openW: openClipW / max(openScale, 0.01),
                openH: openClipH / max(openScale, 0.01),
                openCornerRadius: 18 * (1 - openProgress) / max(openScale, 0.01),
                fixedRect: imageLocalRect,
                isClosing: contentClosing))
            .scaleEffect(effectiveScale, anchor: .center)
            .offset(x: effectiveOffX, y: effectiveOffY)
            .opacity(effectiveOpacity)
            // isFlightActive による非表示は即時（無アニメーション）。
            // withAnimation と同一コミットでもフェードが滲まないようローカルに遮断する。
            .animation(nil, value: isFlightActive)
            .allowsHitTesting(isInteractive)
    }

    // MARK: - Flight view（閉じアニメーション用の飛行サムネイル）
    //
    // 写真の実表示矩形（capturedImageFrame 内に aspectFit + ドラッグオフセット）から
    // セル矩形へ、scaledToFill + 角丸 0→6 で補間しながら飛ぶ。
    // 着地時はセルのサムネイル描画（正方形 scaledToFill クロップ・角丸 6）と
    // ピクセル一致するため、セル黒フェードとの継続性が保たれる。

    @ViewBuilder
    private func flightView(coverRect: CGRect) -> some View {
        if let img = effectiveCloseImage, let src = effectiveCloseRect, !capturedImageFrame.isEmpty {
            let viewport = CGRect(x: capturedImageFrame.minX - coverRect.minX,
                                  y: capturedImageFrame.minY - coverRect.minY,
                                  width: capturedImageFrame.width,
                                  height: capturedImageFrame.height)
            // 写真の aspectFit 矩形（UIImage.size は orientation 適用済み）
            let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
            let fitW = min(viewport.width, viewport.height * aspect)
            let fitH = fitW / max(aspect, 0.001)
            // 開始 = 写真の現在表示位置（ドラッグ追従込み）。
            // dismissDragOffset は閉じ中もリセットされないため、
            // ドラッグ中は指に追従し、閉じ開始後は離した位置で固定される。
            let startRect = CGRect(x: viewport.midX - fitW / 2 + dismissDragOffset.width,
                                   y: viewport.midY - fitH / 2 + dismissDragOffset.height,
                                   width: fitW, height: fitH)
            let endRect = CGRect(x: src.minX - coverRect.minX,
                                 y: src.minY - coverRect.minY,
                                 width: src.width, height: src.height)
            let p = closingProgress
            let w = max(startRect.width  + (endRect.width  - startRect.width)  * p, 1)
            let h = max(startRect.height + (endRect.height - startRect.height) * p, 1)
            let cx = startRect.midX + (endRect.midX - startRect.midX) * p
            let cy = startRect.midY + (endRect.midY - startRect.midY) * p
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 6 * p))
                .position(x: cx, y: cy)
                .opacity(isFlightActive ? 1 : 0)
                // 表示切替は即時。フレーム/位置/角丸の補間は closingProgress の
                // withAnimation が担う（常時マウントなので初期値からの補間が効く）。
                .animation(nil, value: isFlightActive)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Animation helpers

    private func startOpenAnimation() {
        isExpanded = false
        isContentVisible = false
        showClosingMask = false
        closingProgress = 0
        capturedImageFrame = .zero
        dismissDragOffset = .zero
        dismissMagPeak = 0
        swipeReleasedOffset = .zero
        closingStartBackground = 0
        isDismissing = false
        isFlightActive = false
        closeRect = nil
        closeImage = nil
        didResolveCloseTarget = false

        // onAppear と同じターンで開始し、初期状態だけが描画されるフレームを作らない。
        // 背景は isExpanded == false の間 opacity 0 のため透明から立ち上がる。
        withAnimation(.spring(response: animationDuration, dampingFraction: 0.86)) {
            isExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            withAnimation(.easeOut(duration: 0.15)) {
                isContentVisible = true
            }
        }
    }

    private func startClosingAnimation() {
        // 着地先を閉じる瞬間に解決する（withAnimation の外 = 値の差し替えは即時。
        // 飛行体ビューは常時マウントなので値が変わっても identity は保たれ、
        // 直後の closingProgress 補間が新しい着地先へ正しく効く）。
        if let provider = closeTargetProvider {
            let resolved = provider()
            closeRect = resolved.rect
            closeImage = resolved.image
            didResolveCloseTarget = true
        }
        let releasedOffset = dismissDragOffset
        swipeReleasedOffset = releasedOffset
        // 現在表示中の背景不透明度を閉じフェードの始点として固定する
        //（ドラッグ中の式と同じ計算。ここから 1 - closingProgress で 0 へ）。
        let mag = sqrt(Double(releasedOffset.width * releasedOffset.width
                             + releasedOffset.height * releasedOffset.height))
        let progress = min(max(max(mag, dismissMagPeak) / 400, 0), 1)
        closingStartBackground = max(0.0, 1.0 - progress * 1.5)
        // 飛行サムネイルが使える場合はそちらで閉じる（withAnimation の外で
        // フラグを立てる = ライブコンテンツの非表示と飛行体の表示は即時）。
        if effectiveCloseImage != nil, effectiveCloseRect != nil, !capturedImageFrame.isEmpty {
            isFlightActive = true
        }
        withAnimation(.easeOut(duration: animationDuration)) {
            isDismissing = true
            isContentVisible = false
            showClosingMask = true
            closingProgress = 1
        }
        onCloseAnimationStarted?()
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration + 0.05) {
            onCloseAnimationFinished()
        }
    }

    private func openTransform(coverRect: CGRect)
        -> (scale: CGFloat, clipW: CGFloat, clipH: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        guard let src = sourceRect, !src.isNull, !src.isEmpty,
              coverRect.width > 0, coverRect.height > 0 else {
            return (0.96, coverRect.width, coverRect.height, 0, 0)
        }
        let scaleX = src.width / coverRect.width
        let scaleY = src.height / coverRect.height
        return (
            max(max(scaleX, scaleY), 0.01),
            src.width, src.height,
            src.midX - coverRect.midX,
            src.midY - coverRect.midY
        )
    }
}

// MARK: - CoverClip

/// Opening / Closing 両フェーズを単一型で扱うクリップ Shape。
/// フェーズごとに別の Shape 型へ切り替えると content View が再生成されるため、
/// 単一型に統合して identity を維持しアニメーションの連続性を保つ。
private struct CoverClip: Shape {
    var openW: CGFloat
    var openH: CGFloat
    var openCornerRadius: CGFloat
    var fixedRect: CGRect
    var isClosing: Bool

    func path(in rect: CGRect) -> Path {
        if isClosing {
            return Path(fixedRect)
        } else {
            let r = CGRect(
                x: (rect.width  - openW) / 2,
                y: (rect.height - openH) / 2,
                width: openW, height: openH
            )
            return Path(roundedRect: r, cornerRadius: openCornerRadius, style: .continuous)
        }
    }
}

// MARK: - Environment: isDetailClosing

private struct IsDetailClosingKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue = false
}

extension EnvironmentValues {
    var isDetailClosing: Bool {
        get { self[IsDetailClosingKey.self] }
        set { self[IsDetailClosingKey.self] = newValue }
    }
}
