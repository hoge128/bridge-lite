# フィルタパイプライン再設計

最終更新: 2026-06-30

## 背景・動機

bridge-lite には多数のフィルタが実装されている。現状は動作しているが、**「フィルタを 1 つ変えるだけで全パイプラインが同期で走り直す」**構造のため、将来エントリ数が数万〜10 万件規模になったときに主スレッドが詰まる懸念がある。体感上は現状困っていないが、将来の備えとして設計を整理する。

---

## 現状のフィルタ一覧

### ユーザー可視フィルタ（`FilterCriteria` / `FilterCriteria.swift:41-208`）

| フィルタ | フィールド | 判定コスト | 依存メタ |
|---|---|---|---|
| ファイル名/キャプション検索 | `nameSearch` | `localizedCaseInsensitiveContains` × 2（重） | entry.filename + xmp.caption |
| 拡張子除外 | `excludedExtensions` | Set O(1)（flatten 時のみ） | URL のみ |
| カメラ必須 | `cameraOnly` | 文字列 isEmpty × 2 | EXIF make/model |
| カメラ除外 | `excludedCameras` | Set O(1) | EXIF cameraName |
| レンズ除外 | `excludedLenses` | Set O(1) | EXIF lensName |
| アーティスト除外 | `excludedArtists` | Set O(1) | EXIF artist |
| ISO 範囲 | `isoMin/Max` | Int パース + 比較 | EXIF iso |
| 焦点距離範囲 | `focalMin/Max` | Double パース + 比較 | EXIF focalLength35mm |
| シャッター速度範囲 | `shutterMin/Max` | parseSeconds（split+Double） | EXIF exposureTime |
| 絞り範囲 | `apertureMin/Max` | Double パース + 比較 | EXIF fnumber |
| 日付範囲 | `dateMin/Max`, `dateMode` | DateFormatter parse + Calendar（重） | EXIF datetime |
| 日付複数選択 | `dateAllowList` | DateFormatter 1 回 + Set | EXIF datetime |
| 輝度範囲 | `luminanceMin/Max` | Int 比較 | サムネイル後計算スコア |
| レーティング | `filterRatings` | Set O(1) | XMP rating |
| ラベル | `filterLabels` | Set O(1) | XMP label |
| Photo Kind | `filterKinds` | グループ毎 O(n_members)（重） | EXIF/XMP/filename |
| Flatten | `flatten` | O(1)（グルーピング無効化） | なし |

### 内部的に効いている絞り込み（UI 非表示）

| 名称 | 場所 | 説明 |
|---|---|---|
| 拡張子フィルタ（Rust） | `scanner.rs:6-13` | `SUPPORTED_EXTENSIONS` / `RAW_EXTENSIONS` |
| 隠しファイル除外 | `ScanPipeline.swift:27` | `.skipsHiddenFiles` |
| SCAN_MAX_DEPTH = 10 | `scanner.rs:155` | 階層制限 |
| RAW+JPG ペアリング | `scanner.rs` + `PairingPipeline.swift` | shotId で束ねる |
| 代表エントリ選定 | `LibraryStore.swift:2112, 2163` | 1 グループ 1 代表に絞る（事実上の隠しフィルタ） |

---

## 現状のパイプライン構造（変更前）

中心関数: `LibraryStore.recomputeVisible()` (LibraryStore.swift:1416〜)

```
recomputeVisible()
 ├─ S1: Representative 選定（全 shotGroups 走査、メモ化なし）
 │     if flatten     → liveReps = Set(orderedIDs)
 │     elif filterKinds → computeRepresentativesForKinds(...)
 │     else           → computeRepresentatives(...)
 │     reps = orderedIDs.filter { liveReps.contains($0) }
 │
 ├─ S2: 述語フィルタ
 │     filtered = reps.filter { filter.matches(entry, exif, xmp, luminance) }
 │     matches() 内の現在の順序（FilterCriteria.swift:80-164）:
 │       1. nameSearch (string contains×2)
 │       2. excludedExtensions (flatten時)
 │       3. cameraOnly
 │       4. excludedCameras/Lenses/Artists (Set O(1))
 │       5. iso / focal / shutter / aperture
 │       6. date (DateFormatter — 重い)
 │       7. filterRatings / filterLabels
 │       8. luminance
 │
 ├─ S3: Sort
 │     visibleIDs = sortedIDs(filtered)
 │     ※ exifDate キーは DateFormatter parse が N log N 回（旧: キャッシュなし）
 │
 ├─ S4: Daily grouping（viewMode == .daily の時のみ）
 │     rebuildDailyGroups()
 │
 └─ S5: Aggregates（毎回 6 軸 × matches フルスキャン）
       recomputeAggregates(reps: reps, fast: scanPhase == .loading)
       filteredIDsExcluding を 6 回 → matches が合計 7 回フルスキャンされる

問題点:
- filter.didSet { recomputeVisible() } で同期フルパイプライン（coalesce なし）
- 全 5 ステージが毎回フルリセット（スキップなし）
- computeRepresentatives が毎フィルタ変更で全グループ再走査（メモ化なし）
- photoDate(for:) で DateFormatter が N log N 回（sort）＋ N 回（daily）＋ N 回（aggregates）呼ばれる
```

### トリガー一覧

| 変化 | 処理 | 遅延 |
|---|---|---|
| `filter` 代入（didSet） | `recomputeVisible()` 同期 | なし（即座） |
| `setExif` / `mergeExifBatch` | `scheduleMetaFlush` 250ms → `scheduleRecomputeVisible(400ms)` | 250+400ms |
| `setXmp` | 同上 | 250+400ms |
| luminance スコア確定 | `scheduleRecomputeVisible(600ms)`（luminanceMin/Max 有効時のみ） | 600ms |
| `applyReindexedGroups` | `recomputeVisible()` 同期 | なし |
| `applyRating/Label/Caption` | `recomputeVisible()` 同期 | なし |
| `settings.sortKey` 変更 | `applyOrder()`（sort のみ、aggregates 不要） | なし |

---

## 再設計の骨子

### 5 ステージ + dirty フラグ

`recomputeVisible()` を 5 ステージに分解。各ステージは `dirty` フラグが立っているときだけ実行する。

```
依存関係:
  reps → filtered → sorted → daily
                    filtered → aggregates
```

| ステージ | メソッド | 出力キャッシュ | invalidate キー |
|---|---|---|---|
| S1 | `runStageReps()` | `cachedRepresentatives`, `cachedRepsOrdered` | shotGroups, filterKinds, flatten, entries.shotId |
| S2 | `runStageFiltered()` | `cachedFiltered` | S1 出力, filter 述語系フィールド |
| S3 | `runStageSorted()` | `visibleIDs` | S2 出力, sortKey, sortAscending |
| S4 | `runStageDaily()` | `dailyGroups` | S3 出力, viewMode |
| S5 | `runStageAggregates()` | 6 buckets, photosPerDay, availables | S1 出力, filter 全体 |

### dirty フラグの伝搬ルール

`mark(reps:filtered:sorted:daily:aggregates:)` で管理:

```
mark(reps: true)       → reps + filtered + sorted + daily + aggregates がすべて true
mark(filtered: true)   → filtered + sorted + daily + aggregates が true
mark(sorted: true)     → sorted + daily が true
mark(daily: true)      → daily のみ true
mark(aggregates: true) → aggregates のみ true
```

### filter 変更の分類

`classifyFilterChange(from:to:)` で 2 軸を判定:

- **`repsAffected`**: `flatten` または `filterKinds` が変化 → S1 から再計算必要
- **`isTextInput`**: テキスト/スライダー系（nameSearch, *Min/*Max, dateMin/Max）→ coalesce 候補

---

## 述語の Tier 構造（将来の CompiledFilter 設計用）

`matches()` の述語をメタデータ依存性でグループ化する設計。早期 return 効率が上がる。

```
Tier 1（URL のみ、EXIF/XMP 不要）:
  - excludedExtensions（flatten 時, Set O(1)）
  - nameSearch の filename 部分

Tier 3（EXIF 必要）:
  コスト昇順: cameraOnly → excludedCameras/Lenses/Artists → iso → aperture → focal → shutter → date

Tier 4（XMP 必要）:
  - filterRatings, filterLabels（Set O(1)）
  - nameSearch の caption 部分（Tier 1 でヒット済みなら skip）

Tier 5（派生スコア）:
  - luminance min/max
```

**現状の順序の問題**: nameSearch（重い）が先頭、rating/label（軽い）が後ろ。逆が望ましい。

---

## 実装状況（2026-05-11 時点）

### 完了: PR1 - filter.didSet 差分ディスパッチ

`LibraryStore.swift` に以下を追加:

- `FilterChangeShape { repsAffected: Bool, isTextInput: Bool }`
- `classifyFilterChange(from:to:) -> FilterChangeShape`
- `onFilterChanged(from:)` — 現在は shape 計算後に `recomputeVisible()` を呼ぶ（挙動同一）

**現状**: shape は計算しているが coalesce は未使用。後続 PR でテキスト入力を 150〜200ms 間引く。

---

### 完了: PR2 - パイプラインのステージ分解

`LibraryStore.swift` に以下を追加:

```swift
// 追加プロパティ
@ObservationIgnored private var dirty = PipelineDirty()
@ObservationIgnored private var cachedRepresentatives: Set<UInt64> = []
@ObservationIgnored private var cachedRepsOrdered: [UInt64] = []
@ObservationIgnored private var cachedFiltered: [UInt64] = []

// PipelineDirty 構造体（reps/filtered/sorted/daily/aggregates の5フラグ）
// mark(reps:filtered:sorted:daily:aggregates:) — 下流伝搬
// runDirtyStages() — 5 ステージを順番に実行
// runStageReps/Filtered/Sorted/Daily/Aggregates() — 各ステージ
```

`recomputeVisible()` は「`dirty = PipelineDirty()` + `runDirtyStages()`」の薄いラッパに変更。21 か所の呼び出し元はそのまま。

**最初の実効最適化**: `applyOrder()` を `mark(sorted: true)` + `runDirtyStages()` に変更。sort キー変更時に S1/S2/S5 がスキップされるようになった。

---

### 完了: PR4 - exifDateCache による日付パースのキャッシュ化

```swift
@ObservationIgnored private var exifDateCache: [UInt64: Date?] = [:]
// キー不在   = 未計算
// 値 nil    = datetime 未設定 or パース失敗確定
// 値 non-nil = パース済み日付
```

- `scheduleMetaFlush` の flush 後に `flushedExif` を eager キャッシュ書き込み
- `photoDate(for:)` をキャッシュ優先実装に置換（lazy fallback あり）
- `applyRemovalToStore` / `reset()` でクリア追加

**効果**: exifDate ソートが N log N 回の DateFormatter parse → ほぼ全件 O(1) lookup。daily / date filter / aggregates も同様。

---

## 残タスク（未実施）

### PR3: Representative メモ化（中規模）

`computeRepresentatives` / `computeRepresentativesForKinds` が毎フィルタ変更で全グループ再走査している。

実装方針:
- `entryKindCache: [UInt64: PhotoKind]` を導入（`isDevelopedMember` の 4 段判定を O(1) に）
- `RepsCacheKey(flatten, kinds, shotGroupsVersion, entryKindVersion)` でメモ化
- xmp/exif フラッシュで developed/software 変化時のみ `entryKindVersion` を bump

懸念: invalidate 漏れが起きると古い representative が残る。DEBUG アサーションで旧パスと比較検証してから切替。

---

### PR5: CompiledFilter（中規模）

`FilterCriteria.matches()` を呼ぶたびに各フィールドをパースしている（isoMin → Int, dateMin → Date, shutter → Double など）。

実装方針:
- `struct CompiledFilter: Sendable, Equatable` を追加（パース済み値を保持）
- `filter.didSet` 時に 1 度だけ `filter.compiled()` を呼んで `LibraryStore` でメモ化
- 4 Tier 述語メソッドに分割（Tier 1/3/4/5）
- 述語順序を「コスト昇順」に並び替え（Set O(1) 系 → Int/Double 比較 → parse → DateFormatter）
- `FilterCriteria.matches()` は `CompiledFilter.matches()` に委譲する薄ラッパで外部 API 維持

---

### PR6: Aggregates の coalesce + Task.detached 化（中規模）

aggregates（S5）は現在同期実行で、フィルタ変更のたびに N 件 × 7 回スキャンが走る。

実装方針:
- `aggregatesPendingTask: Task<Void, Never>?` で 200ms coalesce
- `AggregateInputs` を `Sendable` な値型 snapshot として `Task.detached` に渡す
- 結果反映時に `scanGeneration` 照合

ユーザー許容: 200〜400ms の遅延は OK（確認済み）。

---

### PR7: Aggregates 1-pass 化（中〜大規模）

現在 `filteredIDsExcluding` を 6 回呼んでいる（= `filter.matches` を 6 回フルスキャン）。1 ループで 6 軸を同時判定する「axis-aware predicate」に書き換える。

PR6 の後で性能計測して効果が見えてから判断。

---

### 完了: PR-snap (2026-06-30) - 離散トグルの即時適用

`onFilterChanged(from:)` を 3 分岐に変更（クリック感度改善のため）:

- `repsAffected`（flatten / filterKinds 変化）→ 従来どおり即時 `recomputeVisible()`
- `isTextInput`（スライダー/テキスト）→ `scheduleFilterApply()`（200ms デバウンス）
- それ以外＝**離散トグル（レーティング/ラベル等のチップ）→ デバウンス無しで即時 `runDirtyStages()`**

**重要**: この即時適用は **main スレッド同期**実行のまま。下記「PR8」で非同期＋シマー方式に置き換える前提の暫定対応だった。**→ 2026-06-30 に PR8 を実装し、この同期即時適用は `scheduleFilterApplyAsync` ベースの非同期方式に置き換え済み（下記 PR8 節を参照）。**

---

## UX 設計目標: 「コントロール即応 + 結果は非同期 + シマー表示」（PR8 / ✅ 実装済み 2026-06-30）

> 実装サマリ（2026-06-30）: 下記設計のとおり `LibraryStore` に実装済み。
> - `runFilterStagesAsync(applyGen:)` を追加。S2 filtered / S2.5 ratingCounts / S3 sorted を
>   `Task.detached(.userInitiated)` でバックグラウンド計算し、`scanGeneration` + `filterApplyGeneration`
>   の二重ガードで反映。`isFilterPending` でシマー表示。
> - `scheduleFilterApplyAsync(debounceMs:)` に置換（旧 `scheduleFilterApply` は削除）。
>   離散トグル/repsAffected=0ms、連続入力(スライダー/テキスト)=200ms。
> - 純粋 static `sortIDs(...)` / `computeRatingCounts(...)` を追加し同期・非同期パスで共有
>   （`compareIDs` は `sortIDs` に統合）。`.exifDate` ソートは MainActor で `photoDate` 事前解決。
> - stale 上書き防止: `recomputeVisible()` 冒頭で in-flight をキャンセル＋世代 bump、`reset()` でも同様。
> - 注意（既存挙動踏襲）: `filter.matches` の日付述語は共有 static DateFormatter を使い off-main 実行される。
>   既存の aggregates パス（`filteredIDsExcluding`）も同様に off-main で matches を呼んでおり、本変更は
>   その前例に倣う（DateFormatter の format/parse は macOS 10.9+ でスレッドセーフ）。将来 PR5
>   (CompiledFilter) でパース済み述語に置換すればこの依存自体が消える。
>
> 以下は設計の経緯・詳細（参照用）。

> ユーザー要望（2026-06-30）: **フィルタ操作（コントロール）自体は即座に描画されるべき。結果（フィルタ対象の画像が出るまで）は数秒かかってよい。その待ち時間をシマーアニメーションで表現したい。**

### 現状はこの設計になっていない（要点）

- 結果に直結する重い段 **S2 filtered / S2.5 ratingCounts / S3 sorted** は `runDirtyStages()` 内で **main スレッド同期実行**（`runDirtyStages()` のコメント「S1〜S4 は同期実行、S5 のみ Task.detached」）。
- そのため計算中は main がブロックされ、**フィルタチップ自身の再描画もシマー（`ThumbnailGridView` の `.shimmer(when: store.isFilterPending)`）も止まる**。
- `isFilterPending` のシマーは実質、連続入力の 200ms デバウンス区間しかカバーしておらず、**本当の計算時間中は出ていない**。
- 既存ドキュメントの PR6 は **S5 aggregates のみ**の非同期化であり、S2/S2.5/S3（＝結果そのもの）の非同期化はカバーしていない。本節がそれを補う。

### 望ましいフロー

1. **コントロール操作（main・即時・軽量）**: `filter` 更新 ＋ `isFilterPending = true` だけを同期実行。チップのハイライトとシマー開始が即描画される。
2. **結果計算（バックグラウンド）**: reps（必要時）/ filtered / ratingCounts / sorted をスナップショット入力で `Task.detached` 計算。数秒かかっても UI は固まらない。
3. **反映（MainActor）**: `visibleIDs` / `ratingCounts` を反映し `isFilterPending = false`。シマー停止・画像表示。

### 実装方針（既存パターンの横展開）

同ファイルの **`runStageAggregates()`（S5）が既にこの形**（`exifSnap`/`entrySnap`/`filterSnap`/`lumSnap` をスナップ → `Task.detached` → `scanGeneration` (gen) ガード付きで `MainActor.run` 反映）。これを filtered/sorted/ratingCounts 段にも適用すればよく、新しい仕組みは不要。

- **新メソッド** 例: `runFilterStagesAsync()` を追加し、`onFilterChanged` の非 repsAffected 分岐から呼ぶ。
- **スナップショット**: 計算入力（`entries` / `exifData` / `xmpData` / `luminanceScores` / `cachedRepsOrdered` / `filter` / `settings.sortKey` / `sortAscending`）を `Sendable` ローカルに束ねて detached に渡す（計算中 read-only）。
- **キャンセル**: 新しいフィルタ変更が来たら in-flight を破棄。既存 `pendingFilterApplyTask` を流用し、反映前に `Task.isCancelled` と `gen == scanGeneration` を二重チェック。
- **デバウンス整理**: 離散トグル＝デバウンス無しで即 detached 起動、連続入力（スライダー/テキスト）＝従来 200ms デバウンス後に detached 起動。どちらも `isFilterPending` で待ち時間をシマー表示。
- **repsAffected の扱い**: S1（代表選定）も重いので、理想的には同様に非同期化。ただし S1 は `shotGroups`/`entries` 依存で invalidate が絡むため、まず S2/S2.5/S3 の非同期化を先行し、S1 は段階導入を検討。

### 並行性の注意

- ステージ群は現状 `@MainActor` の store プロパティを直接読む。detached 化に伴い「読む値は全てローカル snapshot」へ徹底する（途中で store を触らない）。
- `filter.matches` は `entry`/`exif`/`xmp`/`luminance` を引数で受けるので、ID→メタの辞書をスナップに含めれば純粋関数として detached 実行可能。
- 反映は必ず MainActor。`visibleIDs` 差分代入（`if next != visibleIDs`）は維持して不要な再描画を避ける。

### 受け入れ基準（このプロジェクト着手時）

- 数万件規模でレーティング/ラベル/種別チップを連打しても **チップのハイライトが即描画**され、グリッドに**シマーが流れ続ける**こと（main がブロックされない）。
- 計算完了後に画像が差し替わり、シマーが止まること。
- 連打時に古い結果が最終結果を上書きしないこと（gen ガード）。
- スライダー/テキストは従来どおりデバウンスが効くこと。

### この設計と PR-snap の関係

PR8 を実装する際は、PR-snap の「離散トグル即時 `runDirtyStages()`（同期）」を**この非同期方式に置き換える**（PR8 が上位互換）。シマーは `isFilterPending` を流用。

---

## View 層: FilterPanelView の再描画コスト削減（✅ 2026-06-30）

PR8（データ非同期化）後も「チェックボックスのクリックで描画が遅い」が残った。原因はデータではなく
`FilterPanelView` の SwiftUI 再描画コスト（main 同期）。対応済み:

- **ルートの `.background(.ultraThinMaterial)` を削除**（最大の主犯）。縦長パネル全面のライブブラーが
  クリックごとに GPU 再合成されていた。`FilterPanelView` は NavigationSplitView の sidebar 列で OS が
  既に背景を提供するため不要（CLAUDE.md の SidebarView material 禁止と同種）。
- **各セクションを独立 `View` struct に分割**（`FileTypeFilterSection` … `LuminanceFilterSection`、
  共有 `FilterSectionLabel`）。`@State expanded` を各 struct へ移設。これで非同期 aggregates 更新
  （`ratingCounts`/`isoBuckets…`/`availableCameras…`）が**該当セクションのみ**を再描画する
  （旧モノリシック body は全体を作り直していた）。

**Fix C（✅ 2026-06-30・最重要だった）: ExifHistogramView を Equatable スキップ化**
Fix A+B 後も体感遅延が残った。原因は 7 個の `ExifHistogramView`（Canvas + GeometryReader +
DragGesture + ラベル ForEach と重い body）が、各セクション body が `store.filter` を読むため
**フィルタ変更のたびに 7 連続で再評価**されること。対応:
- `ExifHistogramView` の `@Binding minText/maxText` を **プレーン `String` + 確定時 `onCommit` クロージャ**へ変更。
  これで本 View は `@Observable`/`Binding` を一切読まない。ドラッグ確定（onEnded）でのみ `onCommit` を呼ぶ。
- `ExifHistogramView: Equatable`（`bars`/`minText`/`maxText`/`isLoading` で比較、クロージャは除外）。
  `ExifBucket: Equatable` も付与。
- 7 呼び出し側に `.equatable()` を適用。→ 無関係なフィルタ変更時、入力不変の histogram は **body 再評価をスキップ**。

**Fix D（✅ 2026-06-30・Codex 診断による本丸）: isFilterPending のしきい値ゲート化**
Codex の root-cause レビューで、チェックボックス体感遅延の主因は **`isFilterPending=true` がクリック毎に
グリッド全面シマー（`ThumbnailGridView.swift:78` の `.shimmer(when:)`）を起動**し、巨大グリッドへの
オーバーレイ mount + `repeatForever` アニメ start/stop がメインスレッドでチェック描画と競合することと判明。
対応（`LibraryStore.swift`）:
- `onFilterChanged` では **isFilterPending を即時 true にしない**。
- `scheduleFilterApplyAsync` に `pendingShimmerTask` を追加。`shimmerThresholdMs`(=100ms) 経過しても
  適用が終わっていない場合のみ `isFilterPending=true`。高速クリック（compute<100ms）ではシマーを
  一切出さない＝グリッドのシマー churn が起きず即応。
- 適用完了／`recomputeVisible`／`reset` で `pendingShimmerTask` をキャンセル。`isFilterPending=false` は
  既に false なら通知しない（`if isFilterPending { … }`）でグリッドの無駄な再評価を回避。

**Fix E（✅ 2026-06-30・Codex 診断 → ユーザー要望で再設計）: ヒストグラムを 3 層に分離**
ドラッグ中 `dragLeft/dragRight`(@State) が毎フレーム変わり `ExifHistogramView.body` が再評価され、
重い曲線（Catmull-Rom + ネスト `drawLayer`）と軸ラベル（N×`minimumScaleFactor`）が毎フレーム再描画。
ユーザー方針: **選択バー（ハンドル）はマウス即追従／曲線はドラッグ中リアルタイム不要／更新中はシマー**。
`ExifHistogramView` を 3 層に分離:
- **`HistogramCurve: View, Equatable`**（曲線本体）— `bars`/`leftIndex`/`rightIndex`（コミット済み）で比較し
  `.equatable()`。ドラッグ中は入力不変で **再描画スキップ＝静的**。Catmull-Rom/`drawLayer` はドラッグ中走らない。
- **更新中シマー** — `activeHandle != nil`（ドラッグ中）のとき曲線の上に `.shimmer()` を重ね「更新中」を表示。
- **`HistogramHandles: View`**（選択バー）— ライブ `effLeftIndex/effRightIndex` で毎フレーム描画。曲線を
  含まず縦線＋ピンのみで軽量＝マウス即追従。
- ラベル行 `HistogramLabelRow`（コミット済み index・`.equatable()`）も維持。
- 形状/曲線ヘルパーは `HistogramPin` enum と `hist*` ファイルスコープ関数へ移動し曲線/ハンドル層で共有。
- UX: 曲線と軸ラベルはドラッグ確定（離した）時に更新。ドラッグ中はシマー＋ライブのハンドルで操作感を担保。
- カーソル（`HistogramInteractive`、フィルムストリップのリサイズ帯と同方式の push/pop＋set）:
  - 選択バーの矩形（ハンドル±ゾーン／ボックス内）にいる時だけ形を変える。それ以外は arrow（`.onContinuousHover` で位置判定）。
  - ハンドルは動ける方向で出し分け: 両方 `resizeLeftRight` / 左端 `resizeRight` / 右端 `resizeLeft`（動けない方向の△なし）。ドラッグ中も端到達で差し替え。
  - ボックス内（領域ごと移動可能）はホバー `openHand`／移動中 `closedHand`。全範囲で移動不可なら arrow。
  - ドラッグ中は適用範囲を accent（青）の半透明矩形でライブ表示（eff* に追従）。`import AppKit` 追加。

**残課題（任意）**: `filter` は値型の単一 property のため、各セクション body（GroupBox + ラベルの
isXxxActive + Toggle の get）はいずれの filter 変更でも再評価される（観測は property 単位）。重い
histogram body は Fix C、グリッドシマーは Fix D、ヒストグラムのドラッグは Fix E で解消済み。さらに
削るなら Codex 推奨の **FilterCriteria の観測粒度分割**（セクション毎に別 observable／@Observable
サブモデル）。Fix E で体感が残る場合に着手。

---

## 将来の議論ポイント

1. **filter.isTextInput の coalesce 有効化**: `onFilterChanged(from:)` で `isTextInput == true` のとき `scheduleRecomputeVisible(coalesceMs: 150)` を使う。スライダー/テキスト入力の連続発火を間引く。

2. **述語の適用順序の最適化**: `matches()` の評価順を「軽い → 重い」に並べ替えるだけで、大量 early return が期待できる。特に rating / label は Set O(1) で軽く、かつユーザー的に選択率が高い（絞り込み量が多い）。

3. **filterKinds 変更のみ reps 再計算**: `onFilterChanged` で `repsAffected == true` のとき `mark(reps: true)` を使い、それ以外は `mark(filtered: true)` にする。flatten / filterKinds 変更以外で S1 をスキップできる。

4. **aggregates の UI 分離**: ヒストグラムと `availableExtensions/Cameras/...` の更新タイミングを分けることを検討。`available*` はメタデータ到着時に更新、buckets はフィルタ変更後の coalesce で更新。

---

## 変更ファイル

- `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift` — すべての変更はここ
- `xcode/BridgeLite/BridgeLite/Models/FilterCriteria.swift` — PR5 以降の変更予定

## 参考リンク（ファイル内）

| 関数/構造体 | LibraryStore.swift 行番号（目安） |
|---|---|
| `PipelineDirty` 構造体 | ~1417 |
| `mark(...)` | ~1426 |
| `runDirtyStages()` | ~1436 |
| `runStageReps()` | ~1445 |
| `classifyFilterChange(...)` | ~1504 |
| `onFilterChanged(from:)` | ~1525 |
| `recomputeVisible()` ラッパ | ~1543 |
| `applyOrder()` | ~1548 |
| `photoDate(for:)` | ~1663 |
| `scheduleMetaFlush()` | ~2044 |
| `computeRepresentatives()` | ~2163 |
| `computeRepresentativesForKinds()` | ~2112 |
| `recomputeAggregates()` | ~1637 |
| `filteredIDsExcluding()` | ~1699 |
