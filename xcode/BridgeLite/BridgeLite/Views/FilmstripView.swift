import SwiftUI
import AppKit

// MARK: - FilmstripView
//
// 任意の写真2〜4枚を並べて比較する独立ビュー。
// レイアウトは上下分割：
//   上 = 選択中（先頭4枚）の大プレビュー（GroupCompareView の CompareMemberColumn を再利用）
//   下 = 写真を選ぶサムネイルグリッド（ThumbnailGridView をそのまま埋め込み）
//   右 = （任意）メタデータバー（store.filmstripShowMeta、デフォルト OFF）
//
// 比較対象は既存の複数選択 (store.selectedIDs) を流用する。GroupCompareView と異なり
// 同一ショットグループに限定しない（visibleIDs 全体から任意に選べる）。
// プレビュー背景は比較ビュー（黒）とは別に、フィルムストリップ専用で白にする。

struct FilmstripView: View {
    @Environment(LibraryStore.self) private var store

    /// プレビューに一度に表示する最大枚数（全枚数を領域内にフィットさせる）。
    private var maxCompare: Int { LibraryStore.filmstripMaxCompare }
    /// ダウンサンプル目標（高品質・メモリ安全）。
    private let previewMaxPixels = 2048

    // ピッカー（下グリッド）の高さ。仕切りドラッグで可変。値が小さいほどプレビューが拡大する。
    @State private var pickerHeight: CGFloat = 280
    @State private var dragStartPicker: CGFloat? = nil
    private let pickerMinHeight: CGFloat = 140   // ここまで縮めるとプレビュー最大（＝上限）
    private let pickerMaxHeight: CGFloat = 600

    /// プレビューに並べる比較対象（store と共有：表示順の先頭 maxCompare 件）。
    private var compareIDs: [UInt64] { store.filmstripCompareIDs }

    private var selectedCount: Int { store.selectedIDs.count }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header

                previewArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                resizeDivider

                // 下: ピッカー。既存グリッドをそのまま再利用（GridInteractionNSView 単一レイヤ）。
                ThumbnailGridView()
                    .frame(maxWidth: .infinity)
                    .frame(height: pickerHeight)
                    // プレビューがアクティブのときピッカーの「背景のみ」減光（サムネには被せない）
                    .background {
                        if store.filmstripPreviewActive { Color.gray.opacity(0.35) }
                    }
            }
            .animation(.easeInOut(duration: 0.15), value: store.filmstripPreviewActive)

            // 右: メタデータバー（デフォルト OFF）。ライブラリの showSidebar とは独立。
            if store.filmstripShowMeta {
                Divider()
                SidebarView()
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                    .background(Color(.windowBackgroundColor))
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.filmstripShowMeta)
        .background(Color(.windowBackgroundColor))
        .background {
            // Esc でライブラリへ戻る
            Button("") { store.filmstripMode = false }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Spacer()

            if selectedCount > maxCompare {
                Label(
                    String(localized: "filmstrip.hint.max",
                           defaultValue: "Up to \(maxCompare) photos can be compared"),
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if selectedCount > 0 {
                Text("\(min(selectedCount, maxCompare)) / \(maxCompare)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Preview area（フィルムストリップ専用の白背景）

    @ViewBuilder
    private var previewArea: some View {
        let ids = compareIDs
        ZStack {
            // 背景のみ減光（写真には被せない）。プレビュー非アクティブ時は白→グレー。
            (store.filmstripPreviewActive ? Color.white : Color(white: 0.80))

            if ids.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "filmstrip.empty",
                                defaultValue: "Select photos to compare"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 全枚数を領域内にフィット（スクロールなし・行列でぴったり割り付け）。
                GeometryReader { geo in
                    let n = ids.count
                    let (rows, cols) = optimalGrid(memberCount: n, viewportSize: geo.size)
                    let spacing: CGFloat = 8
                    let cellW = max(40, (geo.size.width - spacing * CGFloat(cols + 1)) / CGFloat(cols))
                    let cellH = max(40, (geo.size.height - spacing * CGFloat(rows + 1)) / CGFloat(rows))

                    VStack(spacing: spacing) {
                        ForEach(Array(0..<rows), id: \.self) { r in
                            HStack(spacing: spacing) {
                                ForEach(Array(0..<cols), id: \.self) { c in
                                    let idx = r * cols + c
                                    if idx < n {
                                        let id = ids[idx]
                                        CompareMemberColumn(
                                            memberID: id,
                                            isFocused: store.filmstripFocusID == id,             // プレビューのフォーカス
                                            lightBackground: true,                               // 白背景向けの暗色文字
                                            compact: true,                                       // 大レーティング行は隠す
                                            downsampleMaxPixels: previewMaxPixels,               // 高品質ダウンサンプル
                                            isSelected: store.filmstripPreviewSelectedIDs.contains(id)
                                        )
                                        .frame(width: cellW, height: cellH)
                                        // グリッド同等の選択: クリック / Shift範囲 / ⌘トグル（ピッカーとは独立）
                                        .onTapGesture {
                                            let m = NSEvent.modifierFlags
                                            if m.contains(.shift) { store.previewRangeSelect(to: id) }
                                            else if m.contains(.command) { store.previewToggle(id) }
                                            else { store.previewSelect(id) }
                                        }
                                    } else {
                                        Color.clear.frame(width: cellW, height: cellH)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(spacing)
                    // 上下矢印ナビ用に現在の列数を store へ反映
                    .onAppear { store.filmstripPreviewCols = cols }
                    .onChange(of: cols) { _, newCols in store.filmstripPreviewCols = newCols }
                }
            }
        }
        // 白背景に合わせて常にライト配色（アプリがダークでも文字が黒で見えるように）
        .environment(\.colorScheme, .light)
    }

    // MARK: - Resizable divider（プレビュー領域を上限まで拡大縮小）

    private var resizeDivider: some View {
        ZStack {
            Rectangle()
                .fill(Color(.separatorColor))
                .frame(height: 1)
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 12)
        .contentShape(Rectangle())
        .background(.bar)
        .gesture(
            DragGesture()
                .onChanged { v in
                    if dragStartPicker == nil { dragStartPicker = pickerHeight }
                    let base = dragStartPicker ?? pickerHeight
                    // 下へドラッグ（translation.height > 0）でピッカー縮小＝プレビュー拡大
                    pickerHeight = min(max(base - v.translation.height, pickerMinHeight), pickerMaxHeight)
                }
                .onEnded { _ in dragStartPicker = nil }
        )
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
    }

    // GroupCompareView と同等の最適グリッド算出（1〜4 枚を viewport に応じて配置）。
    private func optimalGrid(memberCount n: Int, viewportSize size: CGSize) -> (rows: Int, cols: Int) {
        guard n > 0 else { return (1, 1) }
        let viewportAspect = max(0.1, size.width / max(size.height, 1))
        let imageAspect: CGFloat = 1.5
        let rawCols = (Double(n) * Double(viewportAspect) / Double(imageAspect)).squareRoot()
        let cols = min(max(Int(rawCols.rounded()), 1), n)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        return (rows, cols)
    }
}
