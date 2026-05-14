import SwiftUI

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
    @State private var showFilter = false
    @State private var showExportAll = false
    @State private var exportURLs: [URL] = []
    @State private var showFolderPicker = false
    @State private var columnCount = 3

    private var gridSpacing: CGFloat { columnCount == 3 ? 1 : 4 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if scanStore.isScanning {
                    ProgressView("スキャン中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scanStore.groups.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(scanStore.folderURL?.lastPathComponent ?? "BridgeLite")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavigationBar()
            .toolbar { toolbar }
            .sheet(item: $selectedGroup) { group in
                DetailView(
                    group: group,
                    entries: scanStore.entries,
                    thumbnails: scanStore.thumbnails,
                    ratings: Binding(
                        get: { ratingStore.ratings },
                        set: { ratingStore.ratings = $0 }
                    ),
                    db: scanStore.db
                )
            }
            .sheet(isPresented: $showFilter) {
                FilterSheetView(
                    minRating: $scanStore.filterMinRating,
                    filterLabel: $scanStore.filterLabel
                ) { showFilter = false }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showExportAll) {
                ExportSheet(urls: exportURLs) { showExportAll = false }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    showFolderPicker = false
                    scanStore.scan(url: url)
                }
            }
            .onChange(of: scanStore.entries) { _, newEntries in
                let all = Array(newEntries.values)
                Task { await ratingStore.loadAll(entries: all) }
            }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let n = CGFloat(columnCount)
            // セル幅を確定：パディング 2 点 × 2 辺 + 間隔 × (列数-1) を除いた幅を等分
            let cellSize: CGFloat = columnCount == 3
                ? (geo.size.width - gridSpacing * 2 - gridSpacing * (n - 1)) / n
                : 0

            ScrollView {
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(scanStore.filteredGroups(ratings: ratingStore.ratings)) { group in
                        ThumbnailCellView(
                            group: group,
                            entries: scanStore.entries,
                            thumbnails: scanStore.thumbnails,
                            ratings: ratingStore.ratings,
                            exifs: scanStore.exifs,
                            squareCellSize: columnCount == 3 ? cellSize : nil,
                            isSelected: selectedGroup?.id == group.id
                        ) {
                            selectedGroup = group
                        }
                    }
                }
                .padding(gridSpacing)
            }
            .gesture(
                MagnificationGesture()
                    .onEnded { scale in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            columnCount = scale < 1.0 ? 3 : 2
                        }
                    }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("写真が見つかりませんでした")
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
            Button {
                exportURLs = ExportService.urlsForGroups(
                    scanStore.filteredGroups(ratings: ratingStore.ratings),
                    entries: scanStore.entries
                )
                showExportAll = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(scanStore.groups.isEmpty)

            Button {
                if isFiltering {
                    scanStore.filterMinRating = nil
                    scanStore.filterLabel = nil
                } else {
                    showFilter = true
                }
            } label: {
                Image(systemName: isFiltering
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(isFiltering ? Color.accentColor : Color.primary)
            }
        }
    }

    private var isFiltering: Bool {
        scanStore.filterMinRating != nil || scanStore.filterLabel != nil
    }
}
