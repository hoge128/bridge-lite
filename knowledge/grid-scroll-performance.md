# サムネイルグリッドのスクロール/クリック高速化（per-cell AppKit 排除）

3,000 枚クラスのフォルダで「スクロール」と「クリック→選択フォーカス」が体感で遅く、
**スクロールするほど悪化して戻らない**問題を解消した記録。再発時はまずここを参照する。

## 症状（2026-06 報告）
- 3,000 枚クラスのフォルダで、グリッドのスクロールとサムネイルのクリック反応が遅い。
- スクロール前は速いが、**何度かスクロールすると遅くなり、待っても戻らない**（持続劣化）。
- リリース(Archive) ビルドでも、v0.5.0 でも同等に遅い ＝ 退行ではなくアーキ上限。

## 切り分けで「除外できた」もの
- **Debug/Release**: Release(Archive) でも再現 → Debug ビルドのせいではない。
  （ただし日常の ⌘R は Debug=`-Onone` で SwiftUI は数倍遅い。体感比較は必ず同条件で）
- **メモリ/キャッシュ**: サムネイルメモリキャッシュを 3.2GB→512MB にしても変化なし
  → デコード済み画像の常駐量が主因ではない。
- **デコードタスクの一時的詰まり**: 待っても戻らない＝一過性ではない。

## 根本原因（実機二分法で確定）
`ThumbnailCellView` の**セル毎の AppKit / イベント機構**が犯人。`LazyVGrid` はスクロールで
セルを生成/破棄するため、セル毎に作られる AppKit オブジェクトの churn と、トラッキング
エリア等のイベント経路コストが**蓄積**し、クリック/ホバーのイベント応答性を持続的に劣化させる。

二分法の結果（同一フォルダ・同一ビルドで比較）:

| セルに残した per-cell AppKit | 体感 |
|---|---|
| 全部外す（contextMenu / onHover / 右クリックNSView / ドラッグNSView） | **非常に高速** |
| `.contextMenu` だけ外す | やや遅い |
| `.contextMenu` + `.onHover` を外す | やや速い（まだ NSViewRepresentable が残ると不十分） |

→ **どれか1つではなく、per-cell の AppKit が全部少しずつ蓄積コストを足している。**
macOS の SwiftUI には軽量な右クリック検出が無く、右クリックメニューもドラッグも
per-cell AppKit に依存していたのが背景。

## 採用した修正
### P1: 選択を per-cell 化（commit 610bb12）
クリック遅延の主因は `ThumbnailCellView` が body で `store.selectedIDs.contains(id)` を読み、
選択変更で**全可視セルが再評価**されていたこと。
- `LibraryStore.selectionDidUpdate: PassthroughSubject<Set<UInt64>, Never>` を追加。
- `selectedIDs` の `didSet` で「旧⊕新（symmetricDifference）」だけを送信（全経路を自動カバー）。
- セルは `@State isSelected` を持ち、自分の id を含む通知のみ `onReceive` で更新。
- 既存の `thumbnailDidUpdate / exifDidUpdate / xmpDidUpdate` と同じ per-id Subject 方式。

### P2/P3: マウス操作をグリッド単位の単一 AppKit レイヤへ集約
- `ThumbnailCellView` から **per-cell の AppKit を全廃**：`.contextMenu` / `.onHover` /
  `RightClickOverlay`(NSViewRepresentable) / `CellDragBackingView`(NSViewRepresentable) /
  `.gesture(DragGesture)`。セルは純粋な SwiftUI 表示に。
- `ThumbnailGridView` の strictGrid に、コンテンツ全面サイズの単一 NSView
  **`GridInteractionNSView`**（`GridInteractionView: NSViewRepresentable`）を1枚敷き、
  クリック選択・⌘/⇧複数選択・ダブルクリック（比較/単体）・ラバーバンド選択・
  Finder へのファイルドラッグ・右クリック NSMenu を**まとめて処理**。
  - 座標→セル index は `pad=8 / spacing=8 / cols=gridColumnCount / cellSize` の式。
    `isFlipped = true`（top-left 原点）で SwiftUI 側のセル配置と一致させる。
  - ダブルクリックは `NSEvent.doubleClickInterval` で手動判定（`TapGesture(count:2)` 禁止に準拠）。
  - 右クリックは**オンデマンドで NSMenu を生成**（スクロール中コストゼロ）。
- ホバー時の SOOC バッジ表示は廃止（per-cell `.onHover` 排除のため）。

結果: 3,000 枚でもスクロール/クリックが「とても快適」（item 1〜5 正常）。

## ❌ 再発防止（やってはいけない）
- **`ThumbnailCellView`（および各サムネイルセル）に per-cell の AppKit を足さない**：
  `.contextMenu` / `.onHover` / `NSViewRepresentable`（右クリック・ドラッグ等）/
  per-cell の `NSEvent` monitor。スクロールでの生成/破棄 churn が蓄積して必ず遅くなる。
- マウス操作の追加は **`GridInteractionNSView`（グリッド単位レイヤ）側に実装**する。
- セル body で `store.selectedIDs` を直接読まない（全セル再評価を招く）。選択は
  `@State isSelected` + `selectionDidUpdate` 購読で。
- 既存の click-latency 禁止（`TapGesture(count:2)` 併用 / spring 選択アニメ /
  SidebarView ルート `.ultraThinMaterial` / body 内 DateFormatter 生成 / ホットパス print）も継続厳守。

## 検証手順（スクロールが遅いと感じたら）
1. 体感比較は**同一ビルド構成**で（Debug ⌘R 同士、または Release/Archive 同士）。
2. 3,000 枚クラスのフォルダを開き、**たくさんスクロール→クリック**して持続劣化が出るか。
3. 出るなら、まず `ThumbnailCellView` に per-cell AppKit（上記禁止項目）が再混入していないか確認。
4. `LibraryStore` の `selectedIDs` を body で読む View が増えていないか確認。
5. メモリ/キャッシュは（過去の切り分け通り）主因になりにくい。デコードタスクの
   一過性詰まりは「待つと戻る」ので持続劣化とは区別する。

## 関連
- `xcode/BridgeLite/BridgeLite/Views/ThumbnailGridView.swift`（`GridInteractionNSView`）
- `xcode/BridgeLite/BridgeLite/Views/ThumbnailCellView.swift`（純表示化）
- `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift`（`selectionDidUpdate` / `selectedIDs.didSet`）
- CLAUDE.md「クリックレスポンス速度に関する禁止事項」
