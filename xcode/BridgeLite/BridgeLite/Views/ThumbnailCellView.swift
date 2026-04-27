import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false

    private var isSelected: Bool { store.selectedID == entry.id }
    private var thumbnail: CGImage? { store.thumbnailImages[entry.id] }
    private var xmp: XmpData? { store.xmpData[entry.id] }
    private var exif: ExifData? { store.exifData[entry.id] }

    private enum PhotoKind { case sooc, raw, retouched }

    private var photoKind: PhotoKind {
        if entry.isRaw { return .raw }
        if (xmp?.developed == true) || (exif?.isDeveloped == true) { return .retouched }
        return .sooc
    }

    private var identifierText: String {
        let isJa = store.settings.language == "ja"
        switch photoKind {
        case .sooc:      return isJa ? "カメラ出力" : "SOOC"
        case .raw:       return "RAW"
        case .retouched: return isJa ? "現像済" : "Retouched"
        }
    }

    var body: some View {
        if store.settings.gridMode == .dense {
            denseBody
        } else {
            strictBody
        }
    }

    // MARK: - Strict mode (180×180 square, filename + rating below)

    private var strictBody: some View {
        VStack(spacing: 4) {
            ZStack {
                ThumbnailImageView(cgImage: thumbnail)
                    .frame(width: 180, height: 180)
                colorLabelStrip
            }
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) { flagView.padding(5) }
            .overlay(alignment: .topTrailing) { identifierBadge.padding(4) }
            .overlay { selectionStroke(cornerRadius: 6) }

            HStack(spacing: 3) {
                if let rating = xmp?.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                }
                Text(entry.filename)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 180)
        }
        .onHover { isHovered = $0 }
    }

    // MARK: - Dense mode (flexible size, no filename, overlaid metadata)

    private var denseBody: some View {
        ZStack {
            ThumbnailImageView(cgImage: thumbnail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            colorLabelStrip
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                flagView
                if let rating = xmp?.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(4)
        }
        .overlay(alignment: .topTrailing) { identifierBadge.padding(4) }
        .overlay { selectionStroke(cornerRadius: 4) }
        .onHover { isHovered = $0 }
    }

    // MARK: - Shared sub-views

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
    private var flagView: some View {
        if let flag = xmp?.flag {
            Image(systemName: flag == .pick ? "flag.fill" : "xmark.circle.fill")
                .font(.caption2.bold())
                .foregroundStyle(flag == .pick ? Color.white : Color.red)
                .shadow(color: .black.opacity(0.5), radius: 1)
        }
    }

    @ViewBuilder
    private var identifierBadge: some View {
        let kind = photoKind
        Text(identifierText)
            .font(.caption2.bold())
            .foregroundStyle(kind == .sooc ? Color.primary : Color.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                switch kind {
                case .sooc:
                    RoundedRectangle(cornerRadius: 3).fill(.ultraThinMaterial)
                case .raw:
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.8))
                case .retouched:
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.8))
                }
            }
    }

    private func selectionStroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(
                isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.4) : Color.clear),
                lineWidth: isSelected ? 2 : 1
            )
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
