import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false

    private var isSelected: Bool { store.selectedID == entry.id }
    private var thumbnail: CGImage? { store.thumbnailImages[entry.id] }
    private var xmp: XmpData? { store.xmpData[entry.id] }
    private var groupSize: Int { store.shotGroups[entry.shotId]?.count ?? 1 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                ThumbnailImageView(cgImage: thumbnail)
                    .frame(width: 180, height: 180)

                // Label color strip + rating pill stacked at bottom (inside clip)
                VStack(spacing: 0) {
                    Spacer()
                    if let rating = xmp?.rating, rating > 0 {
                        HStack {
                            Text(String(repeating: "★", count: rating))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                                .padding(.leading, 4)
                                .padding(.bottom, 3)
                            Spacer()
                        }
                    }
                    if let label = xmp?.label {
                        label.color.opacity(0.85).frame(height: 5)
                    }
                }
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Flag icon — top-left (outside clip so it's fully visible)
            .overlay(alignment: .topLeading) {
                if let flag = xmp?.flag {
                    Image(systemName: flag == .pick ? "flag.fill" : "xmark.circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(flag == .pick ? Color.white : Color.red)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .padding(5)
                }
            }
            // Variant badge — top-right (only when group has multiple members)
            .overlay(alignment: .topTrailing) {
                if groupSize > 1 {
                    variantBadge.padding(4)
                }
            }
            // Selection / hover stroke
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.4) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            }

            Text(entry.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180)
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var variantBadge: some View {
        let exif = store.exifData[entry.id]
        let isDev = (xmp?.developed == true) || (exif?.isDeveloped == true)
        let text = isDev ? "DEV" : (entry.isRaw ? "R" : "J")
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(isDev ? Color.white : Color.primary)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                if isDev {
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.8))
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.ultraThinMaterial)
                }
            }
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
