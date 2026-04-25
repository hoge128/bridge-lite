# TODO-swiftUI.md — Rust core + SwiftUI GUI 移行タスク管理

## 0. 概要 / 移行原則

### ゴール

既存 iced + Rust の全機能を Rust core + SwiftUI に移行する。技術負債ゼロで完了させる。

### 維持する技術資産

- **Adobe XMP Toolkit** (vendor/ 済み、macOS 26 `RawCameraException` パッチ適用済み)
- **shot grouping アルゴリズム** (`pairing.rs`、Phase 1–4 Union-Find + タイムスタンプ分割 + pHash マージ + AEB 分離)
- **SQLite スキーマ** (`images` / `thumbnails` / `phashes` / `meta` テーブル、WAL モード)
- **既存テスト 58 件** (bridge-core 31 / pairing 9 / scanner 6 / xmp 6 / phash 3 / iced-app 3)

### 廃止する技術資産

- `iced 0.14` および `wgpu` テクスチャ管理
- `muda` ベースのメニューバー
- `memory_guard.rs` (iced/wgpu メモリ問題の回避策) → **削除済み**
- `macos/cgimage_shim.cpp` (root level) → **削除済み** (`crates/iced-app/macos/` に移動、Phase G で削除)
- `image` クレート (GUI 経路のみ。bridge-core への依存は完全除去)
- `i18n.rs` (独自国際化実装) → **削除済み**
- `theme.rs` (iced テーマ定義) → **削除済み**
- `dirs-next` (bridge-core から除去。DB パスは引数で受ける)

### 完了の定義

- [x] SwiftUI 版が iced 版の全機能をカバーしている *(Phase F 完了)*
- [x] `cargo test --workspace` が全件パスする *(58 件)*
- [ ] `crates/iced-app` が workspace の `members` から削除されている *(Phase G 残)*

### ブランチ戦略

`feat/swiftui-migration` ブランチで作業。`main` への merge は Phase G 完了後。

---

## Phase A: Workspace 化 ✅ 完了

**目的**: 現在の単一クレート構成をワークスペース構成に移行し、bridge-core / bridge-ffi を追加できる土台を作る。

- [x] **A.1** `Cargo.toml` をワークスペースルート化。`members` に `bridge-core` / `bridge-ffi` / `iced-app` を追加し `resolver = "3"` を指定
- [x] **A.2** 現 `src/` 全体を `crates/iced-app/src/` に移動。パッケージ名は `bridge-lite-iced` に変更
- [x] **A.3** `vendor/xmp_toolkit` の `patch.crates-io` をワークスペース `Cargo.toml` に昇格
- [x] **A.4** `crates/bridge-core/` を Rust lib として作成
- [x] **A.5** `crates/bridge-ffi/` を staticlib として作成
- [x] **A.6** `tools/build-rust-xcframework.sh` を作成

**完了確認**:
- `cargo build --workspace` グリーン
- `cargo test --workspace` で 58 件パス

---

## Phase B: bridge-core への純粋ロジック切り出し ✅ 完了

**目的**: iced に依存しない純粋ロジックを bridge-core へ移植し、GUI から独立してテストできるようにする。

- [x] **B.1** `crates/bridge-core/src/error.rs` 作成 (`CoreError` / `CoreErrorId`)
- [x] **B.2** `scanner.rs` を bridge-core へ移植
- [x] **B.3** `pairing.rs` を bridge-core へ移植 (Union-Find 全 4 Phase 維持)
- [x] **B.4** `metadata.rs` を bridge-core へ移植
- [x] **B.5** `btime.rs` を bridge-core へ移植
- [x] **B.6** `raw_thumb.rs` を bridge-core へ移植 (戻り値 `Vec<u8>`)
- [x] **B.7** `xmp.rs` を bridge-core へ移植 (`DEVELOPED_SOFTWARE_KEYWORDS` を `bridge_core::developed` へ)
- [x] **B.8** `db.rs` を bridge-core へ移植 (`db_path()` 削除、`dirs-next` 除去)
- [x] **B.9** `phash.rs` を bridge-core へ移植 (`compute_phash_from_luma_32x32` 新設)
- [x] **B.10** `is_raw()` を bridge-core に公開
- [x] **B.11** `ImageEntry` の型変更 (`id: u64`, `modified_unix: i64`)
- [x] **B.12** `crates/bridge-core/tests/` に既存テストを統合テストとして移植

**完了確認**:
- `cargo test -p bridge-core` グリーン (31 件)

---

## Phase C: Xcode プロジェクト + bridge-ffi ✅ 完了

**目的**: swift-bridge による FFI 自動生成と Xcode プロジェクトのセットアップ。SwiftUI で最低限のグリッド表示を実現する。

- [x] **C.1** swift-bridge 0.1.59 を bridge-ffi の依存に追加
- [x] **C.2** `bridge-ffi/src/lib.rs` に `#[swift_bridge::bridge]` マクロで API を定義
  - opaque 型: `BridgeDatabase`, `ImageEntryList`, `FfiImageEntry`, `FfiExifResult`, `FfiXmpResult`, `FfiOptionalBytes`, `ShotGroupsMap`, `BridgeFfiError`
  - free 関数: `bridge_open_database`, `bridge_scan_directory`, `bridge_fetch_exif`, `bridge_read_xmp`, `bridge_write_xmp`, `bridge_compute_phash_from_luma`, `bridge_fetch_cached_thumbnail`, `bridge_store_cached_thumbnail`, `bridge_extract_raw_jpeg`, `bridge_reindex_shot_groups`
- [x] **C.3** `bridge-ffi/build.rs` で swift-bridge-build を使ったコード生成を設定
- [x] **C.4** `tools/build-rust-xcframework.sh` の完全実装 (aarch64-apple-darwin ビルド → `Generated/` コピー)
- [x] **C.5** `xcode/BridgeLite/project.yml` を xcodegen 定義で作成、`xcodegen generate` 実行済み
- [x] **C.6** `BridgeCoreDatabase` / `BridgeCoreImageList` ラッパクラス実装
- [x] **C.7** `BridgeCore.swift` 全 FFI 呼び出し実装 (TODO スタブなし)
- [x] **C.8** `CoreError+LocalizedError.swift`: `extension BridgeFfiError: Swift.Error {}` 追加
- [x] **C.9** `ImageEntry+Convert.swift`: `PhotoEntry.init(ffiEntry:)` を実際の FFI accessor で実装
- [x] **C.10** `LibraryStore` / `ScanPipeline` / `ThumbnailPipeline` 最小実装
- [x] **C.11** `LazyVGrid` グリッドビュー実装

**完了確認**:
- `xcodegen generate` でプロジェクト生成済み
- `tools/build-rust-xcframework.sh` でビルドスクリプト完成

---

## Phase D: メタデータ + XMP 編集 ✅ 完了

**目的**: EXIF サイドバー表示と XMP レーティング編集を実装し、Adobe Bridge との相互運用を確認する。

- [x] **D.1** `ExifStore`/`XmpStore` アクターを廃止し、`LibraryStore` の `@Observable` state に統合
  - `exifData: [UInt64: ExifData]`, `xmpData: [UInt64: XmpData]` を `LibraryStore` に直接配置
  - 並行タスクで非同期ロード → `setExif(id:exif:)`, `setXmp(id:xmp:)` でメインアクター更新
- [x] **D.2** `SidebarView` で `store.exifData[id]` を表示 (カメラ名/日時/露出/F値/ISO/焦点距離/解像度)
- [x] **D.3** `XmpSectionView` でレーティング/ラベル/フラグ UI 実装
- [x] **D.4** `ThumbnailGridView` にキーバインド追加 (0-5: レーティング, p/x: pick/reject, 6-9: ラベル)
- [x] **D.5** `applyRating`, `applyLabel`, `togglePick`, `toggleReject` を `LibraryStore` に実装

**完了確認**:
- `store.exifData[id]` がロード完了時に SwiftUI が自動再描画

---

## Phase E: Shot grouping + pHash + Filter ✅ 完了

**目的**: iced 版と同等の shot grouping、pHash 類似判定、フィルタパネルを実装する。

- [x] **E.1** `PairingPipeline` (actor) を実装
  - `noteExifReady(list:db:store:)` で EXIF 完了を通知
  - `maybeReindex` で `BridgeCore.reindexShotGroups` → `store.applyReindexedGroups` を 1 回だけ実行
- [x] **E.2** `computeRepresentatives` を `LibraryStore` に実装 (DEV > JPG > RAW の 3-tier 優先)
  - `exifData[id]?.software` で `DEVELOPED_SOFTWARE_KEYWORDS` を検索
  - `visibleIDs` で live 計算 (exifData ロード完了時に自動反映)
- [x] **E.3** `applyReindexedGroups` で `entry.shotId` も更新してグループキーと一致
- [x] **E.4** `FilterPanelView` 実装 (カメラトグル、評価/ラベル/フラグ選択、ISO 範囲入力、リセット)
- [x] **E.5** `visibleIDs` で `FilterCriteria.matches` を完全適用

**完了確認**:
- フィルタパネルで絞り込み → グリッドがリアルタイム更新

---

## Phase F: ビューア + 設定 + i18n 完成 ✅ 完了

**目的**: フルレズビューア・多言語対応・メニューバーを完成させ、iced 版との機能パリティを達成する。

- [x] **F.1** `ViewerView` 実装
  - RAW: `BridgeCore.extractRawJpeg(quality: .full)` → `CGImage.fromJPEGData`
  - non-RAW: `CGImageSourceCreateImageAtIndex` (Swift 直接)
  - サムネイルを先に表示 → フル解像度ロード完了後に差し替え (`.task(id: store.selectedID)`)
- [x] **F.2** `Localizable.xcstrings` を ja/en 34 キーで完備
- [x] **F.3** `CommandMenu` (File/View/Rate) 完成

**機能パリティチェックリスト**:

| 機能 | 状態 |
|---|---|
| フォルダ開く (Cmd+O) | ✅ |
| サムネイルグリッド表示 | ✅ |
| RAW/JPG ペア (代表表示) | ✅ |
| EXIF サイドバー 7行 | ✅ |
| XMP レーティング (0-5) | ✅ |
| XMP ラベル (5色) | ✅ |
| フラグ (pick/reject) | ✅ |
| キーバインド (0-5, p, x, 6-9) | ✅ |
| フィルタパネル | ✅ |
| フルレズビューア (Space→Close) | ✅ |
| ←/→ ナビゲーション | ✅ |
| ペアバリアント循環 (Tab/Shift+Tab) | ✅ |
| ja/en 多言語対応 | ✅ |

**完了確認**:
- 全機能が LibraryStore @Observable で自動反映

---

## Phase G: iced-app 廃止 + クリーンアップ 🔲 未完了 (ユーザーによる Xcode 動作確認待ち)

**目的**: iced 関連の技術負債をゼロにし、クリーンな Rust core + SwiftUI 構成に仕上げる。

> **重要**: Phase G の削除作業は不可逆。SwiftUI 版を Xcode でビルドして動作を確認してから実施すること。

### ユーザーが先に実施すること

```sh
# 1. Rust ライブラリのビルド
./tools/build-rust-xcframework.sh --release

# 2. Xcode プロジェクトの再生成 (必要な場合)
cd xcode/BridgeLite && xcodegen generate

# 3. Xcode でビルド・実行
open xcode/BridgeLite/BridgeLite.xcodeproj
# → Cmd+B でビルド、Cmd+R で起動、テストフォルダを開いて動作確認
```

### G.1 `crates/iced-app/` 削除

```toml
# Cargo.toml — members から iced-app を除去
[workspace]
members = ["crates/bridge-core", "crates/bridge-ffi"]
resolver = "3"
```

```sh
git rm -r crates/iced-app/
```

- [ ] **G.1a** `Cargo.toml` の `members` から `crates/iced-app` を削除
- [ ] **G.1b** `crates/iced-app/` ディレクトリを `git rm -r` で削除
- [ ] **G.1c** `cargo build --workspace` が通ることを確認

### G.2 残存ファイルのクリーンアップ

- [ ] **G.2a** `assets/` ディレクトリ (iced 向けフォント・SVG アイコン) を削除

  ```sh
  git rm -r assets/
  ```

- [ ] **G.2b** bridge-core の移行期ラッパを削除
  - `phash.rs` の `compute_phash_sync` (deprecated)

### G.3 依存確認

```sh
# iced/muda/image 依存が bridge-core に残っていないこと
cargo tree -p bridge-core | grep -E '(iced|muda|image_hasher|^image )'
# → 出力なし

# C++ ファイルが vendor/target 外に残っていないこと
find . -name '*.cpp' -not -path '*/vendor/*' -not -path '*/target/*'
# → 出力なし
```

- [ ] **G.3a** `cargo tree -p bridge-core` で iced/muda/image が出ないことを確認
- [ ] **G.3b** `find` で vendor/target 外の .cpp がないことを確認

### G.4 ドキュメント更新

- [ ] **G.4a** `README.md` を更新 (ビルド方法、旧 `cargo run` 手順削除)
- [ ] **G.4b** `CORE-GUI.md` を最終更新
- [ ] **G.4c** 本ファイル (`TODO-swiftUI.md`) を最終更新

**Phase G 完了基準**:

```sh
cargo test -p bridge-core      # → ok. 31+ passed
cargo build --workspace         # → Compiling bridge-core, bridge-ffi のみ
find . -name '*.cpp' -not -path '*/vendor/*' -not -path '*/target/*'  # → 出力なし
cargo tree -p bridge-core | grep -E '(iced|muda|image_hasher)'        # → 出力なし
```

---

## 検証チェックリスト (全フェーズ)

| チェック項目 | 対象フェーズ | 状態 |
|---|---|---|
| `cargo build --workspace` | Phase A | ✅ |
| `cargo test --workspace` (58 件) | Phase A | ✅ |
| `cargo test -p bridge-core` (31 件) | Phase B | ✅ |
| swift-bridge FFI バインディング生成 | Phase C | ✅ |
| xcodegen でプロジェクト生成 | Phase C | ✅ |
| Xcode Cmd+B でビルド成功 | Phase C | 🔲 ユーザー確認待ち |
| Xcode Cmd+R で起動・フォルダ開く | Phase C | 🔲 ユーザー確認待ち |
| Adobe Bridge XMP 互換 (`DSE06383.xmp`) | Phase D | 🔲 ユーザー確認待ち |
| Adobe Bridge XMP 互換 (`DSE06419.JPG`) | Phase D | 🔲 ユーザー確認待ち |
| shot grouping 正確性 (件数一致) | Phase E | 🔲 ユーザー確認待ち |
| `crates/iced-app` 削除完了 | Phase G | 🔲 未着手 |
| `cargo tree -p bridge-core` に iced/muda なし | Phase G | 🔲 未着手 |
| C++ ファイルが vendor/target 外にない | Phase G | 🔲 未着手 |
