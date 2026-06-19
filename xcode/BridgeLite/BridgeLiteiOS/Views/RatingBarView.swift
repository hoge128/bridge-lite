import SwiftUI

/// 星レーティング単体コントロール（スライド・タップ・ダブルタップ対応）。
/// RatingBarView と iPad 2×2 グリッドの両方から再利用する。
struct RatingStarsControl: View {
    @Binding var xmp: XmpData
    let onCommit: (XmpData) -> Void

    @State private var dragRating: Int? = nil
    @State private var isDragging = false
    @State private var lastTap: (rating: Int, time: Date)? = nil

    // 各星: frame 36pt + spacing 6pt = 42pt/star
    private let starStride: CGFloat = 42

    var body: some View {
        let displayRating = dragRating ?? (xmp.rating ?? 0)
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= displayRating ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(star <= displayRating ? Color.yellow : Color.white.opacity(0.7))
                    .frame(width: 36, height: 36)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if abs(value.translation.width) > 6 { isDragging = true }
                    if isDragging {
                        dragRating = ratingFromX(value.location.x)
                    }
                }
                .onEnded { value in
                    defer { isDragging = false; dragRating = nil }
                    if isDragging || abs(value.translation.width) > 6 {
                        commitRating(ratingFromX(value.location.x))
                    } else {
                        handleTap(rating: ratingFromX(value.location.x))
                    }
                }
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .adaptiveGlass(cornerRadius: 20)
    }

    private func ratingFromX(_ x: CGFloat) -> Int {
        // x=0 が最初の星の左端。各星は 42pt 幅（frame 36 + spacing 6）
        // 最初の星の中心より左 (x < 21) は 0 扱い
        let offset = x - starStride / 2
        if offset < 0 { return 0 }
        return min(5, Int(offset / starStride) + 1)
    }

    private func handleTap(rating: Int) {
        let now = Date()
        // ダブルタップ（0.3秒以内の再タップ）→ 0 に
        if let last = lastTap, now.timeIntervalSince(last.time) < 0.3 {
            commitRating(0)
            lastTap = nil
            return
        }
        commitRating(rating)
        lastTap = (rating: rating, time: now)
    }

    private func commitRating(_ rating: Int) {
        xmp.rating = rating == 0 ? nil : rating
        onCommit(xmp)
    }
}

/// カラーラベル単体コントロール。
/// 「ラベルなし」ボタンは廃止（選択中のラベルを再タップで解除）。
/// 選択状態は 白い外枠 + チェックマーク で明示する。
struct ColorLabelControl: View {
    @Binding var xmp: XmpData
    let onCommit: (XmpData) -> Void

    var body: some View {
        // 星(spacing 6 / frame 36 / 横padding 20)と同一の横メトリクスにして、
        // 星 i の真下にラベル i が並ぶよう縦の列を揃える。
        HStack(spacing: 6) {
            ForEach(XmpLabel.allCases, id: \.self) { label in
                labelButton(label)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .adaptiveGlass(cornerRadius: 20)
    }

    @ViewBuilder
    private func labelButton(_ label: XmpLabel) -> some View {
        let isSelected = xmp.label == label
        Button {
            xmp.label = isSelected ? nil : label
            onCommit(xmp)
        } label: {
            Circle()
                .fill(label.color)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: isSelected ? 2.5 : 0)
                )
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                    }
                }
                .shadow(color: isSelected ? label.color.opacity(0.6) : .clear, radius: 4)
                // 星(36pt フレーム)と縦位置・行高を揃える。
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label.name))
    }
}

/// 星レーティング + カラーラベルを縦に並べた複合ビュー（縦／フルスクリーンレイアウト用）。
struct RatingBarView: View {
    let entry: PhotoEntry
    @Binding var xmp: XmpData
    let onCommit: (XmpData) -> Void

    var body: some View {
        VStack(spacing: 10) {
            RatingStarsControl(xmp: $xmp, onCommit: onCommit)
            ColorLabelControl(xmp: $xmp, onCommit: onCommit)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }
}
