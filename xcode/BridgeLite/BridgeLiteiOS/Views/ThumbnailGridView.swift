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

    private let gridSpacing: CGFloat = 1
    private let columnCount = 3

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    var body: some View {
        NavigationStack {
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
                    VStack(spacing: 0) {
                        if scanStore.isScanning {
                            scanProgressBanner
                        }
                        grid
                    }
                    .animation(.easeInOut(duration: 0.2), value: scanStore.isScanning)
                }

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
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheetView(scanStore: scanStore) { showSettings = false }
            }
            .onChange(of: scanStore.entries) { _, newEntries in
                let all = Array(newEntries.values)
                Task { await ratingStore.loadAll(entries: all, jpgWriteMode: scanStore.jpgWriteMode) }
            }
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
        }
    }

    private var scanProgressBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Group {
                if scanStore.scanLoadedCount < scanStore.scanTotalCount || scanStore.exifIndexTotal == 0 {
                    // サムネイル読み込みフェーズ
                    if scanStore.scanTotalCount > 0 {
                        Text(String(format: String(localized: "Loading %d / %d"),
                                    scanStore.scanLoadedCount, scanStore.scanTotalCount))
                    } else {
                        Text(String(localized: "Scanning…"))
                    }
                } else {
                    // EXIF 索引フェーズ（サムネイル 全件完了後）
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
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .shimmer()
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
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
                // 先頭グループのサムネイルをプレビューとして渡す
                var preview: UIImage? = nil
                if let firstGroup = groups.first,
                   let repID = firstGroup.representativeID,
                   let data = scanStore.thumbnails[repID] {
                    preview = UIImage(data: data)
                }
                presentActivityController(urls: urls, preview: preview, count: urls.count)
            } label: {
                Image(systemName: "square.and.arrow.up")
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
