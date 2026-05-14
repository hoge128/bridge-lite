import SwiftUI

struct ThumbnailCellView: View {
    let group: ShotGroup
    let entries: [UInt64: PhotoEntry]
    let thumbnails: [UInt64: Data]
    let ratings: [UInt64: XmpData]
    let exifs: [UInt64: ExifData]
    let kind: PhotoKind
    /// nil = 2列モード（自然アスペクト比）、非 nil = 3列モード（正方形、値はセル幅）
    let squareCellSize: CGFloat?
    let isSelected: Bool
    let onTap: () -> Void

    private var representativeID: UInt64? { group.representativeID }
    private var thumbnailData: Data? { representativeID.flatMap { thumbnails[$0] } }
    private var xmp: XmpData? { representativeID.flatMap { ratings[$0] } }

    var body: some View {
        Button(action: onTap) {
            cellContent
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cellContent: some View {
        if let size = squareCellSize {
            // 正方形: frame で明示的にサイズを確定してから scaledToFill でクロップ
            ZStack(alignment: .bottomLeading) {
                squareThumbnail(size: size)
                colorLabelStrip
                overlayBadges
            }
            .frame(width: size, height: size)
            .clipped()
            .overlay(selectionBorder(cornerRadius: 0))
        } else {
            // 自然アスペクト比
            ZStack(alignment: .bottomLeading) {
                fitThumbnail
                colorLabelStrip
                overlayBadges
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(selectionBorder(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private var colorLabelStrip: some View {
        if let label = xmp?.label {
            VStack(spacing: 0) {
                Spacer()
                label.color.opacity(0.85).frame(height: 5)
            }
        }
    }

    @ViewBuilder
    private func squareThumbnail(size: CGFloat) -> some View {
        if let data = thumbnailData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
        } else {
            Color(.systemGray5)
                .frame(width: size, height: size)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }

    @ViewBuilder
    private var fitThumbnail: some View {
        if let data = thumbnailData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
        } else {
            Color(.systemGray5)
                .aspectRatio(3/2, contentMode: .fit)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }

    @ViewBuilder
    private var overlayBadges: some View {
        // bottom-leading: rating
        if let xmp, xmp.rating != nil {
            HStack(spacing: 3) {
                if let rating = xmp.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .adaptiveGlass(cornerRadius: 8)
            .padding(4)
        }

        // top-trailing: member count (groups only)
        if group.memberIDs.count > 1 {
            Text("\(group.memberIDs.count)")
                .font(.caption2.bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .adaptiveGlass(cornerRadius: 8)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }

        // top-leading: photo kind badge
        kindBadge
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var kindBadge: some View {
        Text(kind.localizedBadgeName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(kind == .sooc ? Color.primary : Color.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                switch kind {
                case .sooc:
                    RoundedRectangle(cornerRadius: 3).fill(.ultraThinMaterial)
                case .raw:
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.85))
                case .developed:
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.85))
                case .indeterminate:
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.85))
                }
            }
    }

    private func selectionBorder(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
    }
}
