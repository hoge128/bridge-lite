# プログレッシブ サムネイル表示パターン

スキャン完了を待たずにグリッドを早期表示し、サムネイルを後から埋める設計。  
iOS で 2026-05 に実装。macOS は元からこの設計。

---

## 基本方針

「スキャン中」フラグ（`isScanning`）でグリッドを隠さない。  
「グループが確定したか否か」でグリッドの表示を切り替える。

```
groups が空 かつ isScanning → 全画面 ProgressView（初動のみ）
groups が空                 → empty state
groups が揃っている         → グリッド即表示（サムネイル未着は灰色 placeholder）
```

---

## なぜ groups が早く揃うか

スキャン処理は 2フェーズに分かれている：

| フェーズ | 処理 | 時間 |
|---------|------|------|
| 1. グルーピング | `scanDirectory` + `reindexShotGroups` | 数百ms〜数秒 |
| 2. サムネイル生成 | `loadThumbnails`（SQLite取得 + ImageIO/RAW抽出） | 数十秒〜数分 |

フェーズ1 が終わると `groups` は全件確定しており、グリッドを描くのに十分な情報が揃っている。  
フェーズ2 のサムネイル生成が長時間処理の本体。ここでグリッドを隠す必要はない。

---

## 実装パターン（iOS / SwiftUI）

### ThumbnailGridView

```swift
// NG: isScanning でグリッド全体を隠す（死に時間が発生する）
if scanStore.isScanning {
    ProgressView()
} else {
    grid
}

// OK: groups が確定したらすぐグリッドを出す
if scanStore.groups.isEmpty && scanStore.isScanning {
    // 初動（フェーズ1 の数秒間）のみ全画面 ProgressView
    ProgressView()
} else if scanStore.groups.isEmpty {
    emptyState
} else {
    VStack(spacing: 0) {
        if scanStore.isScanning {
            scanProgressBanner  // フェーズ2 の進捗を上部バナーで表示
        }
        grid
    }
    .animation(.easeInOut(duration: 0.2), value: scanStore.isScanning)
}
```

### 進捗バナー

スキャン中にグリッドが表示されている間、ユーザーに「まだ読み込み中」であることを伝える。  
完了で `isScanning = false` になると自動消滅。

```swift
private var scanProgressBanner: some View {
    HStack(spacing: 8) {
        ProgressView().controlSize(.mini)
        if scanStore.scanTotalCount > 0 {
            Text(String(format: String(localized: "Loading %d / %d"),
                        scanStore.scanLoadedCount, scanStore.scanTotalCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text(String(localized: "Scanning…"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(.secondarySystemBackground))
    .overlay(alignment: .bottom) { Divider() }
    .transition(.move(edge: .top).combined(with: .opacity))
}
```

**ポイント:**
- `scanLoadedCount` は `@Observable` プロパティのため、サムネイル到着ごとに Text が自動更新される
- バナーに `ultraThinMaterial` を使わない（ライブブラー再合成のコストを避けるため）
- `spring` アニメーション不使用（CLAUDE.md の禁止事項）

### ThumbnailCellView（placeholder は既存実装で十分）

```swift
// サムネイルデータが nil のとき既存の gray placeholder がそのまま機能する
if let data = thumbnailData, let uiImage = UIImage(data: data) {
    Image(uiImage: uiImage)...
} else {
    Color(.systemGray5)
        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
}
```

セル側に追加実装は不要。

---

## macOS との対応関係

| | macOS | iOS |
|--|-------|-----|
| グリッド表示タイミング | `applyReindexedGroups()` 後 | `groups` 非空になった直後 |
| 進捗表示場所 | 画面下部ステータスバー（`StatusBarView`） | グリッド上部バナー |
| 進捗の値 | `loadedThumbnailCount / preScanImageFiles` | `scanLoadedCount / scanTotalCount` |
| サムネイル更新方式 | `PassthroughSubject` + 250ms coalesce → 細粒度 per-cell 更新 | `@Observable thumbnails[id]` の直接代入 |

---

## 適用すべき場面

- 新しいスキャン系 View を作るとき
- 「ロード中は全画面ブロック」というパターンを見かけたとき
- グリッド・リストを持つ View で「表示できる段階になったらすぐ出す」判定が必要なとき

**判断基準:** データが「全部揃う前に部分的に有用な状態」になるなら、その時点で表示する。
