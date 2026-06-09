import SwiftUI
import UIKit

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
    @State private var selectedSourceRect: CGRect?
    @State private var selectedCellDimOpacity: Double = 0
    @State private var coverOpacity: Double = 1.0
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
                        onCloseAnimationStarted: {
                            withAnimation(.easeIn(duration: 0.22)) {
                                selectedCellDimOpacity = 0
                            }
                        },
                        onCloseAnimationFinished: finishDetailDismissal
                    ) { triggerClose, dismissDragOffset in
                        NavigationStack {
                            detailView(group: group, onClose: triggerClose, dismissDragOffset: dismissDragOffset)
                        }
                    }
                    .opacity(coverOpacity)
                    .ignoresSafeArea()
                }
            }
        } else {
            NavigationStack { mainContent }
                .sheet(item: $selectedGroup) { group in
                    NavigationStack {
                        detailView(group: group) { selectedGroup = nil }
                    }
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
            onClose: onClose
        )
    }

    private func presentDetail(group: ShotGroup, sourceRect: CGRect?) {
        selectedSourceRect = sourceRect
        selectedCellDimOpacity = 1.0
        coverOpacity = 1.0
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
        selectedCellDimOpacity = 0
        selectedSourceRect = nil
        coverOpacity = 1.0
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
                            onTap: {
                                scanStore.resetAutoReleaseTimer()
                                // iPhone のみ: iPad は simultaneousGesture で処理。
                                if !isPad { selectedGroup = group }
                            },
                            onDelete: { groupPendingDelete = group }
                        )
                        .overlay {
                            // 現在開いているセルを黒くし、閉じるアニメーションで徐々に明転する
                            if group.id == selectedGroup?.id, selectedCellDimOpacity > 0 {
                                Color.black
                                    .opacity(selectedCellDimOpacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .id(group.id)
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
                .padding(.horizontal, 16)
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
    @State private var isSwipeDismiss: Bool = false
    @State private var isDismissing = false
    /// DetailView の imageViewport から受け取ったグローバル座標フレーム。
    @State private var capturedImageFrame: CGRect = .zero
    /// 閉じるアニメーション中、マスクを使ってコンテンツを縮小するフラグ。
    @State private var showClosingMask = false
    /// 0 = imageFrame、1 = sourceRect（セル位置）へ補間する閉じ進捗。
    @State private var closingProgress: CGFloat = 0

    private let animationDuration: TimeInterval = 0.22

    init(
        sourceRect: CGRect?,
        onCloseAnimationStarted: (() -> Void)? = nil,
        onCloseAnimationFinished: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ triggerClose: @escaping () -> Void, _ dismissDragOffset: Binding<CGSize>) -> Content
    ) {
        self.sourceRect = sourceRect
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
                    .opacity(showClosingMask
                             // ボタン閉じ: 1.0 → 0 へフェード
                             // スワイプ閉じ: すでに透明。swipeReleasedOffset が .zero でも
                             //   開始位置に戻して離した場合は isSwipeDismiss が true になるので
                             //   フラッシュを確実に防げる。
                             ? (isSwipeDismiss ? 0.0 : Double(1 - closingProgress))
                             : isExpanded
                                 // 完全透明にしない（最低 0.3）。
                                 // 0 にすると閉じアニメーション開始時の
                                 // 背景ジャンプが視覚的に目立つため。
                                 ? max(0.5, 1.0 - dismissProgress * 1.5)
                                 : 0)
                    .ignoresSafeArea()

                // ブランチ切り替えを廃止し content の View identity を維持する。
                // openingContent / closingContent で if-else 分岐すると SwiftUI が
                // content(triggerClose, $dismissDragOffset) を別 View と見なし、
                // dismissDragOffset のアニメーションが引き継がれず瞬間移動が起きる。
                unifiedContent(coverRect: coverRect)
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
                if isExpanded, isContentVisible, !frame.isEmpty {
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
        let target = sourceRect ?? CGRect(x: coverRect.midX - 75, y: coverRect.midY - 75,
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
        let effectiveScale   = showClosingMask ? currentScale  : openScale
        let effectiveOffX    = showClosingMask ? combinedOffX  : openOffX
        let effectiveOffY    = showClosingMask ? combinedOffY  : openOffY
        let effectiveOpacity = showClosingMask ? 1.0 : (sourceRect == nil ? Double(openProgress) : 1.0)
        let isInteractive    = !showClosingMask && isExpanded && !isDismissing

        content(triggerClose, $dismissDragOffset)
            .environment(\.isDetailClosing, showClosingMask || !isContentVisible)
            .frame(width: coverRect.width, height: coverRect.height)
            .scaleEffect(effectiveScale, anchor: .center)
            // CoverClip 単一型: showClosingMask が変わっても型が同じなので View が再生成されない
            .clipShape(CoverClip(
                openW: openClipW, openH: openClipH,
                openCornerRadius: 18 * (1 - openProgress),
                fixedRect: imageLocalRect,
                isClosing: showClosingMask))
            .offset(x: effectiveOffX, y: effectiveOffY)
            .opacity(effectiveOpacity)
            .allowsHitTesting(isInteractive)
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
        isSwipeDismiss = false
        isDismissing = false

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
        let releasedOffset = dismissDragOffset
        let wasSwipeDismiss = dismissMagPeak > 0
        // この2値は showClosingMask == false の間は描画に影響しないため、
        // アニメーション開始値として先に固定する。
        swipeReleasedOffset = releasedOffset
        isSwipeDismiss = wasSwipeDismiss
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

// MARK: - ZoomClipShape

/// Opening / Closing 両フェーズを単一型で扱うクリップ Shape。
/// ZoomClipShape（opening）と FixedRectClip（closing）を型切り替えなしで表現し、
/// content View の identity を維持してアニメーションの連続性を保つ。
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

/// アニメーション中にクリップ矩形をセルサイズ→フルスクリーンへ補間するカスタム Shape。
/// 親ビューの中央に配置され、均一スケールのコンテンツから縦横比を保ったまま切り出す。
private struct ZoomClipShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), cornerRadius) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = CGRect(
            x: (rect.width  - width)  / 2,
            y: (rect.height - height) / 2,
            width: width,
            height: height
        )
        return Path(roundedRect: r, cornerRadius: cornerRadius, style: .continuous)
    }
}

/// 閉じるアニメーション用クリップ。
/// コンテンツ座標系内の固定矩形でクリップし、
/// info パネル透明エリアが黒背景を透かして見えるのを防ぐ。
private struct FixedRectClip: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
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
