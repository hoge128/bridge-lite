# フィルタパイプライン再設計

最終更新: 2026-05-11

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
