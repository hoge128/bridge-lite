# CORE-GUI.md — Rust core + SwiftUI GUI ハイブリッド設計ドキュメント

## 1. 設計原則

### なぜ Rust + SwiftUI 構成で実現できるか

CLAUDE.md に定めた 5 つの設計原則は、Rust core + SwiftUI GUI のハイブリッド構成によって以下のように実現される。

#### 1-1. 閲覧・分析・評価に徹する

Rust core は画像の解析・インデックス・評価ロジックを持つが、現像・編集・書き出しの API を一切持たない。SwiftUI 側も `CGImageSource` による表示に徹し、ピクセル変換やフィルタ適用は実装しない。「現像はしない」という制約をアーキテクチャのレイヤ境界で強制できる。

#### 1-2. ファイルは絶対に変更しない（XMP レーティングを除く）

`write_xmp` は Rust core が `write → fsync → atomic rename (tmp → dst) → setattrlist(btime 復元)` の順序で実行する。この 4 ステップが完全に Rust 側に閉じているため、SwiftUI 側のコードがうっかりファイルを書き換える経路が構造的に存在しない。SwiftUI は Rust 関数を呼ぶだけで、ファイルパスを直接 `FileManager` に渡す処理を持たない。

#### 1-3. RAW+JPG を一枚の写真として扱う

`ShotGroup` は Rust の `pairing.rs` (Phase 1–4 Union-Find アルゴリズム) が生成し、`reindex_shot_groups` で更新される。SwiftUI 側の `LibraryStore` はこのグループ情報を `PhotoEntry` の配列として受け取るだけで、ペアリングロジックを知る必要がない。RAW/JPG/現像バリアント間の切り替えは Swift 側の `ShotGroup.variant(at:)` が担うが、そのデータ構造は Rust から供給される。

#### 1-4. macOS ネイティブ API で限界まで高速化する

Rust core は SQLite (WAL モード) と低レベルな EXIF 解析を担当し、SwiftUI 側は `CGImageSource` / `ImageIO` / `NSCache` をフルに使う。FFI 境界ではサムネイル JPEG バイト列 (`Vec<u8>`) を渡すため、CGImage 生成は常に Swift 側で行われ、ハードウェアデコーダ (ISP) が自動的に活用される。Rust 側でソフトウェアデコードした中間イメージを Bridge 越しに渡すという非効率が生じない。

#### 1-5. メタデータは読む、書かない（XMP レーティングを除く）

Adobe XMP Toolkit の Rust バインディングを bridge-core のみが保持し、Swift 側は XMP ファイルを直接パースしない。`XmpStore` actor は楽観更新 (Rust 呼び出し前に UI を更新) → Rust `write_xmp` 完了後に確定 → 失敗時 revert という厳格なフローを持つが、XMP バイト列の実際の読み書きは常に Rust 層で完結する。

### Core / GUI 分離原則

```
Rust (bridge-core / bridge-ffi)
  ファイルアクセス、EXIF/XMP 解析、永続化 (SQLite)、
  ハッシュ計算 (pHash DCT)、shot grouping アルゴリズム、btime 保全

Swift (SwiftUI app)
  CGImageSource によるサムネイル・フルレズ生成
  NSCache による RAM キャッシュ (L1)
  全 UI レンダリング・ユーザー操作ハンドリング
  LocalizedError によるユーザー向けエラーメッセージ
  OS 統合 (CommandMenu, onKeyPress, OSLog, NSOpenPanel)
```

この分離により、将来的に GUI を AppKit / Tauri 等に差し替えても bridge-core は無変更で済む。逆に Rust 側のアルゴリズムを改善しても SwiftUI 側の UI コードには触れない。

### 「中途半端な FFI 用型を作らない」原則

`FfiImageEntry` (bridge-ffi が生成する C 互換構造体) は FFI 境界でのみ存在し、Swift に渡った瞬間に `PhotoEntry` (純 Swift 型) へ変換して消える。

```swift
// BridgeCore.swift (Bridging レイヤ)
extension PhotoEntry {
    init(_ ffi: FfiImageEntry) {
        self.id       = ffi.id
        self.path     = URL(filePath: String(ffi.path))
        self.shotId   = ffi.shot_id
        self.isRaw    = ffi.is_raw
        self.fileSize = ffi.file_size
    }
}
```

`FfiImageEntry` が Swift のビジネスロジック層に漏れ出ることはない。`ShotGroup` の組み立てや `FilterCriteria` の評価はすべて `PhotoEntry` を使って行われる。

### 「コア層は GUI ライブラリへ依存しない」原則

`bridge-core` の `Cargo.toml` に `iced`, `muda`, `image` (GUI 経路) の依存は一切入れない。`image` クレートは現状の iced-app で使われているが、bridge-core では RAW 埋め込み JPEG を `Vec<u8>` で返すだけで、デコードは Swift 側の `CGImageSource` が行う。これにより `cargo tree -p bridge-core` の出力が軽量に保たれ、Linux 移植時のコンパイル時間も短縮できる。

---

## 2. アーキテクチャ概観

### 三層モデル

```
┌─────────────────────────────────────────────┐
│  SwiftUI app (Xcode)                        │
│  Views / Stores / Pipelines / Models        │
│  CGImageSource / NSCache / ImageIO          │
└──────────────────┬──────────────────────────┘
                   │ swift-bridge 自動生成コード
┌──────────────────▼──────────────────────────┐
│  bridge-ffi  (Rust staticlib)               │
│  #[swift_bridge::bridge] API 定義           │
│  FfiImageEntry などの FFI 型                │
└──────────────────┬──────────────────────────┘
                   │ Rust 関数呼び出し
┌──────────────────▼──────────────────────────┐
│  bridge-core  (Rust lib)                    │
│  scanner / pairing / metadata / xmp / db    │
│  phash / btime / raw_thumb / error          │
│                  │                          │
│    Adobe XMP Toolkit SDK (C++)              │
│    kamadak-exif / rusqlite / walkdir        │
└─────────────────────────────────────────────┘
```

### 依存方向

```
SwiftUI → bridge-ffi → bridge-core → Adobe XMP Toolkit SDK (C++)
```

逆方向 (bridge-core → iced など) は禁止。Swift 型が Rust の `#[repr(C)]` 構造体に依存することも、`bridge-ffi` 経由以外では行わない。

### ディレクトリ構成

```
bridge-lite/
├── Cargo.toml                  # ワークスペースルート
├── crates/
│   ├── bridge-core/            # Rust lib (純粋ロジック)
│   │   ├── Cargo.toml
│   │   ├── src/
│   │   │   ├── lib.rs
│   │   │   ├── error.rs        # CoreError / CoreErrorId
│   │   │   ├── scanner.rs
│   │   │   ├── pairing.rs
│   │   │   ├── metadata.rs
│   │   │   ├── btime.rs
│   │   │   ├── raw_thumb.rs
│   │   │   ├── xmp.rs
│   │   │   ├── db.rs
│   │   │   └── phash.rs
│   │   └── tests/              # 統合テスト (25件以上)
│   ├── bridge-ffi/             # Rust staticlib + swift-bridge
│   │   ├── Cargo.toml
│   │   ├── build.rs            # swift-bridge-build でコード生成
│   │   └── src/lib.rs
│   └── iced-app/               # 移行期に維持 (Phase G で削除)
│       ├── Cargo.toml
│       └── src/
├── vendor/
│   └── xmp_toolkit/            # macOS 26 RawCameraException パッチ済み
├── xcode/
│   └── BridgeLite/
│       ├── BridgeLite.xcodeproj
│       └── BridgeLite/
│           ├── Bridging/
│           │   └── BridgeCore.swift  # FfiImageEntry → PhotoEntry 変換
│           ├── Models/
│           │   ├── PhotoEntry.swift
│           │   ├── ExifData.swift
│           │   ├── XmpData.swift
│           │   ├── ShotGroup.swift
│           │   └── FilterCriteria.swift
│           ├── Stores/
│           │   ├── LibraryStore.swift
│           │   ├── ThumbnailStore.swift
│           │   ├── ExifStore.swift
│           │   └── XmpStore.swift
│           ├── Pipelines/
│           │   ├── ScanPipeline.swift
│           │   ├── ThumbnailPipeline.swift
│           │   ├── PHashPipeline.swift
│           │   └── PairingPipeline.swift
│           ├── Views/
│           │   ├── ContentView.swift
│           │   ├── ThumbnailGridView.swift
│           │   ├── SidebarView.swift
│           │   ├── ViewerView.swift
│           │   ├── FilterPanelView.swift
│           │   ├── SettingsView.swift
│           │   └── AboutView.swift
│           └── Resources/
│               └── Localizable.xcstrings
└── tools/
    └── build-rust-xcframework.sh
```

### 「消滅するファイル」リスト (Phase G 完了時)

以下のファイルは SwiftUI 移行完了後に削除される:

| ファイル | 理由 |
|---|---|
| `src/app.rs` | iced アプリケーション本体。SwiftUI に置換 |
| `src/menu.rs` | muda ベースのメニュー。CommandMenu に置換 |
| `src/i18n.rs` | 独自 i18n。Localizable.xcstrings に置換 |
| `src/theme.rs` | iced テーマ。SwiftUI のカラースキームに置換 |
| `src/memory_guard.rs` | iced/wgpu メモリ問題の回避策。根本消滅 |
| `src/macos_thumb.rs` | iced 向けサムネ生成。ThumbnailPipeline に置換 |
| `macos/cgimage_shim.cpp` | C++ ブリッジ。Swift 直接呼び出しに置換 |

### サードパーティ所属

**Rust 側 (bridge-core / bridge-ffi)**
- Adobe XMP Toolkit SDK (C++, vendor 済み)
- kamadak-exif — EXIF パース
- image_hasher — pHash 計算補助
- rusqlite — SQLite アクセス (WAL モード)
- walkdir — ディレクトリ走査

**Swift 側 (Xcode)**
- ImageIO / CGImageSource — サムネイル・フルレズ生成
- QuickLookThumbnailing — 補助的なサムネイル生成
- NSCache — RAM キャッシュ (L1)
- swift-bridge — Rust FFI 自動生成
- OSLog / Logger — ログ

---

## 3. 責務分離

### Rust core が持つもの

```rust
// scanner.rs
pub fn scan_directory(path: &Path) -> Result<Vec<ImageEntry>, CoreError>

// pairing.rs
pub fn reindex_shot_groups(
    entries: &[ImageEntry],
    exif: &HashMap<usize, ExifData>,
    phashes: &HashMap<usize, u64>,
) -> Vec<ShotGroup>

// phash.rs
/// 32×32 grayscale luma バイト列 (1024 bytes) を受け取り DCT pHash を返す
pub fn compute_phash_from_luma_32x32(luma: &[u8; 1024]) -> u64

// xmp.rs
pub fn read_xmp(path: &Path) -> Result<XmpData, CoreError>
pub fn write_xmp(path: &Path, data: &XmpData) -> Result<(), CoreError>

// btime.rs
pub fn preserve_btime(path: &Path, btime: i64) -> Result<(), CoreError>

// db.rs
pub fn open_database(db_path: &Path) -> Result<Database, CoreError>
pub fn fetch_exif_batch(db: &Database, ids: &[u64]) -> Vec<(u64, ExifData)>
pub fn index_exif(db: &Database, entry: &ImageEntry) -> Result<ExifData, CoreError>
pub fn fetch_cached_thumbnail(db: &Database, id: u64, mtime: i64) -> Option<Vec<u8>>
pub fn store_cached_thumbnail(db: &Database, id: u64, mtime: i64, jpeg: &[u8]) -> Result<(), CoreError>
pub fn fetch_phash_batch(db: &Database, ids: &[u64]) -> Vec<(u64, u64)>
pub fn store_phash(db: &Database, id: u64, mtime: i64, hash: u64) -> Result<(), CoreError>

// raw_thumb.rs
pub fn extract_raw_embedded_jpeg(path: &Path) -> Result<Vec<u8>, CoreError>
```

### Rust core が持たないもの

- UI 文字列・エラーメッセージのロケール (Swift の Localizable.xcstrings が担う)
- `CGImageSource` / `CGImage` / `NSCache` の呼び出し (Swift 側に完全に委譲)
- DB ファイルパスの解決 (`dirs-next` は bridge-core から除去。`db_path: &Path` を引数で受ける)
- ImageIO フレームワークとの直接連携
- `AVFoundation` の呼び出し

### Swift が持つもの

```swift
// ThumbnailPipeline.swift
func generateThumbnail(for entry: PhotoEntry, size: CGSize) async throws -> CGImage {
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
    ]
    let src = CGImageSourceCreateWithURL(entry.path as CFURL, nil)!
    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)!
}

// XmpStore.swift — 楽観更新フロー
func setRating(_ rating: Int, for entry: PhotoEntry) async throws {
    let old = current(entry)
    optimisticUpdate(entry, rating: rating)   // UI 即反映
    do {
        try await BridgeCore.writeXmp(path: entry.path, rating: rating)
    } catch {
        revert(entry, to: old)                 // 失敗時に戻す
        throw error
    }
}
```

- `LocalizedError` の訳語 (`CoreErrorId` で switch → `xcstrings` キーを引く)
- `Localizable.xcstrings` (ja/en 完備)
- `CommandMenu` / `CommandGroup` / `.onKeyPress` によるキーバインド
- `NSOpenPanel` によるフォルダ選択

### Swift が持たないもの

- XMP バイト列のパース・書き込み (Adobe XMP Toolkit 経由の Rust が担当)
- SQLite への直接アクセス (すべて bridge-ffi 経由)
- shot grouping の Union-Find アルゴリズム (pairing.rs)
- pHash の DCT 計算 (`compute_phash_from_luma_32x32`)
- `btime` 保全のための `setattrlist` 呼び出し (btime.rs)

---

## 4. データフロー

### ディレクトリスキャン

```
[Swift] NSOpenPanel で URL 取得
    ↓
[Rust] scan_directory(path: &Path) → Vec<ImageEntry>
    - walkdir で再帰走査
    - RAW_EXTENSIONS スライスで is_raw 判定
    - file_size / mtime 取得
    ↓
[Swift] BridgeCore.swift で FfiImageEntry → PhotoEntry に変換 (1回マッピング)
    ↓
[Swift] LibraryStore.entries に格納
    ↓
[Swift] ThumbnailGridView が LazyVGrid でレンダリング開始
```

### EXIF 取得

```
[Swift] ExifStore.fetchBatch(ids: [UInt64])
    ↓
[Rust] fetch_exif_batch(db, ids) → Vec<(u64, ExifData)>  ← DB キャッシュから一括取得
    ↓
    キャッシュミス分のみ:
[Rust] index_exif(db, entry) → ExifData  ← kamadak-exif でファイル読み
    - EXIF_SCHEMA_VERSION (v3) チェック → バージョン違いで全行削除
    ↓
[Swift] ExifStore (actor) に保存 → SidebarView へ通知
```

### XMP 読み書き

```
読み取り:
[Rust] read_xmp(path)
  - RAW (.arw/.cr3/.nef/...) → .xmp サイドカーのみ
  - 非 RAW (.jpg/.heif/...)  → 埋め込み優先、サイドカーフォールバック
  - すべて Adobe XMP Toolkit SDK 経由でパース
  → XmpData { rating, label, flag, label_color }

書き込み:
[Swift] XmpStore.setRating → 楽観更新
  → [Rust] write_xmp(path, data)
     1. tmp ファイルへ書き込み (Adobe XMP Toolkit)
     2. fsync
     3. atomic rename (tmp → dst)
     4. setattrlist(ATTR_CMN_CRTIME) で btime 復元
  → 成功: DB の xmp キャッシュ更新
  → 失敗: Swift 側が revert
```

### サムネイル三層キャッシュ

```
[Swift] ThumbnailStore.thumbnail(for entry: PhotoEntry)

L1 NSCache (RAM, CGImage)
  ヒット → CGImage を返す

L2 SQLite (disk, JPEG bytes)
  [Rust] fetch_cached_thumbnail(db, id, mtime)
  ヒット → JPEG bytes を Swift に返す → CGImageSource でデコード → NSCache 追加

L3 ImageIO 生成 (Swift)
  - 通常ファイル: CGImageSourceCreateThumbnailAtIndex
  - RAW ファイル: extract_raw_embedded_jpeg (Rust) → CGImageSource でデコード
  → CGImage を NSCache 追加
  → JPEG エンコード → [Rust] store_cached_thumbnail で SQLite に書き戻し
```

### pHash 計算フロー

```
[Swift] PHashPipeline
  1. ThumbnailStore から 32×32 CGImage を取得
  2. CGBitmapContext で BGRA → luma 変換 (ITU-R BT.601)
     let luma = r * 0.299 + g * 0.587 + b * 0.114
  3. [u8; 1024] の luma 配列を bridge-ffi 経由で Rust へ
  4. [Rust] compute_phash_from_luma_32x32(&[u8; 1024]) → u64 (DCT 平均ビット)
  5. [Rust] store_phash(db, id, mtime, hash)
```

### Shot grouping タイミング

```
PairingPipeline
  - exif_done_count と phash_done_count を監視 (watermark カウンタ)
  - 両方が entries.count と一致した時点で reindex_shot_groups を 1 回だけ実行
  ↓
[Rust] reindex_shot_groups(entries, exif, phashes) → Vec<ShotGroup>
  - Phase 1: ファイルステム共通グループ (Union-Find)
  - Phase 2: 撮影日時 ±1s でマージ
  - Phase 3: pHash ハミング距離 ≤ 10 でマージ
  - Phase 4: AEB 連写分離 (EV 差チェック)
  ↓
[Swift] LibraryStore.shotGroups 更新 → グリッド再描画
```

### XMP 編集と DB 同期

```
[Swift] XmpStore
  → [Rust] write_xmp  成功
  → [Rust] db::update_xmp でキャッシュ行を最新化
  → [Swift] XmpStore の published state 更新 → SidebarView 反映
```

---

## 5. エラーハンドリング戦略

### CoreError 定義 (Rust)

```rust
// crates/bridge-core/src/error.rs
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("unsupported format: {path}")]
    UnsupportedFormat { path: String },

    #[error("XMP parse error: {0}")]
    XmpParse(String),

    #[error("XMP write error: {0}")]
    XmpWrite(String),

    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),

    #[error("thumbnail decode error: {path}")]
    ThumbnailDecode { path: String },

    #[error("not found: {path}")]
    NotFound { path: String },

    #[error("operation cancelled")]
    Cancelled,
}

/// Swift 側で switch 文に使う識別子
#[repr(u32)]
pub enum CoreErrorId {
    Io              = 1,
    UnsupportedFormat = 2,
    XmpParse        = 3,
    XmpWrite        = 4,
    Db              = 5,
    ThumbnailDecode = 6,
    NotFound        = 7,
    Cancelled       = 8,
}
```

`Result<T, CoreError>` は swift-bridge が自動的に `Swift throws` に変換する。

### Swift 側 LocalizedError

```swift
// BridgeCore.swift
extension BridgeCoreError: LocalizedError {
    var errorDescription: String? {
        switch self.id {
        case .io:               return String(localized: "error.io")
        case .unsupportedFormat: return String(localized: "error.unsupportedFormat")
        case .xmpParse:         return String(localized: "error.xmpParse")
        case .xmpWrite:         return String(localized: "error.xmpWrite")
        case .db:               return String(localized: "error.db")
        case .thumbnailDecode:  return String(localized: "error.thumbnailDecode")
        case .notFound:         return String(localized: "error.notFound")
        case .cancelled:        return nil   // キャンセルはユーザー通知不要
        }
    }
}
```

### ログ方針

| 層 | ログ先 | 言語 | 用途 |
|---|---|---|---|
| Rust (bridge-core) | stderr | 英語固定 | デバッグ。`eprintln!` または `tracing` |
| Swift | `os.Logger` / `OSLog` | アプリのロケール | ユーザー向け診断・Instruments 連携 |

### ファイルパーミッション / ネットワーク切断ケース

`CoreError::Io` として Rust 側で wrap し、swift-bridge 経由で Swift throws に変換。Swift 側の `.alert` で「ファイルにアクセスできませんでした。接続を確認してください。」等のユーザー向けメッセージを表示する。

---

## 6. 並行制御の境界

### Tokio runtime シングルトン

```rust
// crates/bridge-core/src/runtime.rs
use tokio::runtime::Runtime;
use std::sync::OnceLock;

static RT: OnceLock<Runtime> = OnceLock::new();

pub fn handle() -> &'static tokio::runtime::Handle {
    RT.get_or_init(|| {
        Runtime::new().expect("failed to create Tokio runtime")
    }).handle()
}
```

bridge-ffi の初期化時 (アプリ起動直後) に `handle()` を呼んで確保する。アプリ終了時に graceful shutdown を実行する。

### swift-bridge async fn 変換

```rust
// bridge-ffi/src/lib.rs
#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        async fn scan_directory(path: String) -> Result<Vec<FfiImageEntry>, CoreError>;
        async fn fetch_exif_batch(db: &Database, ids: Vec<u64>) -> Vec<FfiExifData>;
        async fn generate_thumbnail(path: String, size: u32) -> Result<Vec<u8>, CoreError>;
    }
}
```

Rust 側の `async fn` が swift-bridge により Swift 側の `async throws` に自動変換される。`ThumbnailPipeline` 等の重い処理を Swift の `Task` から直接 `await` できる。

### Sendable 規約

- Rust 由来の型 (`FfiImageEntry` 等) は値型 Sendable に揃える (`#[repr(C)]` + Copy)。
- `CGImage` は actor 越えで渡す場合は `Data` (JPEG バイト) に変換し、受け取り側で `CGImageSource` から再構築する。
- `PhotoEntry` は `struct` (値型) かつ `Sendable` 準拠。

### Actor 分割

```swift
@MainActor @Observable final class LibraryStore
// グリッド表示データ・選択状態・フィルタ状態を管理

actor ThumbnailStore
// NSCache (L1) + SQLite (L2) の三層キャッシュ制御

actor ExifStore
// EXIF バッチ取得 + キャッシュ

actor XmpStore
// 楽観更新 + Rust 書き戻し + revert

actor ScanPipeline
// walkdir + ImageEntry 生成 + LibraryStore への通知

actor ThumbnailPipeline      // ConcurrencyLimiter MAX=6
// ImageIO サムネ生成 + SQLite 書き戻し

actor PHashPipeline          // ConcurrencyLimiter MAX=4
// 32×32 luma 生成 + Rust DCT 呼び出し + SQLite 保存

actor PairingPipeline
// watermark カウンタ監視 + reindex_shot_groups 実行
```

### ConcurrencyLimiter

```swift
// Semaphore 風の並列度制御
actor ConcurrencyLimiter {
    private let max: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(max: Int) { self.max = max }

    func acquire() async {
        if running < max { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            running -= 1
        }
    }
}
// THUMB = ConcurrencyLimiter(max: 6)
// PHASH = ConcurrencyLimiter(max: 4)
```

### キャンセル伝播

Swift の `Task.cancel` が呼ばれると、bridge-ffi 経由で Rust 側の `CancellationToken` に通知が伝播する設計。長時間実行の `scan_directory` や `reindex_shot_groups` はキャンセルポイントを設け、`CoreError::Cancelled` を返す。

---

## 7. キャッシュ戦略

### 三層構造

```
L1: NSCache (RAM)
  - キー: PhotoEntry.id (UInt64)
  - 値:   CGImage (非圧縮 RGB)
  - 上限: NSCache が OS メモリ圧に応じて自動 evict
  - TTL:  なし (OS に委ねる)

L2: SQLite thumbnails テーブル (disk)
  - キー: (image_id, mtime)  ← mtime 変化で自動 invalidation
  - 値:   JPEG bytes (BLOB)
  - 管理: Rust db.rs が担当
  - スキーマ: CREATE TABLE thumbnails (image_id INTEGER, mtime INTEGER, jpeg BLOB, PRIMARY KEY (image_id))

L3: ImageIO 生成 (Swift, on-demand)
  - CGImageSourceCreateThumbnailAtIndex (通常ファイル)
  - extract_raw_embedded_jpeg → CGImageSource (RAW ファイル)
  - 生成後 → L2 に書き戻し → L1 に追加
```

### EXIF invalidation

```rust
// db.rs
const EXIF_SCHEMA_VERSION: u32 = 3;

pub fn open_database(db_path: &Path) -> Result<Database, CoreError> {
    // ...
    let stored_ver: u32 = /* meta テーブルから取得 */;
    if stored_ver != EXIF_SCHEMA_VERSION {
        db.execute("DELETE FROM exif_cache", [])?;
        db.execute("UPDATE meta SET value=? WHERE key='exif_schema_version'",
                   [EXIF_SCHEMA_VERSION])?;
    }
}
```

### pHash invalidation

キー = `(path, mtime)`。`mtime` が変化していれば DB から pHash を読まず再計算する。

### pipeline_version によるサムネイル全削除

```sql
-- meta テーブル
INSERT OR REPLACE INTO meta VALUES ('pipeline_version', '2');
```

`pipeline_version` が更新された場合 (サムネイル生成アルゴリズム変更等)、`DELETE FROM thumbnails` をトリガーする。

---

## 8. ライフサイクル管理

### Database RAII

```swift
// LibraryStore.swift
final class DatabaseHandle {
    private let handle: OpaquePointer  // Rust Database*

    init(path: URL) throws {
        handle = try BridgeCore.openDatabase(path: path)
    }

    deinit {
        BridgeCore.closeDatabase(handle)  // Rust 側 drop を呼ぶ
    }
}
```

### メモリ管理

- `NSCache` が OS メモリ圧で CGImage を自動 evict する。上限は設定せず OS に委ねる。
- フルレズ (`ViewerView`) は `@State var fullResImage: CGImage? = nil` とし、ビューア終了 (`onDisappear`) で `nil` 代入して ARC で即解放する。
- Rust 側で `Vec<u8>` を返す場合、swift-bridge が Swift の `Data` に変換してコピーが発生するが、サムネイルサイズ (≤ 50 KB) では問題にならない。

### ファイル書き込みの安全シーケンス

```rust
// btime.rs + xmp.rs の協調
pub fn write_xmp(path: &Path, data: &XmpData) -> Result<(), CoreError> {
    let btime = get_btime(path)?;             // 1. btime を退避
    let tmp = path.with_extension("xmp.tmp");
    write_to_file(&tmp, data)?;               // 2. tmp へ書き込み
    fsync_file(&tmp)?;                        // 3. fsync
    std::fs::rename(&tmp, xmp_path(path))?;  // 4. atomic rename
    preserve_btime(xmp_path(path), btime)?;  // 5. btime 復元
    Ok(())
}
```

### Tokio runtime shutdown

```swift
// BridgeLiteApp.swift
.onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
    BridgeCore.shutdownRuntime()  // Rust 側の graceful shutdown
}
```

### memory_guard.rs が不要な理由

`memory_guard.rs` は iced + wgpu が GPU テクスチャを蓄積し続ける問題への緊急回避策だった。SwiftUI 構成ではこの問題が根本から消滅する:

1. `iced`/`wgpu` を使わないため GPU テクスチャ蓄積問題が発生しない
2. `CGImageSource` は `kCGImageSourceShouldCache: false` でシステムキャッシュを使わない
3. `NSCache` が OS のメモリ圧に応じて自動 purge する

---

## 9. テスト戦略

### Rust unit / integration テスト

```
crates/bridge-core/tests/
├── pairing_test.rs    # 9件: AEB 連写/ステム共通/タイムスタンプ分割 等
├── xmp_test.rs        # 8件: roundtrip/LabelColor/埋め込み/サイドカー 等
├── scanner_test.rs    # 5件: 拡張子フィルタ/隠しファイル除外 等
└── phash_test.rs      # 3件: 同一画像/高類似/全異なる ハミング距離検証
```

実行コマンド:

```sh
cargo test -p bridge-core
```

### Rust にとどめるべきテスト

- **XMP roundtrip**: `xmp:Rating` / `xmp:Label` / `photoshop:LabelColor` の読み書きが一致すること
- **btime 保全**: `write_xmp` 前後で `st_birthtime` が変化しないこと
- **Shot grouping 正確性**: AEB 連写 (EV +1.0 / 0.0 / -1.0) が 1 つのグループにまとまり、別シーンで分割されること
- **RAW IFD 抽出**: `DSE06383.ARW` の埋め込み JPEG バイト列が正常に抽出できること

### Swift XCTest

```swift
// ThumbnailTests.swift
func testThumbnailGeneration() throws {
    let url = Bundle(for: type(of: self)).url(forResource: "DSE06419", withExtension: "JPG")!
    let image = try ThumbnailPipeline.generateSync(url: url, maxPixel: 200)
    XCTAssertEqual(image.width, 200)
    XCTAssertTrue(image.height <= 200)
}

// FilterTests.swift
func testFilterByRating() {
    let entries = [
        PhotoEntry.stub(rating: 3),
        PhotoEntry.stub(rating: 5),
        PhotoEntry.stub(rating: 0),
    ]
    let criteria = FilterCriteria(ratings: [3, 5])
    XCTAssertEqual(entries.filter { criteria.matches($0) }.count, 2)
}
```

### シナリオテスト

```sh
# ~/work/bridge-lite/test/20260221 ディレクトリでスキャン
# iced 版と SwiftUI 版の shot_groups 件数が一致することを確認
cargo run -p bridge-lite-iced -- --scan ~/work/bridge-lite/test/20260221 --dump-groups | wc -l
xcodebuild test -scheme BridgeLite -only-testing BridgeLiteTests/ShotGroupCountTests
```

### Adobe Bridge 相互運用テスト

| ファイル | 検証内容 |
|---|---|
| `test/20260221/DSE06383.xmp` | `photoshop:LabelColor="red"` → Swift 側で `XmpLabel.red` |
| `test/20260221/DSE06419.JPG` | 埋め込み `xmp:Rating="3"` → Swift 側で `rating == 3` |

---

## 10. macOS API 利用方針

### ImageIO

```swift
let options: [CFString: Any] = [
    kCGImageSourceShouldCache:                    false,   // システムキャッシュ不使用
    kCGImageSourceCreateThumbnailWithTransform:   true,    // EXIF 回転自動適用
    kCGImageSourceThumbnailMaxPixelSize:          200,
    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,  // 埋め込みサムネなければ生成
]
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
```

`kCGImageSourceShouldCache: false` で ImageIO のシステムキャッシュを切り、メモリ管理を `NSCache` に一元化する。`kCGImageSourceCreateThumbnailWithTransform: true` でサムネイル生成時に EXIF 回転を自動適用し、表示ロジックを簡略化する。

フルレズ表示:

```swift
let fullOptions: [CFString: Any] = [
    kCGImageSourceShouldCache:   false,
    kCGImageSourceShouldCacheImmediately: true,
]
let full = CGImageSourceCreateImageAtIndex(src, 0, fullOptions as CFDictionary)
```

### QuickLookThumbnailing

`CGImageSource` で対応できないファイル形式 (一部動画、Pages 文書等) のサムネイルを補助的に取得する可能性がある。現時点では必須ではない。

### RawCamera 例外問題への二段防御

macOS 26 で `RawCameraException` が発生する問題への対応:

```
第一防衛ライン (Swift):
  ThumbnailPipeline がファイル拡張子でホワイトリスト判定
  if RAW_EXTENSIONS.contains(ext) {
      → ImageIO ではなく BridgeCore.extractRawEmbeddedJpeg にルーティング
  }

第二防衛ライン (Rust):
  extract_raw_embedded_jpeg が RAW IFD から埋め込み JPEG バイトを抽出
  → 失敗した場合も CoreError::ThumbnailDecode で明示的にエラー
  → Swift 側でプレースホルダ画像を表示
```

vendor 済みの `xmp_toolkit` には macOS 26 `RawCameraException` パッチが適用されているが、`CGImageSource` の RAW デコードは別問題として対処する。

### setattrlist (btime 保全)

```rust
// btime.rs
pub fn preserve_btime(path: &Path, btime: i64) -> Result<(), CoreError> {
    use libc::{setattrlist, attrlist, ATTR_CMN_CRTIME, timespec};
    // ATTR_CMN_CRTIME で st_birthtime を復元
    // Swift 側からこの関数を直接呼ぶ必要はない
}
```

Swift 側から `setattrlist` を呼ぶ必要はなく、Rust の `write_xmp` フロー内部に完全に閉じている。

### xattr / Spotlight

現時点では触らない。将来的に Spotlight インデックスへのメタデータ提供や Finder ラベルとの同期を検討する余地はあるが、現バージョンのスコープ外。

---

## 11. 拡張性

### bridge-core の Linux / Windows 移植

| モジュール | macOS 専用か | 代替 |
|---|---|---|
| `sqlite` (rusqlite) | No | そのまま使用可 |
| `tokio` | No | そのまま使用可 |
| `kamadak-exif` | No | そのまま使用可 |
| `btime.rs` (`setattrlist`) | Yes | `cfg(target_os = "macos")` で切り替え |
| Adobe XMP Toolkit | No (Win/Linux build あり) | `cfg` でプラットフォーム選択 |
| `raw_thumb.rs` | No | そのまま使用可 |

```rust
// btime.rs
pub fn preserve_btime(path: &Path, btime: i64) -> Result<(), CoreError> {
    #[cfg(target_os = "macos")]
    { /* setattrlist */ }
    #[cfg(not(target_os = "macos"))]
    { Ok(()) }  // 他 OS では btime 保全をスキップ
}
```

### 別 GUI への差し替え

bridge-ffi の `#[swift_bridge::bridge]` 定義を別の FFI 層 (例: `cbindgen` 生成の C ヘッダ for Tauri) に書き直すだけで、bridge-core は完全に無変更で利用できる。

### 新規 RAW フォーマット追加

```rust
// scanner.rs
pub const RAW_EXTENSIONS: &[&str] = &[
    "arw", "cr2", "cr3", "nef", "orf", "rw2", "raf", "dng", "pef", "srw",
    // ↑ 新フォーマットをここに追加
];
```

`raw_thumb.rs` の IFD パーサで埋め込み JPEG の offset が異なる場合は `RawFormat` enum に追加してフォーマット別パスを実装する。
