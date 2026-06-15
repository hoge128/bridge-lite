import SwiftUI

// MARK: - FilmstripView
//
// 任意の写真2〜4枚を並べて比較する独立ビュー。
// レイアウトは上下分割：
//   上 = 選択中（先頭4枚）の大プレビュー（GroupCompareView の CompareMemberColumn を再利用）
//   下 = 写真を選ぶサムネイルグリッド（ThumbnailGridView をそのまま埋め込み）
//
// 比較対象は既存の複数選択 (store.selectedIDs) を流用する。GroupCompareView と異なり
// 同一ショットグループに限定しない（visibleIDs 全体から任意に選べる）。

struct FilmstripView: View {
    @Environment(LibraryStore.self) private var store

    /// 比較プレビューに表示する最大枚数。
    private let maxCompare = 4

    /// 表示順を保ったまま選択中の ID を取り出し、先頭 maxCompare 件に絞る。
    private var compareIDs: [UInt64] {
        store.visibleIDs.filter { store.selectedIDs.contains($0) }
            .prefix(maxCompare)
            .map { $0 }
    }

    private var selectedCount: Int { store.selectedIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            header

            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 下: ピッカー。既存グリッドをそのまま再利用（GridInteractionNSView 単一レイヤ）。
            ThumbnailGridView()
                .frame(maxWidth: .infinity)
                .frame(height: pickerHeight)
        }
        .background(Color(.windowBackgroundColor))
        .background {
            // Esc でライブラリへ戻る
            Button("") { store.filmstripMode = false }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    // ピッカーは画面下部 ~40%。プレビューに十分な高さを残す。
    private var pickerHeight: CGFloat { 280 }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Filmstrip")
                .font(.headline)

            Spacer()

            if selectedCount > maxCompare {
                Label(
                    String(localized: "filmstrip.hint.max",
                           defaultValue: "Up to 4 photos can be compared"),
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

    // MARK: - Preview area

    @ViewBuilder
    private var previewArea: some View {
        let ids = compareIDs
        if ids.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text(String(localized: "filmstrip.empty",
                            defaultValue: "Select 2–4 photos to compare"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let (rows, cols) = optimalGrid(memberCount: ids.count, viewportSize: geo.size)
                let spacing: CGFloat = 8
                let minCellHeight: CGFloat = 160
                let cellHeight = max(geo.size.height / CGFloat(rows) - spacing, minCellHeight)
                let gridColumns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, spacing: spacing) {
                        ForEach(ids, id: \.self) { id in
                            CompareMemberColumn(
                                memberID: id,
                                isFocused: store.primaryID == id
                            )
                            .frame(height: cellHeight)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color.black)
            }
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
