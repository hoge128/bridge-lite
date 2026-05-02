# SPEED-TODO

6000 枚規模で残っている非効率な実装の改修 TODO（高 + 中優先度 14 項目）。

前回コミット `b8eaaf2 perf: 6000枚規模スキャン後の操作重さを7項目で改善` の延長。設計を壊さず最小差分で潰す方針。

検証は OSSignposter / `print` を入れず、⌘B → 6000 枚フォルダで体感確認。

---

## PR1: 低リスク独立改修

### [ ] H2 — `FilterCriteria` の `DateFormatter` キャッシュ
- ファイル: `xcode/BridgeLite/BridgeLite/Models/FilterCriteria.swift:144-158`
- `parseExifDate` / `parseISODate` 内のローカル `let f = DateFormatter()` を `static let exifDateFormatter` / `static let isoDateFormatter` に置換
- 参考: `LibraryStore.swift:848-867` に同形のパターンあり

### [ ] H6 — `RGBHistogram` に `maxVal` を保持
- ファイル: `xcode/BridgeLite/BridgeLite/Views/SidebarView.swift:6-12, 198-222, 253-256`
- `RGBHistogram` に `let maxVal: Int` を追加、`computeRGBHistogram` 末尾で `max(r.max, g.max, b.max, 1)` を 1 度だけ計算
- `RGBHistogramView.maxVal` computed property を削除（毎 body の Array 結合が消える）
- `RGBHistogram.empty` も `maxVal: 1` 付きで再定義

### [ ] H3 — `buildDateBuckets` を O(N+B) 化
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:1004-1053`
- 入口で `let sorted = dates.sorted()` を 1 度だけ
- cursor を進めながら `sorted` の先頭から `< nextMonth` (または `< nextDay`) まで idx を前進、`count = idx_after - idx_before`
- 月版・日版とも `dates.filter { ... }.count` を撤廃

### [ ] M6 — `ssText` の最適化
- ファイル: `xcode/BridgeLite/BridgeLite/Views/SidebarView.swift:319-322`
- `s.components(separatedBy: " ").first ?? s` を `s.split(separator: " ", maxSplits: 1).first.map(String.init) ?? s` に置換

### [ ] M9 — `WindowAccessor` 同値再代入ガード
- ファイル: `xcode/BridgeLite/BridgeLite/Views/ContentView.swift:227-229`
- `if nsView.window !== window { window = nsView.window }` のガード追加

### [ ] M12 — `ScanPipeline` をストリーミング列挙化
- ファイル: `xcode/BridgeLite/BridgeLite/Pipelines/ScanPipeline.swift:33`
- `enumerator.allObjects` 一括化を `while let obj = enumerator.nextObject()` に変更
- 各反復先頭で `try Task.checkCancellation()`、`guard let fileURL = obj as? URL else { continue }`

---

## PR2: ExifData 派生プロパティ統合（H4 + M7 + H7）

### [ ] ExifData 拡張
- ファイル: `xcode/BridgeLite/BridgeLite/Models/ExifData.swift`
- 既存 computed `isDeveloped` を **stored** に昇格
- 新規 stored: `var capturedAt: Date? = nil`, `var hasCameraTag: Bool = false`
- 新規 method: `func computingDerived() -> ExifData` — `make/model/software` から 3 派生プロパティを計算
- `static let exifDateParser: DateFormatter` を追加（`capturedAt` パース用）

### [ ] ExifData 流入箇所での正規化
- `Bridging/BridgeCore.swift` の ExifData 生成 2 箇所（`fetchExifBatch` 系）で末尾に `.computingDerived()` を適用
- `LibraryStore.setExif(id:exif:)` (`LibraryStore.swift:1087-1090`) と `mergeExifBatch` (行 1092-1095) 入口で `mapValues { $0.computingDerived() }` を介して正規化

### [ ] H4 — `computeRepresentatives` 系の置換
- `LibraryStore.computeRepresentatives` (行 1289-1311) と `computeRepresentativesForKinds` (行 1222-1271) のラムダ内 `software.lowercased() ... contains` ブロックを `exifData[id]?.isDeveloped == true` に置換
- `LibraryStore.isDevelopedMember` (行 1206-1214) も同様に簡素化

### [ ] H7 — `photoDate` 簡素化
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:843-846`
- `exifData[id]?.capturedAt ?? entries[id]?.createdDate ?? .distantPast` に変更
- `Self.exifDateParser.date(from:)` 呼び出しを削除

### [ ] M7 — `photoKind` 確認
- ファイル: `xcode/BridgeLite/BridgeLite/Views/ThumbnailCellView.swift:20-25`
- 派生プロパティが O(1) 化されたので computed のまま据え置き（`@State` 化は不要）

---

## PR3: 集約・インデックス（H1 + M1）

### [ ] H1-a — `available*` のインクリメンタル更新
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:889-893`
- 新規 stored: `availableExtensionsSet` / `Cameras` / `Lenses` / `Artists` の `Set<String>` × 4
- `ingest` (行 1189-1204) で初期化 + 拡張子登録
- `metaFlushTask` flush 時 (行 1107 周辺) に `flushedExif` 走査 → `Set.insert` 戻り値が true のときだけ配列再 sort
- `deleteSelectedGroups` (行 604-616) で関係 Set/配列の rebuild
- `recomputeAggregates` 行 890-893 の 4 行を削除

### [ ] H1-b — 5 軸 histogram 統合
- `Models/FilterCriteria.swift` に `func matches(entry:exif:xmp:exclude: HistogramAxis? = nil) -> Bool` を追加（既存 `matches` と統合、デフォルト引数）
- `LibraryStore` に `recomputeHistogramBuckets(reps:)` を新設、reps を 1 周しながら 5 軸の `matchesExcept` を判定 → 各 bucket カウンタへ振り分け
- `bucketIndex(for:specs:)` を抽出して 4 量的軸（ISO/focal/shutter/aperture）で再利用
- `filteredIDsExcluding` (行 873-887) を削除

### [ ] M1 — `visibleIndex` キャッシュ
- 新規 stored: `private var visibleIndex: [UInt64: Int] = [:]`
- `recomputeVisible` 末尾で `visibleIndex = Dictionary(uniqueKeysWithValues: visibleIDs.enumerated().map { ($1, $0) })`
- `rangeSelect` / `rangeNavigate*` / `navigateNext` / `Prev` / `Up` / `Down` / `First` / `Last` の `visibleIDs.firstIndex(of:)` を `visibleIndex[id]` に置換（10 箇所程度）
- `cyclePairVariant` (行 452-461) のグループ内 firstIndex は対象外

---

## PR4: `recomputeVisible` キャッシュ（M3）— 慎重に

### [ ] 3 段キャッシュ導入
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:718-742`
- 新規 stored: `cachedReps` / `cachedFiltered` / `cachedRepsKey: RepsKey?` / `cachedFilteredKey: FilteredKey?`
- `RepsKey` = `Hashable` 小 struct（`shotGroups.count`, `orderedIDs.count`, `filter.flatten`, `filter.filterKinds`）
- `FilteredKey` = `RepsKey` + `filter` ハッシュ
- Stage A (reps) / Stage B (filtered) / Stage C (sort + visibleIndex + dailyGroups + aggregates) に分解

### [ ] invalidation
- `filter` didSet → `cachedFilteredKey = nil`
- `mergeExifBatch` / `setXmp` flush → `cachedFilteredKey = nil`
- `applyReindexedGroups` / `ingest` / `deleteSelectedGroups` → 両方 nil
- `applyRating` / `applyLabel` 直前 → `cachedFilteredKey = nil`
- `applyOrder()` → invalidate なし（Stage C のみ走る）

**最小スコープから始める**: 最初は「sort 切替で Stage A/B 再利用」だけで様子を見て、問題なければ他の invalidation を追加。

---

## PR5: バッチ ID Set 通知（H5）

### [ ] Subject 型変更
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:67-69`
- `PassthroughSubject<UInt64, Never>` → `PassthroughSubject<Set<UInt64>, Never>` に変更（thumbnail / exif / xmp の 3 つ）

### [ ] 送信側のバッチ化
- `setThumbnail` の flush (行 1078-1080): `for id in flushed.keys { send(id) }` を `send(Set(flushed.keys))` に
- `scheduleMetaFlush()` flush (行 1115-1117) も同様（exif / xmp）

### [ ] 受信側の更新
- ファイル: `xcode/BridgeLite/BridgeLite/Views/ThumbnailCellView.swift:73-81`
- `.filter { $0 == self.entry.id }` → `.filter { $0.contains(self.entry.id) }`
- 購読箇所が ThumbnailCellView のみであることを再確認（grep）

---

## PR6: 残り（M5 + M11 + M8 + M13）

### [ ] M5 — `propagationMatrix` を stored 化
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/SettingsStore.swift:145-154`
- computed property を削除し `private(set) var propagationMatrix: PropagationMatrix` を stored 化
- 関連 6 boolean の didSet (行 126-143) で `propagationMatrix = PropagationMatrix(...)` を更新
- `init()` で初期値を組み立て

### [ ] M11 — `LoadProgressTracker` actor で MainActor hop 削減
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:310-322` / `Pipelines/ThumbnailPipeline.swift:62`
- 新規 actor `LoadProgressTracker { private var count = 0; func increment() -> Int { ... } func reset() { count = 0 } }`
- `LibraryStore` に `private let progressTracker = LoadProgressTracker()`
- `ThumbnailPipeline.loadOne` 末尾を `let n = await store.progressTracker.increment(); if n % 50 == 0 { await store.updateLoadStatus(loaded: n) }` に変更
- `LibraryStore.updateLoadStatus(loaded:)` を MainActor isolated で残す（50 件単位のみ MainActor）
- `reset()` で actor 状態リセット

### [ ] M8 — NSWindow 通知を object フィルタで絞り込む
- ファイル: `xcode/BridgeLite/BridgeLite/Views/ContentView.swift:21-28`
- `NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: nsWindow)` のように `object:` で window を指定して絞り込む
- `guard ... === nsWindow else { return }` を削除
- `bridgeLiteOpenURL` 通知は維持

### [ ] M13 — `suspend` / `resume` 軽量化
- ファイル: `xcode/BridgeLite/BridgeLite/Stores/LibraryStore.swift:1135-1147`
- `suspend()` から `thumbnailBlobs = [:]` と `ThumbnailDecodeCache.shared.evictAll()` を削除
- `resume()` 先頭に `guard thumbnailBlobs.isEmpty else { return }` を追加（既にロード済みなら no-op）
- 新規 stored: `private var memoryPressureSource: DispatchSourceMemoryPressure?`
- `init` または `openDirectory` 完了時に `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)` を起動
- イベント発火時に **非アクティブタブのみ** evict（`nsWindow?.isKeyWindow == false`）
- タブ閉じ時 (`reset()`) に `memoryPressureSource?.cancel()` でリーク防止

---

## CLAUDE.md 遵守事項

- `TapGesture(count: 2)` 同居 / spring / ホットパス `print` / body 内 `DateFormatter()` を新規導入しない
- UI 文字列は追加しない想定。万一追加する場合は `String(localized:defaultValue:)` 形式で xcstrings の ja/en 両方に登録（`isJa` 三項演算子は禁止）
- ⌘B / ⌘R はユーザー実行（CLI ビルド禁止）

---

## 検証手順（各 PR 適用後にユーザーに依頼）

1. **ビルド** — Xcode ⌘B 警告ゼロ → ⌘R 起動
2. **6000 枚 open** — File→Open Folder、"Counting…" → "Loading X/6000" 進捗が中断なく完走
3. **6000 枚スクロール** — 最上段→最下段、カクつきの有無
4. **フィルタ操作** — Camera / Lens / ISO 範囲 / Date 範囲切替、< 200ms 体感、histogram バー高さ整合
5. **レーティング編集** — 1 枚 `1`〜`5` / `0`、100 枚選択 ⌘star でダイアログ → propagationMatrix 通り
6. **タブ切替** — ⌘T で新タブ・別フォルダ open、タブ間切替で **再ロードなしで即時表示**（M13 後）、元タブの選択保持
7. **回帰** — ⌘C コピー、Delete→⌘Z、Space で Viewer→Esc、複数タブでメモリ膨張なし

---

## 想定リスク

- **PR4 (M3)** がもっとも危険。invalidation 漏れで「レーティングしても表示が変わらない」など UI 不整合 → 最小スコープから段階導入
- **PR5 (H5)** Subject 型変更で他購読者の有無を再確認（現状 `ThumbnailCellView` のみ確認済み）
- **PR6 (M13)** メモリ pressure source の `cancel()` 漏れ → タブ閉じ時の解放を必ず確認
- **PR3 (H1-a)** インクリメンタル更新の削除パス漏れ → `deleteSelectedGroups` で 4 セット rebuild を明示

---

## 参考: 軽微（スコープ外、L1〜L11）

将来的に余裕があれば対応:

- L1: `PhotoEntry.hasDevelopedSuffix` を init 計算済み stored に
- L2: `ThumbnailCellView.cellContextMenu` の遅延化
- L3: `formattedFileSize` の `ByteCountFormatter` キャッシュ
- L4: `selectionStroke` の `if isSelected` 分岐で内側 stroke を削減
- L5: `.animation(.easeInOut, value: store.filter.flatten)` を grid 全体から外す
- L6: `BridgeCore` Task.detached 多用の整理（特に `isRaw(url:)`、SQLite write のキュー直列化）
- L7: `ConcurrencyLimiter.run` の `defer { Task { release() } }` 同期化
- L8: `PHashPipeline.enqueue` の cancellation 時 `pending` 整合性
- L10: Undo スタックに上限（10〜20）
