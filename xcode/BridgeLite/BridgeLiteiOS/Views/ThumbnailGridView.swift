import SwiftUI
import UIKit

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
    @State private var selectedSourceRect: CGRect?
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

    /// iPad は fullScreenCover、iPhone は sheet。
    /// fullScreenCover は UIKit モーダル presentation のため、
    /// zoom 遷移の座標ズレバグが構造的に発生しない。
    @ViewBuilder
    private var detailPresenter: some View {
        if isPad {
            NavigationStack { mainContent }
                .fullScreenCover(item: $selectedGroup) { group in
                    ExpandFromCellFullScreenCover(
                        sourceRect: selectedSourceRect,
                        onCloseAnimationFinished: finishDetailDismissal
                    ) { triggerClose in
                        NavigationStack {
                            detailView(group: group, onClose: triggerClose)
                        }
                    }
                    .interactiveDismissDisabled(true)
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

    private func detailView(group: ShotGroup, onClose: @escaping () -> Void) -> some View {
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
            onClose: onClose
        )
    }

    private func presentDetail(group: ShotGroup, sourceRect: CGRect?) {
        selectedSourceRect = sourceRect
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        UIView.performWithoutAnimation {
            withTransaction(transaction) {
                selectedGroup = group
            }
        }
    }

    private func finishDetailDismissal() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        UIView.performWithoutAnimation {
            withTransaction(transaction) {
                selectedGroup = nil
            }
        }
        selectedSourceRect = nil
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
    let onCloseAnimationFinished: () -> Void
    /// content は triggerClose クロージャを受け取る ViewBuilder。
    /// DetailView の閉じるボタンがこのクロージャを直接呼ぶことで、
    /// ThumbnailGridView を経由するフレーム遅延をなくす。
    let content: (_ triggerClose: @escaping () -> Void) -> Content

    @State private var isExpanded = false
    @State private var isContentVisible = false
    /// DetailView の imageViewport から受け取ったグローバル座標フレーム。
    @State private var capturedImageFrame: CGRect = .zero
    /// 閉じるアニメーション中、マスクを使ってコンテンツを縮小するフラグ。
    @State private var showClosingMask = false
    /// 0 = imageFrame、1 = sourceRect（セル位置）へ補間する閉じ進捗。
    @State private var closingProgress: CGFloat = 0

    private let animationDuration: TimeInterval = 0.22

    init(
        sourceRect: CGRect?,
        onCloseAnimationFinished: @escaping () -> Void,
        @ViewBuilder content: @escaping (_ triggerClose: @escaping () -> Void) -> Content
    ) {
        self.sourceRect = sourceRect
        self.onCloseAnimationFinished = onCloseAnimationFinished
        self.content = content
    }

    /// 閉じるボタンから直接呼ばれる。ThumbnailGridView を経由しないので即座に発火する。
    private func triggerClose() {
        guard !showClosingMask else { return }
        isContentVisible = false
        startClosingAnimation()
    }

    var body: some View {
        GeometryReader { coverGeo in
            let coverRect = coverGeo.frame(in: .global)

            ZStack {
                Color.black
                    .opacity(showClosingMask ? Double(1 - closingProgress) : (isExpanded ? 1 : 0))
                    .ignoresSafeArea()

                if !showClosingMask {
                    // 開くアニメーション
                    openingContent(coverRect: coverRect)
                } else {
                    // 閉じるアニメーション：コンテンツにマスクを当てて縮小
                    // サムネイルの画像種別（埋め込み・デコード済み）に依存しない
                    closingContent(coverRect: coverRect)
                }
            }
            .frame(width: coverRect.width, height: coverRect.height)
            .background(Color.clear)
            .onAppear { startOpenAnimation() }
            .onPreferenceChange(DetailImageViewportFrameKey.self) { frame in
                if isExpanded, isContentVisible, !frame.isEmpty {
                    capturedImageFrame = frame
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
    }

    // MARK: - Open animation content

    @ViewBuilder
    private func openingContent(coverRect: CGRect) -> some View {
        let t = openTransform(coverRect: coverRect)
        let progress: CGFloat = isExpanded ? 1 : 0
        let scale = t.scale + (1 - t.scale) * progress
        let clipW = t.clipW + (coverRect.width  - t.clipW) * progress
        let clipH = t.clipH + (coverRect.height - t.clipH) * progress
        let offX  = t.offsetX * (1 - progress)
        let offY  = t.offsetY * (1 - progress)

        content(triggerClose)
            .environment(\.isDetailClosing, !isContentVisible)
            .frame(width: coverRect.width, height: coverRect.height)
            .scaleEffect(scale, anchor: .center)
            .clipShape(ZoomClipShape(width: clipW, height: clipH,
                                     cornerRadius: 18 * (1 - progress)))
            .offset(x: offX, y: offY)
            .opacity(sourceRect == nil ? Double(progress) : 1)
            .allowsHitTesting(isExpanded)
    }

    // MARK: - Close animation content（scale+offset 方式）
    // Photos app と同様に「コンテンツ自体を縮小・移動」させることで、
    // 画像が自分でセルへ飛んでいく自然な動きを実現する。
    // マスク方式と異なり、静止コンテンツの上を窓が動く「スライド窓」効果が起きない。

    @ViewBuilder
    private func closingContent(coverRect: CGRect) -> some View {
        let target = sourceRect ?? CGRect(x: coverRect.midX - 75, y: coverRect.midY - 75,
                                          width: 150, height: 150)
        // capturedImageFrame が未取得の場合はフルスクリーンから縮小
        let start = capturedImageFrame.isEmpty ? coverRect : capturedImageFrame

        let screenCenterX = coverRect.width  / 2
        let screenCenterY = coverRect.height / 2

        // imageViewport がセルに収まる均一スケール
        let closingScale = max(min(target.width  / max(start.width,  1),
                                   target.height / max(start.height, 1)), 0.01)
        let currentScale = 1 + (closingScale - 1) * closingProgress

        // imageFrame 中心のローカル座標
        let imageMidX = start.midX  - coverRect.minX
        let imageMidY = start.midY  - coverRect.minY
        let cellMidX  = target.midX - coverRect.minX
        let cellMidY  = target.midY - coverRect.minY

        // 最終スケール後に imageFrame 中心がどこに来るか（スクリーン中央からのスケール）
        let scaledFinalMidX = screenCenterX + (imageMidX - screenCenterX) * closingScale
        let scaledFinalMidY = screenCenterY + (imageMidY - screenCenterY) * closingScale

        // progress=1 でセル中心に一致させるオフセット
        let targetOffX = cellMidX - scaledFinalMidX
        let targetOffY = cellMidY - scaledFinalMidY

        // imageViewport の領域だけを先にクリップする。
        // これにより info パネルの透明エリアが黒背景を透かして見えるのを防ぐ。
        let imageLocalRect = CGRect(x: start.minX - coverRect.minX,
                                    y: start.minY - coverRect.minY,
                                    width:  start.width,
                                    height: start.height)
        content(triggerClose)
            .environment(\.isDetailClosing, true)
            .frame(width: coverRect.width, height: coverRect.height)
            .clipShape(FixedRectClip(rect: imageLocalRect))
            .scaleEffect(currentScale, anchor: .center)
            .offset(x: targetOffX * closingProgress, y: targetOffY * closingProgress)
            .allowsHitTesting(false)
    }

    // MARK: - Animation helpers

    private func startOpenAnimation() {
        isExpanded = false
        isContentVisible = false
        showClosingMask = false
        closingProgress = 0
        capturedImageFrame = .zero

        DispatchQueue.main.async {
            withAnimation(.spring(response: animationDuration, dampingFraction: 0.86)) {
                isExpanded = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                withAnimation(.easeOut(duration: 0.15)) {
                    isContentVisible = true
                }
            }
        }
    }

    private func startClosingAnimation() {
        closingProgress = 0
        showClosingMask = true

        withAnimation(.easeIn(duration: animationDuration)) {
            closingProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
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
