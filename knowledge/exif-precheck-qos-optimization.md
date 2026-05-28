# EXIF プリチェック高速化と Phase N/5 スキャン進捗バナー

## 背景

iOS スキャン中に「Preparing EXIF index…」が長時間表示される問題の調査と修正。  
スキャン進捗バナーの UX 刷新（Phase N/5 表示 + タップで詳細展開）も同時に実施した。

---

## 問題1: EXIF プリチェック（Phase 3）が 16 秒かかる

### 根本原因

`BridgeCore.indexNewEntries` の内部に **隠れた `.utility` タスク**があった。

```swift
// BridgeCore.swift（修正前）
static func indexNewEntries(list: BridgeCoreImageList, db: BridgeCoreDatabase) async {
    await Task.detached(priority: .utility) {   // ← ここが問題
        bridge_index_new_entries(db.inner, list.inner)
    }.value
}
```

`ScanStore.swift` 側で `Task.detached(priority: .userInitiated)` を指定していても、  
実際に Rust コードを実行するのは内側の `.utility` タスクだった。

iOS では `.utility` は他タスクが忙しいとき CPU をほぼ割り当てられない。  
サムネイル読み込み（`.userInitiated`）が走っている間、EXIF プリチェックが  
200枚程度でも 16 秒かかっていた。

### 修正

```swift
// BridgeCore.swift（修正後）
static func indexNewEntries(
    list: BridgeCoreImageList,
    db: BridgeCoreDatabase,
    priority: TaskPriority = .userInitiated   // 引数化、デフォルト .userInitiated
) async {
    await Task.detached(priority: priority) {
        bridge_index_new_entries(db.inner, list.inner)
    }.value
}
```

- iOS（ScanStore）: デフォルト `.userInitiated` を使用
- macOS（LibraryStore）: `.utility` を明示的に渡す（後述）

---

## 問題2: プリチェックのクエリが不必要に重い

### 問題

プリチェックは「この path が EXIF キャッシュに存在するか」を調べるだけなのに、  
`fetch_exif_batch`（全 EXIF カラムを SELECT）を使っていた。

また外側ループのチャンクサイズが 50 のため、2000件で 40 回クエリが発行されていた。

### 修正

**`fetch_cached_paths` を新規追加**（`bridge-core/src/db.rs`）

```rust
pub fn fetch_cached_paths(
    path_mtimes: &[(PathBuf, i64)],
    conn: &Connection,
) -> std::collections::HashSet<PathBuf> {
    // SELECT path, mtime のみ — 全 EXIF カラムの転送を排除
    // 内部で 500 件チャンクに分割して IN 句の上限（999）を回避
}
```

**外側ループを廃止**（`bridge-ffi/src/lib.rs`）

```rust
// 修正前: チャンク 50 件でループ → 2000件で 40 クエリ
for chunk in path_mtimes.chunks(50) {
    let cached = fetch_exif_batch(chunk, &rconn);
    ...
}

// 修正後: 全件を一括で渡す → fetch_cached_paths 内部が 500 件チャンクで処理
let cached_set = bridge_core::db::fetch_cached_paths(&path_mtimes, &rconn);
EXIF_PRECHECK_PROGRESS.store(path_mtimes.len(), Ordering::Relaxed);
```

クエリ数の比較（2000件の場合）:

| 変更前 | 変更後 |
|--------|--------|
| `fetch_exif_batch` × 40回（全カラム SELECT） | `fetch_cached_paths` 内部 × 4回（path/mtime のみ） |

---

## Phase N/5 スキャン進捗バナー刷新

### 設計方針

- バナーには **実行中の最も番号が小さい Phase** を表示する
- 後の Phase が先行して完了しても、前の Phase が終わるまでは前を表示する
- バナーをタップすると全 5 Phase の状態一覧を展開表示（Option B）

### Phase 定義

| Phase | 内容 | 完了条件 |
|-------|------|----------|
| 1 | ディレクトリ走査 | `scanDirectory` 完了（常に done） |
| 2 | ファイル読み込み | `scanLoadedCount >= scanTotalCount` |
| 3 | EXIF キャッシュ確認 | `exifIndexTotal > 0` または `exifIndexTaskDone` |
| 4 | EXIF 索引 | `exifIndexTaskDone` |
| 5 | サムネイル生成 | `isScanning == false` |

### バナー表示ロジック（ThumbnailGridView.swift）

```swift
let phase2Active = scanStore.scanTotalCount == 0 || scanStore.scanLoadedCount < scanStore.scanTotalCount
let phase3Active = !phase2Active && scanStore.exifIndexTotal == 0 && !scanStore.exifIndexTaskDone
let phase4Active = !phase2Active && scanStore.exifIndexTotal > 0 && !scanStore.exifIndexTaskDone
// いずれにも当たらなければ Phase 5
```

### レース対策: exifPrecheckTotal の先行設定

Rust が `EXIF_PRECHECK_TOTAL` を書く前に Swift の最初のポールが走ると 0 を読む。  
その間に Phase 2 が完了すると「Preparing EXIF index…」が X/Y なしで表示される。

**対策**: `indexTask` 起動前に Swift 側で母数を先行設定する。

```swift
// indexTask 起動前
exifPrecheckProgress = 0
exifPrecheckTotal = scannedEntries.count  // Rust より先に設定

let indexTask = Task.detached(priority: .userInitiated) {
    await BridgeCore.indexNewEntries(list: capturedList, db: db)
}
```

### 新規 Rust アトミクス（EXIF プリチェック進捗用）

```rust
// bridge-ffi/src/lib.rs
static EXIF_PRECHECK_PROGRESS: AtomicUsize = AtomicUsize::new(0);
static EXIF_PRECHECK_TOTAL: AtomicUsize = AtomicUsize::new(0);

fn bridge_exif_precheck_progress() -> usize { ... }
fn bridge_exif_precheck_total() -> usize { ... }
```

FFI 公開のため `bridge-ffi.h` と `bridge-ffi.swift` に手動追加が必要  
（`build-rust-ios.sh` は `.h` をコピーするが `.swift` はコピーしない）。

---

## macOS 対応状況

### Boost Mode 連動（後に取り消し）

macOS の `LibraryStore.swift` で `.utility` → `BridgeQoS.scan` に変更したが、  
安定性の問題が確認されたため `.utility` に差し戻した。

```swift
// LibraryStore.swift（現在の状態）
Task.detached(priority: .utility) {
    await BridgeCore.indexNewEntries(list: list, db: db, priority: .utility)
}
```

### Rust 変更（fetch_cached_paths・チャンクレス化）

ソースには取り込まれているが、macOS xcframework はリビルドしていないため未反映。  
`./tools/build-rust-xcframework.sh --release` を実行するまで旧来の動作のまま。

---

## 関連コミット

| コミット | 内容 |
|---------|------|
| `fb700f6` | iOS: Phase N/5 バナー・EXIF プリチェック進捗・fetch_cached_paths・QoS 修正 |
| `5828f85` | Rust: プリチェックのループ廃止・fetch_cached_paths を一括呼び出しに簡素化 |
| `0de9a76` | macOS: BridgeCore.indexNewEntries に priority 引数追加・Boost Mode 連動 |
| `5781a87` | revert(mac): macOS を .utility に差し戻し |
