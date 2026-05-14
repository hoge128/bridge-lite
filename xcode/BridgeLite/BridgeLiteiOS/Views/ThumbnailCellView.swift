import SwiftUI

struct ThumbnailCellView: View {
    let group: ShotGroup
    let entries: [UInt64: PhotoEntry]
    let thumbnails: [UInt64: Data]
    let ratings: [UInt64: XmpData]
    let exifs: [UInt64: ExifData]
    /// nil = 2列モード（自然アスペクト比）、非 nil = 3列モード（正方形、値はセル幅）
    let squareCellSize: CGFloat?
    let isSelected: Bool
    let onTap: () -> Void

    private var representativeID: UInt64? { group.representativeID }
    private var thumbnailData: Data? { representativeID.flatMap { thumbnails[$0] } }
    private var xmp: XmpData? { representativeID.flatMap { ratings[$0] } }

    // Mac版 computeRepresentatives と同じ優先度: developed > sooc > raw > indeterminate
    private var photoKind: PhotoKind {
        var best: PhotoKind = .indeterminate
        for id in group.memberIDs {
            guard let entry = entries[id] else { continue }
            let kind = kindOf(entry: entry, id: id)
            switch kind {
            case .developed:     return .developed   // 即返し（最優先）
            case .sooc:          best = .sooc
            case .raw:           if best == .indeterminate { best = .raw }
            case .indeterminate: break
            }
        }
        return best
    }

    private func kindOf(entry: PhotoEntry, id: UInt64) -> PhotoKind {
        if entry.isRaw { return .raw }
        let xmpData = ratings[id]
        let exifData = exifs[id]
        if entry.hasDevelopedSuffix || (xmpData?.developed == true) || (exifData?.isDeveloped == true) {
            return .developed
        }
        if let e = exifData, (e.make ?? "").isEmpty && (e.model ?? "").isEmpty { return .indeterminate }
        return .sooc
    }

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
                overlayBadges
            }
            .frame(width: size, height: size)
            .clipped()
            .overlay(selectionBorder(cornerRadius: 0))
        } else {
            // 自然アスペクト比
            ZStack(alignment: .bottomLeading) {
                fitThumbnail
                overlayBadges
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(selectionBorder(cornerRadius: 6))
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
        // bottom-leading: rating + label
        if let xmp, xmp.rating != nil || xmp.label != nil {
            HStack(spacing: 3) {
                if let label = xmp.label {
                    Circle().fill(label.color).frame(width: 7, height: 7)
                }
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
        let kind = photoKind
        Text(kind.badgeName)
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
