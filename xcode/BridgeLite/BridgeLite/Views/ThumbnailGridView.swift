import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isDropTargeted = false
    @State private var lastTap: (id: UInt64, time: Date)?
    private var cellSize: CGFloat { store.settings.thumbnailSize }

    private func handleTap(id: UInt64) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if let last = lastTap,
           last.id == id,
           Date().timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
            store.selectEntry(id)
            store.compareAnchorID = id
            store.compareMode = true
            lastTap = nil
            return
        }
        lastTap = (id: id, time: Date())

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
                } else {
                    strictGrid
                }

                if isDropTargeted {
                    Color.blue.opacity(0.15)
                        .allowsHitTesting(false)
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
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
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)
            Text("Drop a folder to open")
                .font(.title3)
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(store.visibleIDs, id: \.self) { id in
                        if let entry = store.entries[id] {
                            ThumbnailCellView(entry: entry)
                                .onTapGesture { handleTap(id: id) }
                        }
                    }
                }
                .padding(8)
            }
            .onAppear { store.gridColumnCount = cols }
            .onChange(of: cols) { _, newCols in store.gridColumnCount = newCols }
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
                                        .onTapGesture { handleTap(id: id) }
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
        }
        .id(store.scanGeneration)
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
