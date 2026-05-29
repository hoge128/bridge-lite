import SwiftUI
import UIKit

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
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

    private static let shareWarningThreshold = 20
    private let gridSpacing: CGFloat = 1
    private let columnCount = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    private var shareNeedsWarning: Bool {
        scanStore.filteredGroups(ratings: ratingStore.ratings).count > Self.shareWarningThreshold
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
        .sheet(item: $selectedGroup) { group in
            DetailView(
                groups: scanStore.filteredGroups(ratings: ratingStore.ratings),
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

    var body: some View {
        NavigationStack {
            mainContent
        }
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
    }

    private var grid: some View {
        GeometryReader { geo in
            let n = CGFloat(columnCount)
            let cellSize = (geo.size.width - gridSpacing * (n + 1)) / n

            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(scanStore.filteredGroups(ratings: ratingStore.ratings)) { group in
                        ThumbnailCellView(
                            group: group,
                            entries: scanStore.entries,
                            thumbnails: scanStore.thumbnails,
                            ratings: ratingStore.ratings,
                            exifs: scanStore.exifs,
                            kind: scanStore.representativeKind(for: group, xmps: ratingStore.ratings),
                            squareCellSize: cellSize,
                            isSelected: selectedGroup?.id == group.id
                        ) {
                            scanStore.resetAutoReleaseTimer()
                            selectedGroup = group
                        }
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
                let groups = scanStore.filteredGroups(ratings: ratingStore.ratings)
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
