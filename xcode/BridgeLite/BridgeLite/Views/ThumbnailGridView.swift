import SwiftUI

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    private let cellSize: CGFloat = 180

    var body: some View {
        if store.settings.gridMode == .dense {
            denseGrid
        } else {
            strictGrid
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
                                .onTapGesture { store.selectEntry(id) }
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
                        ThumbnailCellView(entry: entry)
                            .layoutValue(key: AspectRatioKey.self, value: aspectRatio(for: id))
                            .onTapGesture { store.selectEntry(id) }
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
