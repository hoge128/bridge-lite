import SwiftUI

struct ThumbnailCellView: View {
    let group: ShotGroup
    let entries: [UInt64: PhotoEntry]
    let thumbnails: [UInt64: Data]
    let ratings: [UInt64: XmpData]
    let isSelected: Bool
    let onTap: () -> Void

    private var representative: PhotoEntry? {
        group.representativeID.flatMap { entries[$0] }
    }

    private var thumbnailData: Data? {
        group.representativeID.flatMap { thumbnails[$0] }
    }

    private var xmp: XmpData? {
        group.representativeID.flatMap { ratings[$0] }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                thumbnailImage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                if let xmp {
                    overlayBadge(xmp: xmp)
                }

                if group.memberIDs.count > 1 {
                    groupBadge
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let data = thumbnailData,
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private func overlayBadge(xmp: XmpData) -> some View {
        HStack(spacing: 2) {
            if let label = xmp.label {
                Circle()
                    .fill(label.color)
                    .frame(width: 8, height: 8)
            }
            if let rating = xmp.rating, rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            }
        }
        .padding(4)
    }

    private var groupBadge: some View {
        Text("\(group.memberIDs.count)")
            .font(.caption2.bold())
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}
