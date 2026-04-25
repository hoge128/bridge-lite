import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false

    var isSelected: Bool { store.selectedID == entry.id }
    var thumbnail: CGImage? { store.thumbnailImages[entry.id] }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ThumbnailImageView(cgImage: thumbnail)
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if let members = store.shotGroups[entry.shotId], members.count > 1 {
                    Text(entry.isRaw ? "R" : "J")
                        .font(.caption2.bold())
                        .padding(3)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.4) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )

            Text(entry.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180)
        }
        .onHover { isHovered = $0 }
    }
}

struct ThumbnailImageView: View {
    let cgImage: CGImage?

    var body: some View {
        if let img = cgImage {
            Image(decorative: img, scale: 1.0)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                )
        }
    }
}
