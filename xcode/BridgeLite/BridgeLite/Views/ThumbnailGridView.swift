import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    @State private var isDropTargeted = false
    private var cellSize: CGFloat { store.settings.thumbnailSize }

    private func handleTap(id: UInt64) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            store.toggleSelect(id)
        } else if flags.contains(.shift) {
            store.rangeSelect(to: id)
        } else {
            store.selectEntry(id)
        }
    }

    private func handleDoubleTap(id: UInt64) {
        store.selectEntry(id)
        store.compareAnchorID = id
        store.compareMode = true
    }

    var body: some View {
        ZStack {
            if store.currentDirectoryURL == nil {
                emptyStateContent
            } else if store.settings.gridMode == .dense {
                denseGrid
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
                Task { await store.openDirectory(url) }
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)
            Text("フォルダをドロップして開く")
                .font(.title3)
                .foregroundStyle(isDropTargeted ? Color.blue : Color.secondary)
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
                            ThumbnailCellView(entry: entry, isSelected: store.selectedIDs.contains(id))
                                .simultaneousGesture(TapGesture(count: 2).onEnded { handleDoubleTap(id: id) })
                                .onTapGesture { handleTap(id: id) }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Dense grid (justified flow layout)

    private var denseGrid: some View {
        ScrollView {
            JustifiedFlowLayout(targetRowHeight: cellSize, spacing: 4) {
                ForEach(store.visibleIDs, id: \.self) { id in
                    if let entry = store.entries[id] {
                        ThumbnailCellView(entry: entry, isSelected: store.selectedIDs.contains(id))
                            .layoutValue(key: AspectRatioKey.self, value: aspectRatio(for: id))
                            .simultaneousGesture(TapGesture(count: 2).onEnded { handleDoubleTap(id: id) })
                            .onTapGesture { handleTap(id: id) }
                    }
                }
            }
            .padding(8)
        }
    }

    private func aspectRatio(for id: UInt64) -> CGFloat {
        if let exif = store.exifData[id], let w = exif.width, let h = exif.height, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        if let img = store.thumbnailImages[id], img.height > 0 {
            return CGFloat(img.width) / CGFloat(img.height)
        }
        return 1.5
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

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard firstFolderURL(from: sender) != nil else { return [] }
            DispatchQueue.main.async { self.onTargetChanged?(true) }
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            DispatchQueue.main.async { self.onTargetChanged?(false) }
            guard let url = firstFolderURL(from: sender) else { return false }
            DispatchQueue.main.async { self.onDropURL?(url) }
            return true
        }
    }
}

// MARK: - Justified flow layout

struct AspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1.5
}

struct JustifiedFlowLayout: Layout {
    var targetRowHeight: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 800
        let rows = buildRows(subviews: subviews, containerWidth: width)
        let height = rows.map(\.height).reduce(0, +)
            + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let rows = buildRows(subviews: subviews, containerWidth: bounds.width)
        var y = bounds.minY
        var idx = 0
        for row in rows {
            var x = bounds.minX
            for width in row.widths {
                subviews[idx].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: row.height)
                )
                x += width + spacing
                idx += 1
            }
            y += row.height + spacing
        }
    }

    // MARK: - Row packing

    private struct Row {
        var widths: [CGFloat]
        var height: CGFloat
    }

    private func buildRows(subviews: Subviews, containerWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var currentAspects: [CGFloat] = []

        for subview in subviews {
            currentAspects.append(subview[AspectRatioKey.self])
            let naturalWidth = naturalRowWidth(aspects: currentAspects)
            if naturalWidth >= containerWidth {
                rows.append(scaleRow(aspects: currentAspects, containerWidth: containerWidth))
                currentAspects = []
            }
        }

        if !currentAspects.isEmpty {
            let naturalWidth = naturalRowWidth(aspects: currentAspects)
            if naturalWidth >= containerWidth * 0.6 {
                rows.append(scaleRow(aspects: currentAspects, containerWidth: containerWidth))
            } else {
                let widths = currentAspects.map { $0 * targetRowHeight }
                rows.append(Row(widths: widths, height: targetRowHeight))
            }
        }
        return rows
    }

    private func naturalRowWidth(aspects: [CGFloat]) -> CGFloat {
        aspects.map { $0 * targetRowHeight }.reduce(0, +)
            + spacing * CGFloat(max(0, aspects.count - 1))
    }

    private func scaleRow(aspects: [CGFloat], containerWidth: CGFloat) -> Row {
        let natural = naturalRowWidth(aspects: aspects)
        let scale = min(containerWidth / max(natural, 1), 2.0)
        let height = targetRowHeight * scale
        let widths = aspects.map { ($0 * targetRowHeight) * scale }
        return Row(widths: widths, height: height)
    }
}
