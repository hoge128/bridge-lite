import AppKit
import Combine
import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store

    // @State で自分の id 分だけ保持し、dict 全体への @Observable 依存を排除
    @State private var thumbnail: CGImage? = nil
    @State private var thumbnailOrientation: Image.Orientation = .up
    @State private var xmp: XmpData? = nil
    @State private var exif: ExifData? = nil
    // 選択状態は body で store.selectedIDs を読まず、@State + selectionDidUpdate で
    // 自セルだけ更新する（選択変更時に全可視セルが再評価されるのを回避）。
    @State private var isSelected = false
    // プレビュー生成不可（CRW・MOS 等）。読込シマーと区別してプレースホルダを出す。
    @State private var previewUnavailable = false

    private var cellSize: CGFloat { store.settings.thumbnailSize }

    private var photoKind: PhotoKind {
        if entry.isRaw { return .raw }
        if entry.hasDevelopedSuffix || (xmp?.developed == true) || (exif?.isDeveloped == true) { return .developed }
        if let exif = exif, (exif.make ?? "").isEmpty && (exif.model ?? "").isEmpty { return .indeterminate }
        return .sooc
    }

    private var identifierText: String { photoKind.localizedBadgeName }

    var body: some View {
        strictBody
    }

    // MARK: - Strict mode (square tile, info strip inside frame)
    // サムネイル上部 + 情報ストリップ下部をすべて cellSize×cellSize の丸枠内に収める

    private static let infoStripHeight: CGFloat = 38

    // ファイル名・評価ストリップ（カラーラベルはサムネイル直下に別配置）
    private var infoStrip: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    Text(i <= (xmp?.rating ?? 0) ? "★" : "☆")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            i <= (xmp?.rating ?? 0)
                                ? Color(red: 0.95, green: 0.55, blue: 0.05)
                                : Color.secondary.opacity(0.35)
                        )
                }
            }
            .frame(height: 13)
        }
        .padding(.horizontal, 5)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(width: cellSize, height: Self.infoStripHeight - 4, alignment: .topLeading)
        // per-cell の .ultraThinMaterial（ライブ vibrancy）はグリッド全体で数十枚になり、
        // Mission Control 等のウィンドウ合成を重くするため不透明の適応色に置換（ブラー無し）。
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var strictBody: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            VStack(spacing: 0) {
                ThumbnailImageView(cgImage: thumbnail, orientation: thumbnailOrientation,
                                   unavailable: previewUnavailable)
                    .frame(width: cellSize, height: cellSize - Self.infoStripHeight)
                // カラーラベル帯：サムネイル画像の直下
                Group {
                    if let label = xmp?.label {
                        label.color.opacity(0.85)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: cellSize, height: 4)
                infoStrip
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            identifierBadge
                .padding(4)
                .opacity(store.filter.flatten || photoKind == .sooc ? 0 : 1)
        }
        .overlay(alignment: .topLeading) {
            if let flag = xmp?.flag {
                Image(systemName: flag.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(flag.color.opacity(0.9)))
                    .padding(4)
                    .help(flag.name)
            }
        }
        .overlay { selectionStroke(cornerRadius: 6) }
        .onAppear { loadCell() }
        .onReceive(store.thumbnailDidUpdate.filter { $0 == self.entry.id }) { _ in
            let id = entry.id
            let url = entry.url
            let blob = store.thumbnailBlobs[id]
            let isRaw = entry.isRaw
            let orient: Image.Orientation = isRaw ? (store.thumbnailOrientations[id] ?? .up) : .up
            Task { @MainActor in
                let decoded = await Task.detached(priority: .userInitiated) {
                    ThumbnailDecodeCache.shared.decode(url: url, blob: blob)
                }.value
                thumbnail = decoded
                if isRaw { thumbnailOrientation = orient }
                if decoded != nil { previewUnavailable = false }
            }
        }
        .onReceive(store.previewUnavailableDidUpdate.filter { $0 == self.entry.id }) { _ in
            if thumbnail == nil { previewUnavailable = true }
        }
        .onReceive(store.exifDidUpdate.filter { $0 == self.entry.id }) { _ in
            exif = store.exifData[entry.id]
        }
        .onReceive(store.xmpDidUpdate.filter { $0 == self.entry.id }) { _ in
            xmp = store.xmpData[entry.id]
        }
        .onReceive(store.selectionDidUpdate.filter { $0.contains(self.entry.id) }) { _ in
            isSelected = store.selectedIDs.contains(entry.id)
        }
    }

    // MARK: - Cell state loader

    private func loadCell() {
        thumbnail = nil
        thumbnailOrientation = .up
        xmp = nil
        exif = nil
        // 出現時に現在の選択状態へ同期（以後の変化は selectionDidUpdate で更新）
        isSelected = store.selectedIDs.contains(entry.id)
        previewUnavailable = store.isPreviewUnavailable(entry.id)
        let id = entry.id
        let url = entry.url
        thumbnailOrientation = entry.isRaw ? (store.thumbnailOrientations[id] ?? .up) : .up
        if let cached = ThumbnailDecodeCache.shared.peek(url: url) {
            thumbnail = cached
        } else if let blob = store.thumbnailBlobs[id] {
            Task { @MainActor in
                let decoded = await Task.detached(priority: .userInitiated) {
                    ThumbnailDecodeCache.shared.decode(url: url, blob: blob)
                }.value
                thumbnail = decoded
            }
        }
        xmp = store.xmpData[id]
        exif = store.exifData[id]
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
                    // material（ライブ vibrancy）を避け、適応色の半透明ソリッドで代替。
                    RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                case .raw:
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.8))
                case .developed:
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.8))
                case .indeterminate:
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.8))
                }
            }
    }

    private func selectionStroke(cornerRadius: CGFloat) -> some View {
        // 選択モード中は通常の枠線ではなく、全体を半透明の青ベタ塗りで「フォーカス」を示す
        // （通常選択と視覚的に区別する）。store.filmstripSelectionMode の購読はモード切替時
        // （まれ）のみ再評価を起こすため、選択変更ごとの全可視セル再評価には影響しない。
        let pickMode = store.isSelectionModeActive
        return ZStack {
            if pickMode {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(isSelected ? 0.38 : 0.0))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 2.0 : 1.0)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: isSelected ? 3.0 : 1.0
                    )
                if isSelected {
                    RoundedRectangle(cornerRadius: max(0, cornerRadius - 1.5))
                        .stroke(Color.white.opacity(0.55), lineWidth: 1.0)
                        .padding(1.5)
                }
            }
        }
        .animation(.easeInOut(duration: 0.08), value: isSelected)
    }
}

struct ThumbnailImageView: View {
    let cgImage: CGImage?
    var orientation: Image.Orientation = .up
    /// プレビューを生成できない RAW。true のとき読込シマーではなく「不可」プレースホルダを出す。
    var unavailable: Bool = false

    var body: some View {
        if let img = cgImage {
            Image(decorative: img, scale: 1.0, orientation: orientation)
                .resizable()
                .scaledToFit() // Fill ではなく Fit: タイル内で写真を見切れさせない
                .transition(.opacity)
        } else if unavailable {
            UnavailablePreviewView(compact: true)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                )
                .shimmer()
        }
    }
}

/// プレビューを表示できない RAW（CIFF CRW・Leaf MOS 等）の共通プレースホルダ。
/// グリッド（compact）・単体ビュワー・比較ビューで共有する。
struct UnavailablePreviewView: View {
    var compact: Bool = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            VStack(spacing: compact ? 4 : 10) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: compact ? 24 : 52, weight: .light))
                    .foregroundStyle(.secondary)
                Text(String(localized: "preview.unavailable", defaultValue: "No preview"))
                    .font(compact ? .caption2 : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !compact {
                    Text(String(localized: "preview.unavailable.detail",
                                defaultValue: "This RAW has no embedded preview to display."))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .padding(compact ? 4 : 12)
        }
    }
}
