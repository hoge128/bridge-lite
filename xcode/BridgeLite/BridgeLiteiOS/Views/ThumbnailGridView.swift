import SwiftUI
import UIKit

struct ThumbnailGridView: View {
    @State var scanStore: ScanStore
    @State var ratingStore: RatingStore
    @State private var selectedGroup: ShotGroup?
    @State private var selectedFilterCategory: FilterCategory?
    @State private var showFolderPicker = false
    @State private var showSettings = false
    @State private var columnCount = 3

    private var gridSpacing: CGFloat { columnCount == 3 ? 1 : 4 }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if scanStore.isScanning {
                    VStack(spacing: 8) {
                        ProgressView()
                        if scanStore.scanTotalCount > 0 {
                            Text("\(scanStore.scanLoadedCount) / \(scanStore.scanTotalCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Scanning…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if scanStore.groups.isEmpty {
                    emptyState
                } else {
                    grid
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
                    thumbnails: scanStore.thumbnails,
                    exifs: scanStore.exifs,
                    ratings: Binding(
                        get: { ratingStore.ratings },
                        set: { ratingStore.ratings = $0 }
                    ),
                    db: scanStore.db,
                    jpgWriteMode: scanStore.jpgWriteMode
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
            .onChange(of: scanStore.folderURL) { _, url in
                if url == nil { showFolderPicker = true }
            }
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let n = CGFloat(columnCount)
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
                            kind: scanStore.representativeKind(for: group, xmps: ratingStore.ratings),
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
        // Keep this container background-free; material in a safeAreaInset can fill
        // the bottom safe area. Glass/material belongs on the shaped child views.
        VStack(spacing: 0) {
            if let category = selectedFilterCategory {
                FilterOptionsPanelView(
                    category: category,
                    scanStore: scanStore,
                    ratings: ratingStore.ratings
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            FilterBarView(selectedCategory: $selectedFilterCategory, scanStore: scanStore)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .animation(.easeInOut(duration: 0.2), value: selectedFilterCategory)
    }
}
