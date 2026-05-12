# スキャン性能最適化: 無駄な処理の廃止

macOS 版 (SwiftUI) で実施した3つの最適化。Windows 版 (iced) でも同じ無駄が潜在するため、移植時に対応すること。

---

## 1. SQLite バッチ取得（サムネイルキャッシュ）

### 問題

サムネイル表示のたびに SQLite 接続を1件ずつオープンしていた。6000枚なら接続開閉 6000回。

### macOS での修正

- `crates/bridge-core/src/db.rs` に `fetch_thumb_batch(paths, db_path)` を追加
  - IN 句を 500件チャンクに分割してクエリ
  - mtime で更新検出し古いキャッシュは返さない
  - 結果を `HashMap<PathBuf, Vec<u8>>` で返す
- `crates/bridge-core/src/db.rs` に `store_thumb_batch(items, db_path)` を追加
  - 1トランザクションで全件 INSERT OR REPLACE
- `crates/bridge-ffi/src/lib.rs` に `FfiThumbBatch` 型と FFI 関数を追加
  - `bridge_fetch_cached_thumbnails_for_entries(db, entries) -> FfiThumbBatch`
  - `ffi_thumb_batch_count(batch) -> usize`
  - `ffi_thumb_batch_jpeg_at(batch, idx) -> FfiOptionalBytes`
- Swift 側 `ThumbnailPipeline.loadAll()` で最初に一括取得、各エントリには prefetched data を渡す

### Windows 版での対応方針

- `bridge-core` の `fetch_thumb_batch` / `store_thumb_batch` はすでに実装済みのため Rust 側は共用可能
- iced 側のサムネイル読み込みループで個別 DB アクセスをしているなら、スキャン直後に一括取得してキャッシュ Map を構築してから各タスクに渡す
- FFI 経由でなく直接 `bridge-core` のクレートを使う構成なら `fetch_thumb_batch` を直接呼べる

### 効果

- 主に**2回目以降のフォルダ開き直し**で速くなる（キャッシュヒット時の接続コスト削減）
- 初回スキャン（キャッシュ未存在）には効果なし

---

## 2. RAW ファイルの部分読み込み

### 問題

`raw_thumb.rs` と `metadata.rs` の複数関数で `std::fs::read()` によるファイル全体読み込みを行っていた。CR3/NEF/ARW 等は25〜50MB。サムネイル抽出に数KB〜数百KBしか使わないのに全体を RAM に展開していた。

### ファイル形式別の構造と対応

#### CR3（Canon）— ISOBMFF/MP4 ボックス構造

```
ftyp (12B)
moov (数百KB) ← EXIF (CMT1/CMT2 ボックス) と THMB/PRVW JPEG がここ
mdat (20〜50MB) ← 生センサーデータ。絶対に読まない
uuid (PRVW) ← 高解像プレビュー JPEG
```

**対応**: `BufReader<File>` でボックスヘッダ（8B）だけ読み、`mdat` は `seek` でスキップ。`uuid` ボックスのオフセット+サイズだけ記録し、最後に必要な部分のみ `seek`+`read_exact`。

```rust
// ISOBMFF ボックスウォーカーの骨格
let mut pos: u64 = 0;
while pos + 8 <= file_len {
    f.seek(SeekFrom::Start(pos)).ok()?;
    let mut hdr = [0u8; 8];
    f.read_exact(&mut hdr).ok()?;
    let box_size = u32::from_be_bytes(hdr[..4].try_into().unwrap()) as u64;
    let box_type = &hdr[4..8];
    match box_type {
        b"mdat" => { pos += box_size; continue; } // センサーデータはスキップ
        b"uuid" => { /* 16B UUID を読んで PRVW/THMB か判定 */ }
        b"moov" => { /* 内容を読んで CMT1/CMT2 を探す */ }
        _ => {}
    }
    pos += box_size;
}
```

**重要**: `moov` ボックスは 8MB 以上になることはほぼないため `> 8MB` ならスキップするガードを入れる。

#### NEF/ARW/DNG（TIFF ベース）— IFD チェーン構造

```
TIFF ヘッダ (8B): バイトオーダー + IFD0 オフセット
IFD0: タグ一覧 → SubIFD タグ (0x014A) → サブ IFD オフセット
SubIFD: JPEG オフセット (0x0111) + JPEG サイズ (0x0117)
        ← ここだけ seek+read_exact すれば埋め込みJPEGが取れる
```

**対応**: `BufReader` + `Seek` で IFD0 → SubIFD のオフセットチェーンをたどり、JPEG データの開始位置とサイズだけを読む。

```rust
let file = std::fs::File::open(path).ok()?;
let mut f = BufReader::with_capacity(65536, file);
// ヘッダ読み込み → is_le 判定 → IFD0 オフセット取得
// IFD0 エントリをブロック読み → SubIFD タグ (0x014A) を探す
// SubIFD へ seek → JPEG オフセット/サイズタグを探す
// JPEG 位置へ seek → read_exact でバイト列取得
f.seek(SeekFrom::Start(jpeg_off)).ok()?;
let mut buf = vec![0u8; jpeg_len];
f.read_exact(&mut buf).ok()?;
```

#### ORF（Olympus）— 独自 TIFF 拡張

- プレビュー JPEG は**ファイル先頭 10% 以内**に存在する
- EXIF は**先頭 1MB 以内**に収まる

**対応**: `File::take(n)` でバイト数制限付き読み込み。

```rust
// サムネイル: ファイルの10%または 128KB のどちらか大きい方まで
let scan_limit = (file_len / 10).max(128 * 1024);
file.take(scan_limit).read_to_end(&mut data)?;

// EXIF: 1MB まで
let read_limit = file_len.min(1024 * 1024);
file.take(read_limit).read_to_end(&mut data)?;
```

#### RAF（Fujifilm）

- RAF は独自バイナリ構造（TIFF 非準拠）
- プレビュー JPEG のオフセットがヘッダ固定位置に記録されている
- 現状実装を確認の上、全体読みなら同様に部分読みへ移行する

#### JPEG / HEIF

- ImageIO (macOS) や image-rs (Windows) が内部で効率的に処理するため変更不要

### Windows 版での対応方針

- `raw_thumb.rs` と `metadata.rs` の修正は**クレート内に閉じている**ため、そのまま Windows でも有効
- ただし Windows 側で別途 RAW デコードライブラリを使う場合は同じ方針（部分読み）を適用する
- `BufReader<File>` + `Seek` は Windows でも動作する（標準ライブラリ）

### 効果

- メモリ使用量: CR3 1枚あたり 25〜50MB → 数百KB に削減
- ディスク I/O: 速い SSD でも 50MB read は無視できないため、枚数が多いほど効く
- 速度より**安定性・メモリ圧迫回避**が主な目的

---

## 3. 二重ファイルシステム列挙の廃止

### 問題

スキャン前に `runPreScan()` という専用タスクで `FileManager.enumerator`（macOS）を走らせてファイル数を数えていた。直後に Rust の `scan_directory()` でも同じディレクトリを列挙するため、二重スキャンになっていた。

### macOS での修正

`ScanResult` 構造体を Rust 側に追加し、スキャン結果と一緒にファイル数を返す。

```rust
// crates/bridge-core/src/scanner.rs
pub struct ScanResult {
    pub entries: Vec<ImageEntry>,
    pub total_files: usize,  // ディレクトリ内の全ファイル数
    pub image_files: usize,  // 対応画像ファイル数
}

pub fn scan_directory(path: PathBuf) -> ScanResult {
    // 列挙しながら total_files / image_files をカウント
    ScanResult { entries, total_files, image_files }
}
```

FFI 側に `image_entry_list_total_files()` / `image_entry_list_image_files()` を追加して Swift から参照。

`ScanPhase` から `.preScanning` を削除し `.scanning` → `.loading` → `.idle` に簡略化。

### Windows 版での対応方針

- `scanner.rs` の修正は共通のため Windows でも有効
- iced 側に事前列挙処理があれば削除し、`ScanResult` のカウント値を使う
- プログレスバーの「全体枚数」表示も同様に Rust スキャン結果から取得する

### 効果

- スキャン開始時の余分な待ち時間が消える
- コードが単純になる（`runPreScan` / `preScanTask` 等の状態管理が不要）

---

## まとめ: 移植チェックリスト

| 最適化 | Rust 側修正 | macOS UI 側修正 | Windows UI 側 対応要否 |
|---|---|---|---|
| SQLite バッチ取得 | `db.rs` `fetch_thumb_batch` / `store_thumb_batch` 追加済み | `ThumbnailPipeline` で一括 prefetch | iced のサムネイル読み込みループを一括取得に変更する |
| RAW 部分読み込み | `raw_thumb.rs` / `metadata.rs` を BufReader+Seek に変更済み | なし（Rust 完結） | 変更不要（Rust 共通） |
| 二重列挙廃止 | `scanner.rs` が `ScanResult` を返すよう変更済み | `runPreScan` 削除 / `ScanPhase` 簡略化 | iced 側の事前列挙処理を削除し `ScanResult` のカウントを使う |

Rust クレートの変更は macOS / Windows 共通なので、iced フロントエンドに接続し直すだけで3つとも恩恵を受けられる。
