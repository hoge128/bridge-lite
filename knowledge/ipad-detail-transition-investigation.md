# iPad サムネイルグリッド → DetailView 遷移 実装調査記録

> 調査期間: 2026-06-08〜09。ブランチ: `feature/ipad-optimization`。

---

## 問題の出発点

**症状**: DetailView から戻ってすぐスクロールすると、直前に開いたサムネイルが
旧スクリーン座標に「固まって」描画される。

**根本原因**: `.navigationTransition(.zoom(sourceID:in:))` は UIKit の CALayer
アニメーションを使う。dismiss 開始時にソースセルのフレームを**ウィンドウ座標でキャプチャ**し、
そこへズームバックする。しかしスクロールするとセルの実座標が変わり、
アニメーション終端座標とずれる。

---

## 試した案と結果

### 案 1: `isTransitioningBack` + `.scrollDisabled` (当初の修正)

```swift
// onChange で dismiss 後に 0.35s ロック
.onChange(of: selectedGroup?.id) { _, newID in
    if newID == nil { isTransitioningBack = true; ... }
}
.scrollDisabled(isTransitioningBack)
```

**失敗理由**: SwiftUI の `@State` 変更は次の render cycle まで UIScrollView に
反映されない。`dismiss()` と UIKit アニメーション開始のタイミングに 1+ フレームの
ギャップがあり、その隙間でスクロールが届く。

---

### 案 2: UIWindow 透明オーバーレイ（Codex 実装）

UIKit レベルで `UIWindow` に透明 UIView を被せてタッチを遮断する方式。
`GridTransitionInteractionLock`（後に `gridTransitionLock()` 関数）として実装。

**失敗理由**: Swift 6 Concurrency エラー（`nonisolated(unsafe)`、`@MainActor` の
競合）が複数発生し修正コストが高騰。また UIKit 遷移システムが
オーバーレイより上位のレイヤーにコンテナを追加するため遮断が不完全だった可能性がある。

---

### 案 3: `onWillDismiss` コールバック + `NavigationPopObserver`

`dismiss()` 呼び出し前に同期的にロックをかける方式。

```swift
Button { onWillDismiss?(); dismiss() } label: { ... }
```

`NavigationPopObserver`（UIViewControllerRepresentable）で
`viewWillDisappear` をフックしてインタラクティブポップにも対応。

**失敗理由**: 改善が見られなかった（ユーザー確認済み）。
`parent?.isMovingFromParent` の判定が child VC では期待通り動作しない可能性。

---

### 案 4: NavigationSplitView（2列）

iPad の詳細画面を NavigationStack push ではなく 2列レイアウトに変更。

```swift
NavigationSplitView {
    mainContent   // グリッド列
} detail: {
    DetailView(...) or placeholder
}
```

**失敗理由**: 「ダサい」（ユーザー評価）。写真選定アプリとして
フルスクリーン詳細表示が必要。グリッドが常に左に見える UX は不適。

---

### 案 5: ZStack オーバーレイ + `.transition(.opacity)`

NavigationStack push をやめ、ZStack で DetailView をフルスクリーン重ねる方式。

```swift
ZStack {
    NavigationStack { mainContent }
    if let group = selectedGroup {
        NavigationStack { detailView(group:) }
            .background(Color.black.ignoresSafeArea())
            .transition(.opacity)
            .zIndex(1)
    }
}
```

**結果**: スクロールバグは解消。NavigationStack を閉じるたびに
`UINavigationController` が生成されツールバーの UIKit アニメーションが
SwiftUI の `.scale` トランジションと非同期になりちらつく問題が発生。
`.opacity` のみにすることでちらつきは解消したが、ズームアニメーションなし。

---

### 案 6: `matchedGeometryEffect`（断念）

セルと DetailView 間でヒーロートランジションを試みた。

**失敗理由**: `matchedGeometryEffect(isSource: false)` はソースビューのフレームを
**恒常的にコピー**する。ZStack で source と destination が同時に存在する場合、
destination が source（セル）サイズに固定されフルスクリーンにならない。
`matchedGeometryEffect` は source/destination が交互に存在する通常の
ヒーロー遷移（リスト行→詳細画面）向けの API。

---

### 案 7: NavigationStack + `scrollProxy.scrollTo` 事前スクロール（案 B）

dismiss 前にセルを画面内に確定させてから pop する Photos app 風アプローチ。

```swift
private func dismissDetail(group: ShotGroup) {
    guard isPad else { selectedGroup = nil; return }
    scrollProxy?.scrollTo(group.id, anchor: .center)
    Task { @MainActor in selectedGroup = nil }
}
```

**失敗理由**: 改善しなかった（ユーザー確認済み）。SwiftUI の `scrollTo` は
次の layout cycle に反映されるが、`Task { @MainActor in }` の実行タイミングが
layout cycle の前後どちらになるか不定のため、セル位置が確定前に pop が始まる。

---

### 案 8: `fullScreenCover`（採用・最終解）

`fullScreenCover` は UIKit のモーダル presentation のため、
zoom 遷移の座標キャプチャ問題が構造的に発生しない。

```swift
NavigationStack { mainContent }
    .fullScreenCover(item: $selectedGroup) { group in
        ExpandFromCellFullScreenCover(...) {
            NavigationStack { detailView(group: group, onClose: beginDetailDismissal) }
        }
    }
```

**`ExpandFromCellFullScreenCover` の仕組み**:

#### 開くアニメーション
1. `UIView.performWithoutAnimation` でデフォルトのスライドアニメーションを抑制
2. `.onAppear` で spring アニメーション（response: 0.22, dampingFraction: 0.86）
3. セル → フルスクリーンへの均一スケール（`ZoomClipShape`）
4. 展開完了後 0.28s で info パネルをフェードイン（`isDetailClosing` 環境値）

#### 閉じるアニメーション（Photos app 方式）
1. `beginDetailDismissal()` → `isDetailZoomClosing = true` → info パネルが 0.1s でフェードアウト
2. `capturedImageFrame`（`DetailImageViewportFrameKey` PreferenceKey で取得）を基点に scale+offset
3. **`FixedRectClip` で imageViewport 領域だけを先にクリップ**（←最重要）
4. easeIn(0.22s) でセル位置へ縮小、黒背景が同時にフェードアウト
5. 完了後 `finishDetailDismissal()` → `UIView.performWithoutAnimation { selectedGroup = nil }`

---

## 解決の鍵となった知見

### 1. `.navigationTransition(.zoom(...))` は根本的に修正不可能

このバグは SwiftUI の遷移システムが UIKit の CALayer アニメーション座標を
dismiss 時に再取得しないことが原因。SwiftUI 側に回避 API はなく、
UIKit の `UIViewControllerAnimatedTransitioning` を完全実装しない限り
同じ系統のアプローチは全て失敗する。

### 2. `fullScreenCover` がスクロールバグを解消する理由

`fullScreenCover` は dismiss されるまでモーダルとして前面に残る。
dismiss アニメーション中もグリッドはタッチ不可（モーダルがブロック）。
これにより「アニメーション中のスクロール→座標ズレ」が構造的に起きない。

### 3. `FixedRectClip` が必要な理由（閉じるアニメーション）

info パネルを `opacity: 0` で非表示にしても、その透明エリアが黒背景を
透かして見える。これが「画像の下に黒いエリア」として見える原因。
`scaleEffect` の前に `FixedRectClip(imageLocalRect)` でクリップすることで
imageViewport 以外のエリアを完全に除去できる。

### 4. `matchedGeometryEffect` の限界

ZStack で source と destination を同時に保持する場合、
`isSource: false` のビューが source のフレームに恒常的に固定されてしまう。
通常の「どちらか一方だけが存在する」ケースでしか使えない。

### 5. マスク方式 vs scale+offset 方式

マスク方式（静止コンテンツの上で窓を動かす）は、コンテンツが動いて見えず
「スライド窓」効果になる。Photos app と同様の「画像自体が飛んでいく」動きには、
コンテンツ自体を `scaleEffect + offset` で移動させる必要がある。

### 6. `DetailImageViewportFrameKey` の取得タイミング

`onPreferenceChange` は `isExpanded && isContentVisible` のときのみ更新する。
アニメーション中は `scaleEffect` が適用されているため imageViewport の
グローバル座標が歪んでいる。静止状態（フルスクリーン展開完了後）の座標だけを使う。

---

## 最終アーキテクチャ

```
ThumbnailGridView
  NavigationStack { mainContent }
  .fullScreenCover(item: $selectedGroup) { group in
      ExpandFromCellFullScreenCover(
          sourceRect: visibleCellFrames[group.id],  // ThumbnailCellFramePreferenceKey
          isClosing: isDetailZoomClosing,
          onCloseAnimationFinished: finishDetailDismissal
      ) {
          NavigationStack {
              DetailView(
                  onClose: { beginDetailDismissal() },
                  isClosing: @Environment(\.isDetailClosing)  // info パネル制御
              )
          }
      }
  }
```

**関連ファイル**:
- `ThumbnailGridView.swift`: `ExpandFromCellFullScreenCover`, `ZoomClipShape`, `FixedRectClip`,
  `ThumbnailCellFramePreferenceKey`, `DetailImageViewportFrameKey`
- `DetailView.swift`: `@Environment(\.isDetailClosing)`, imageViewport への `DetailImageViewportFrameKey` 適用

---

## 未解決・改善余地

- **閉じる方向**：imageViewport が画面上部（portrait 58%）にあるため、
  下のセルへ閉じると画像が「落ちる」ように見える。Photos app は
  UIKit snapshot で完全に制御しているため自然に見える。
  現状は許容範囲内と判断して一旦終了。
- **iPhone との差分**: iPhone は `.sheet()` のまま変更なし。
  `onClose: () -> Void` で `selectedGroup = nil` を呼ぶことで
  sheet も自動 dismiss される。
- **iPad 横向き**: `landscapeInfoPanel` にも `DetailImageViewportFrameKey` を
  付与済みだが、横向き時のアニメーション挙動は未検証。
