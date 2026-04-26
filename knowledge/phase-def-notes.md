# Phase D / E / F / G(partial) Work Log

## 実施日: 2026-04-26

## 完了内容

### Phase C 完了 (継続分)
- `BridgeCore.swift`: TODO スタブを実際の FFI 呼び出しに置換
  - `bridge_open_database`, `bridge_scan_directory`, `bridge_fetch_exif`
  - `bridge_read_xmp`, `bridge_write_xmp`, `bridge_compute_phash_from_luma`
  - `bridge_fetch_cached_thumbnail`, `bridge_store_cached_thumbnail`
  - `bridge_extract_raw_jpeg`, `bridge_reindex_shot_groups`
- `BridgeCoreImageList` ラッパクラス追加 (shot grouping 用 opaque handle)
- `CoreError+LocalizedError.swift`: `extension BridgeFfiError: Swift.Error {}` 追加
- `ImageEntry+Convert.swift`: `PhotoEntry.init(ffiEntry:)` を実際の FFI accessor で実装
- `tools/build-rust-xcframework.sh`: 完全実装 (cargo build → Generated/ にコピー)
- xcodegen で BridgeLite.xcodeproj 生成完了

### Phase D 完了
- `LibraryStore`: ExifStore/XmpStore アクターを廃止、`@Observable` state に統合
  - `exifData: [UInt64: ExifData]`, `xmpData: [UInt64: XmpData]` を LibraryStore に移動
  - EXIF/XMP は並行タスクで非同期読み込み → `setExif(id:exif:)`, `setXmp(id:xmp:)` でメインアクター更新
- `SidebarView`: 実際の `store.exifData[id]` を表示。XmpSectionView で rating/label/flag UI
- `ThumbnailGridView`: 0-5 (評価), p/x (pick/reject), 6-9 (ラベル) キーバインド実装
- `ViewerView`: `store.thumbnailImages` から直接読み (非同期不要)

### Phase E 完了
- `computeRepresentatives`: DEV>JPG>RAW の 3 段ティア優先順を実装
  - `exifData[id]?.software` で DEVELOPED_SOFTWARE_KEYWORDS 検索
  - `visibleIDs` で live 計算 (exifData ロード完了時に自動反映)
- `applyReindexedGroups`: entry.shotId も更新してグループキーと一致させる
- `FilterPanelView`: カメラトグル、評価/ラベル/フラグ選択、ISO 範囲入力、リセット
- `visibleIDs`: `FilterCriteria.matches` を完全適用

### Phase F 完了
- `ViewerView`: フル解像度ロード実装
  - RAW: `BridgeCore.extractRawJpeg(quality: .full)` 
  - non-RAW: `CGImageSourceCreateImageAtIndex` (Swift 直接)
  - サムネイルを先に表示 → フル解像度ロード完了後に差し替え
- `Localizable.xcstrings`: 34 キーで ja/en 完備
- CommandMenu (Phase C から継続): File/View/Rate コマンド完成

### Phase G (部分) 完了
- root `src/*.rs` (21ファイル) を git rm で削除
- root `build.rs`, `macos/cgimage_shim.cpp`, `macos/Info.plist.extra` 削除
- `cargo tree -p bridge-core` に iced/muda なし確認

## アーキテクチャ変更サマリ

### LibraryStore の設計変更
最初の設計: ExifStore/XmpStore/ThumbnailStore アクター + LibraryStore
実際の実装: すべて LibraryStore に統合 (@Observable state)

**理由**: SwiftUI の `@Observable` は state が変わると自動的に View を更新するが、
アクターはそれができない。サムネイル/EXIF/XMP は LibraryStore の `@Observable` 
プロパティにすることで、各データが到着するたびに UI が即時更新される。

```swift
@Observable @MainActor final class LibraryStore {
    private(set) var thumbnailImages: [UInt64: CGImage] = [:]  // 各サムネイル完了で更新
    private(set) var exifData: [UInt64: ExifData] = [:]         // EXIF ロード完了で更新
    private(set) var xmpData: [UInt64: XmpData] = [:]           // XMP ロード完了で更新
}
```

### ThumbnailPipeline の変更
最初: actor ThumbnailPipeline, ThumbnailStore アクター経由
実際: enum ThumbnailPipeline (static メソッド), LibraryStore.setThumbnail に直接書き込み

## 残タスク

### Phase G 残
- `crates/iced-app/` 削除 (SwiftUI 版の動作確認後)
  - 削除基準: ユーザーが実際に SwiftUI 版を Xcode でビルドして動作確認
  - bridge-core の移行期ラッパ削除
  - image_hasher/iced/muda が cargo tree に残らないことを確認

### ユーザーが Xcode でやること
1. `./tools/build-rust-xcframework.sh --release` を実行
2. `cd xcode/BridgeLite && xcodegen generate` (既に実行済み)
3. `open BridgeLite.xcodeproj` で Xcode で開く
4. Build (Cmd+B) してコンパイルエラーを確認
5. Run (Cmd+R) して実際のフォルダを開いてみる

## テスト確認
- `cargo test --workspace`: 58 tests pass (31 bridge-core, 9 pairing, 6 scanner, 6 xmp, 6 phash, 3 iced-app)
- SourceKit diagnostics: すべて false positive (ファイル単体解析の制限)
