import SwiftUI

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    private let cellSize: CGFloat = 180

    var body: some View {
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
}
