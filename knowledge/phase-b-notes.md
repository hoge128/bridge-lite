# Phase B: bridge-core 移植作業メモ

実施日: 2026-04-25

## 概要

`crates/iced-app/src/` の純粋ロジックを `crates/bridge-core/src/` に移植し、
iced-app は bridge-core への re-export wrapper に変換した。

## 実施タスク

### B.1: developed.rs
- `crates/bridge-core/src/developed.rs` を新規作成
- `DEVELOPED_SOFTWARE_KEYWORDS` 定数を app.rs から移植

### B.2: scanner.rs
- `crates/bridge-core/src/scanner.rs` を作成 (iced-app/scanner.rs ほぼそのまま)
- `pub fn is_raw(path: &Path) -> bool` を追加 (thumbnail.rs から移植)

### B.3: metadata.rs
- `crates/bridge-core/src/metadata.rs` を作成 (そのまま移植)

### B.4: btime.rs
- `crates/bridge-core/src/btime.rs` を作成 (そのまま移植)

### B.5: raw_thumb.rs
- `crates/bridge-core/src/raw_thumb.rs` を作成 (そのまま移植)

### B.6: db.rs
- `crates/bridge-core/src/db.rs` を作成
- `db_path()` 関数を削除 (dirs-next 依存を除去)
- iced-app の db.rs は `db_path()` のみ残し、残りを bridge-core から re-export

### B.7: xmp.rs
- `crates/bridge-core/src/xmp.rs` を作成
- `use crate::thumbnail::is_raw` → `use crate::scanner::is_raw` に変更
- `crate::app::DEVELOPED_SOFTWARE_KEYWORDS` → `crate::developed::DEVELOPED_SOFTWARE_KEYWORDS` に変更

### B.8: phash.rs
- `crates/bridge-core/src/phash.rs` を作成
- `compute_phash_from_luma_32x32(pixels: &[u8; 1024]) -> u64` 新規 API 追加
- `hamming`, `fetch_phash_batch`, `store_phash` を含む
- `compute_phash_sync` は iced-app 側に残す (macos_thumb 依存のため)

### B.9: pairing.rs
- `crates/bridge-core/src/pairing.rs` を作成 (crate:: 参照はすべて同クレート内で OK)

### B.10: bridge-core/Cargo.toml 更新
- chrono, image, image_hasher, kamadak-exif, libc, rayon, rusqlite, serde, serde_json, tokio, walkdir, xmp_toolkit を追加

### B.11: bridge-core/src/lib.rs 更新
- 全モジュールを公開、主要型を re-export

### B.12: iced-app/Cargo.toml 確認
- bridge-core = { path = "../bridge-core" } は既に追加済みだった

### B.13: iced-app 各ソース更新
- scanner/metadata/btime/raw_thumb/xmp/pairing.rs → bridge-core からの re-export wrapper に変換
- db.rs → db_path() のみ残し、残りは bridge-core re-export
- phash.rs → compute_phash_sync を残し、hamming/compute_phash_from_luma_32x32 は bridge-core re-export
- thumbnail.rs → is_raw を bridge_core::scanner::is_raw に変更、raw_thumb/db も bridge-core 経由
- app.rs → DEVELOPED_SOFTWARE_KEYWORDS を bridge_core::developed から import

### B.14: 統合テスト作成
- `crates/bridge-core/tests/integration_pairing.rs` (9 tests)
- `crates/bridge-core/tests/integration_xmp.rs` (3 tests)
- `crates/bridge-core/tests/integration_scanner.rs` (6 tests)
- `crates/bridge-core/tests/integration_phash.rs` (6 tests)

### B.15: ビルド・テスト結果
- `cargo build --workspace` → 警告なし、エラーなし
- `cargo test --workspace` → 58 tests (bridge-core: 55, iced-app: 3) 全通過

## 注意事項

- iced-app の各 re-export ファイル (scanner/metadata/btime/raw_thumb/xmp/pairing.rs) は
  削除せずに re-export wrapper として残している。これにより `crate::scanner::...` 形式の
  参照が app.rs/thumbnail.rs/phash.rs などから引き続き動作する。
- `#[allow(unused_imports)]` を各 re-export ファイルに付与して警告を抑制。
- image crate は bridge-core/Cargo.toml に `default-features = false` で追加。
  image_hasher の内部依存として使用するため、実際には image_hasher がデコード機能を提供する。
