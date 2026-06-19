# iPad DetailView 閉じ時の全画面フラッシュ（白/黒ベール）調査記録

> 調査日: 2026-06-10。ブランチ: `feature/ipad-optimization`。
> 前提アーキテクチャは `knowledge/ipad-detail-transition-investigation.md` を参照
> （ZStack オーバーレイ + `ExpandFromCellFullScreenCover`）。

---

## 症状

iPad の DetailView をスワイプダウン / ✗ボタンで閉じると、**画面全体（アプリの
コンテンツ領域のみ、システム UI は不変）が半透明のベールで 4〜6 フレーム覆われて
フェードアウトする**。

- ダークモード時は黒、ライトモード時は白に見える（← 後述のとおり `systemBackground`）
- ベールの α は約 0.22、減衰カーブは 0.25s easeOut
- 発生タイミングは**指を離した瞬間ではなく、その約 0.3 秒後 = overlay 除去
  （`selectedGroup = nil`）の瞬間**

当初は `max(0.5, ...)` の背景不透明度フロアで知覚されないよう緩和していたが、
根本修正によりフロアは撤去できた（完全透明まで下げてもフラッシュしない）。

---

## 調査手法（再利用可能）

### 1. デバッグカラーによるレイヤー特定

容疑レイヤーごとに異なる色を塗って画面録画する。フラッシュの色 = 犯人。

- ZStack の背景 dim `Color.black` → `Color.red`
- DetailView 内部の画像背景 → `Color.green`
- → フラッシュは**白**のままだった = SwiftUI 製レイヤーは全員無罪、
  白 = ライトモードの `systemBackground` = **UIKit 層**と確定

### 2. UIKit 背景再アサート検知ログ

`ClearHostingBackground`（UIView サブクラスで親階層の背景を clear にする
ワークアラウンド）の `layoutSubviews` に、非 clear 背景を発見した瞬間の
ログを仕込む。出力例:

```
[FLASH-DEBUG] re-assert: _TtCGC7SwiftUI32NavigationStackHostingController...HostingView
              bg=<UIDynamicSystemColor: name = systemBackgroundColor>
```

→ **白の供給源 = overlay 内 NavigationStack のホスティングビュー**と確定。

### 3. ffmpeg + ImageMagick によるフレーム解析

```sh
# 全フレーム展開
ffmpeg -i rec.mp4 -vf scale=372:-1 /tmp/f_%04d.png
# フレームごとの平均輝度（ベール = 輝度スパイクとして現れる）
for f in f_*.png; do magick "$f" -colorspace Gray -format "%[fx:mean*100]" info:; done
# ベール frame と settle frame の差分を増幅して空間分布を可視化
magick peak.png settled.png -compose difference -composite -evaluate multiply 4 diff.png
```

- 輝度タイムラインからフラッシュの正確なフレーム範囲と減衰カーブを取得
- 差分画像で「全画面 vs 局所」「システム UI を含むか」を判定
- 通知バナー / ステータスバー領域の輝度が不変 → アプリ内レイヤーと確定

---

## 根本原因（3つの要素の合成）

1. **SwiftUI は state 更新のたびに UIKit コンポーネント（NavigationStack の
   ホスティングビュー等）の backgroundColor に `systemBackground` を再アサートする。**
   UIKit 階層を歩いて clear にするワークアラウンドは毎回巻き戻される
   （swiftui-introspect メンテナの証言: siteline/swiftui-introspect#292）。
   特に overlay の teardown 時に復活した背景は `layoutSubviews` で再クリアできない。

2. **セル黒オーバーレイの表示条件が `group.id == selectedGroup?.id` だったため、
   overlay 除去（`selectedGroup = nil`）と同一コミットで構造的に消える**構造だった。
   そこに `withAnimation(.easeOut(0.25)) { selectedCellDimOpacity = 0 }` を同居させた
   結果、グローバル transaction が**同一コミット内のすべての構造的除去**に滲み、
   default の opacity transition が発生。
   - セル黒のフェード（意図した見た目）は実はこの滲みで「偶然」動いていた
   - 同じ滲みが teardown 中の NavigationStack ホスト（白背景復活済み）にも掛かり、
     **全画面白ベールとして見えていた** — 表裏一体だった

3. **`DispatchQueue.main.async` は「次のフレーム」ではない。**
   同一 runloop の CA コミット（beforeWaiting）前に実行されるため、
   async に包んでも除去と withAnimation は同じレンダーコミットに同居する。
   transaction 分離の手段としては無効（実測で確認）。

---

## 効かなかった対策（再試行しないこと）

| 対策 | 結果 |
|---|---|
| 背景 opacity のフロア 0.5 | 知覚されにくくなるだけの対症療法 |
| `DispatchQueue.main.async` で withAnimation を遅延 | 同一コミットに残るため無効 |
| overlay に `.transition(.identity)` | SwiftUI View の除去には効くが、内部の UIKit ホスト teardown のフェードは止まらなかった |
| `.containerBackground(Color.clear, for: .navigation)` (iOS 18) | teardown 時の backgroundColor 再アサートには無効（ベール強度に変化なし） |
| `ClearHostingBackground` の対象クラス拡大 | 再アサートとのいたちごっこ。teardown 時は再クリアの機会がない |

※ `.toolbar(isClosing ? .hidden : .visible)` の撤去と containerBackground は
ベールの直接原因ではなかったが、**セッション中の背景再アサート（re-assert ログ）を
止める効果はあった**ため残している。

## 最終的な修正（効いたもの）

**「overlay 除去のコミットにグローバル animation transaction を一切共存させない」**

1. セル黒オーバーレイの表示条件を `selectedGroup` から独立した
   **`dimmedGroupID`** に変更（除去コミットで道連れに消えない）。
2. `onCloseAnimationFinished` の流れ:
   `finishDetailDismissal()`（`disablesAnimations` で即時除去）
   → `selectedCellDimOpacity = 0` / `dimmedGroupID = nil`（即時・withAnimation なし）。
   飛行サムネイル（後述）がセルとピクセル一致で着地しているため、
   飛行イメージ→実セルの瞬間スワップはシームレス。
   ここにフェードを掛けると「写真→黒→写真」の瞬きがセル内に見える。

### ✗ボタン閉じの背景フラッシュ（Bool 分岐の transaction 帰属不定）

背景黒の opacity を `isSwipeDismiss ? 0.0 : ...` のような Bool 分岐で
切り替えると、`withAnimation` の【外】で設定したフラグと【中】で設定した
フラグが同一コミットで同じ式を変えるため transaction 帰属が不定になり、
1.0 → 0 が瞬時に適用されてフラッシュする。

**修正**: 閉じ開始時点の表示値を `closingStartBackground` に固定し、
`closingStartBackground * (1 - closingProgress)` で駆動する。
アニメーション補間される値（closingProgress）だけで導出すれば
切替フレームで値が連続し、帰属の曖昧さも消える。

---

## 閉じアニメーション「飛行サムネイル」方式（着地品質の最終解）

DetailView 全体を scaleEffect + クリップで縮小する方式は
(a) viewport のレターボックス余白ごと飛ぶ、(b) min 比率 fit のため
セルより小さく着地する、(c) セルの正方形 fill クロップと一致しない、
という品質問題が本質的に残る。最終的に **Photos.app と同じ
「写真スナップショットだけを飛ばす」方式**に置き換えた。

- `presentDetail` 時にセルと同じ代表サムネイルから `UIImage` を作り保持
- カバー内に飛行用 `Image` を**常時マウント**（透明・ドラッグ追従）。
  閉じ開始と同一コミットで挿入すると初期値からの補間が効かないため
- 閉じ開始: `isFlightActive` を `withAnimation` の【外】で立て、
  ライブコンテンツは即時非表示（スコープ付き `.animation(nil, value:)` で遮断）、
  飛行体は即時表示
- 飛行: 写真の実表示矩形（viewport に aspectFit + ドラッグオフセット）→
  実セル矩形へ、`scaledToFill` + 角丸 0→6 で補間。
  着地はセルのサムネイル描画（正方形 fill クロップ・角丸 6）とピクセル一致
- サムネイル未生成時のみ旧方式（コンテンツ縮小）にフォールバック

### ハマりどころ 1: onPreferenceChange は「値が変化した時」しか発火しない

viewport のグローバル座標は初回レイアウトで一度報告されたきり変わらない
（`scaleEffect` / `offset` はレンダー変換でレイアウト座標に影響しない）。
初回発火時にまだ false のフラグ（`isContentVisible` 等）でゲートすると
**キャプチャ機会が永遠に失われる**。
→ `capturedImageFrame` が常に空 = 飛行ガードが常に失敗 +
旧方式の `start = coverRect` フォールバック + 大ドラッグで
クリップ窓が画面外に出て「写真が 1 フレームで消える」の真因でもあった。

### ハマりどころ 2: タップ座標から合成した sourceRect は実セルとズレる

`SpatialTapGesture` の location 中心に `cellSize` の矩形を合成すると、
セル端タップで実セルから最大セル半分ズレて着地する。
→ `onGeometryChange` で可視セルの実フレームを **plain class
（`CellFrameStore`、@State 非観測）** に記録し、タップ時に読む。
@State 辞書に書くとスクロールごとに再レンダーが走るため不可。

---

## 同時に発見・修正した別バグ: 写真が 1 フレームで消える

深くドラッグして離すと、写真がセルへ飛ばずに即座に消滅していた。

**原因**: unifiedContent への統合リファクタリング時に、クリップ（`CoverClip`）が
`scaleEffect` の**後**に移動するリグレッションが入っていた。クリップ窓が
コンテンツと一緒に縮小されないため、縮小していく写真が固定窓から脱出する
（ドラッグ量が大きいほど顕著）。

**修正**: クリップを `scaleEffect` の**前**に戻す
（`ipad-detail-transition-investigation.md` の「最重要」ポイントの再確認）。
open 用クリップ寸法は pre-scale 座標系に合わせて `openScale` で割る補正が必要。

```swift
content(...)
    .clipShape(CoverClip(
        openW: openClipW / max(openScale, 0.01),   // pre-scale 座標系に補正
        ...
        fixedRect: imageLocalRect,                  // close 時は補正不要（コンテンツ座標）
        isClosing: showClosingMask))
    .scaleEffect(effectiveScale, anchor: .center)   // クリップの【後】
    .offset(...)
```

---

## 教訓（今後のルール）

1. **UIKit ホスト（NavigationStack 等）を含む View の構造的除去と
   `withAnimation` を同一コミットに同居させない。**
   フェードさせたい要素には スコープ付き `.animation(_:value:)` を使う。
2. **`DispatchQueue.main.async` をフレーム分離の手段として使わない**（分離されない）。
3. アニメーションが「なぜか動いている」ときは transaction の滲みを疑う。
   意図した経路で動いていない実装は、別の場所で副作用（今回のベール）を生む。
4. フラッシュ系の不具合は **デバッグカラー + 輝度タイムライン + 差分画像** の
   3点セットで犯人を機械的に特定できる。憶測で modifier をいじる前に計測する。
5. クリップ + scaleEffect の組み合わせは **modifier の順序が本質**。
   リファクタリング時に順序を変えると座標系が変わり、静かに壊れる。
