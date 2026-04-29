import AppKit
import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false

    private var cellSize: CGFloat { store.settings.thumbnailSize }
    private var isSelected: Bool { store.selectedIDs.contains(entry.id) }
    private var thumbnail: CGImage? { store.thumbnailImages[entry.id] }
    private var xmp: XmpData? { store.xmpData[entry.id] }
    private var exif: ExifData? { store.exifData[entry.id] }

    private var photoKind: PhotoKind {
        if entry.isRaw { return .raw }
        if (xmp?.developed == true) || (exif?.isDeveloped == true) { return .developed }
        return .sooc
    }

    private var identifierText: String {
        let isJa = store.settings.language == "ja"
        switch photoKind {
        case .sooc:      return isJa ? "カメラ出力" : "SOOC"
        case .raw:       return "RAW"
        case .developed: return isJa ? "現像済" : "Retouched"
        }
    }

    var body: some View {
        strictBody
    }

    // MARK: - Strict mode (square tile sized by slider, filename + rating below)

    private var strictBody: some View {
        VStack(spacing: 4) {
            ZStack {
                // scaledToFit でアスペクト比が合わない場合に生じるレターボックス部分の地色
                Color.secondary.opacity(0.08)
                ThumbnailImageView(cgImage: thumbnail)
                    .frame(width: cellSize, height: cellSize)
                colorLabelStrip
            }
            .frame(width: cellSize, height: cellSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) { flagView.padding(5) }
            .overlay(alignment: .topTrailing) {
                identifierBadge
                    .padding(4)
                    .opacity(photoKind != .sooc || isHovered ? 1 : 0)
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .overlay { selectionStroke(cornerRadius: 6) }

            HStack(spacing: 3) {
                if let rating = xmp?.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow.opacity(0.75))
                }
                Text(entry.filename)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: cellSize)
        }
        .onHover { isHovered = $0 }
        .contextMenu { cellContextMenu }
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
                case .developed:
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.8))
                }
            }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var cellContextMenu: some View {
        let isJa = store.settings.language == "ja"

        Button(isJa ? "コピー" : "Copy") {
            if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
            store.triggerCopy()
        }

        Button(isJa ? "元のファイルを表示" : "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }

        Divider()

        Menu(isJa ? "評価" : "Rating") {
            Button(isJa ? "評価なし" : "No Rating") {
                if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                store.triggerRating(0)
            }
            ForEach(1...5, id: \.self) { n in
                Button(String(repeating: "★", count: n)) {
                    if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                    store.triggerRating(n)
                }
            }
        }

        Menu(isJa ? "ラベル" : "Label") {
            ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                Button(label.name) {
                    if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                    store.applyLabel(label.rawValue)
                }
            }
            Divider()
            Button(isJa ? "ラベルを解除" : "Clear Label") {
                if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                // clear by applying the current label (toggle off)
                if let current = store.xmpData[store.primaryID ?? entry.id]?.label {
                    store.applyLabel(current.rawValue)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
            store.triggerDelete()
        } label: {
            Text(isJa ? "ゴミ箱に移動" : "Move to Trash")
        }
    }

    private func selectionStroke(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.25) : Color.clear),
                    lineWidth: isSelected ? 3.0 : 1.0
                )
            if isSelected {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1.5))
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.0)
                    .padding(1.5)
            }
        }
        .animation(.easeInOut(duration: 0.08), value: isSelected)
    }
}

struct ThumbnailImageView: View {
    let cgImage: CGImage?

    var body: some View {
        if let img = cgImage {
            Image(decorative: img, scale: 1.0)
                .resizable()
                .scaledToFit() // Fill ではなく Fit: タイル内で写真を見切れさせない
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
