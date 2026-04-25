# Phase C: bridge-ffi (swift-bridge FFI layer) 実装メモ

実施日: 2026-04-26

## 概要

`crates/bridge-ffi/` に swift-bridge 0.1.59 を使った FFI レイヤーを実装した。
bridge-core の全 API を Swift から呼び出せるよう opaque type + アクセサパターンで公開している。

## 実施タスク

### C.1: Cargo.toml 更新
- `crate-type = ["staticlib", "cdylib"]`
- dependencies: `swift-bridge = "0.1"`, `tokio = { version = "1.50.0", features = ["full"] }`
- build-dependencies: `swift-bridge-build = "0.1"`

### C.2: build.rs 作成
- `swift_bridge_build::parse_bridges(["src/lib.rs"]).write_all_concatenated("generated", "bridge-ffi")`
- 生成先: `crates/bridge-ffi/generated/bridge-ffi/bridge-ffi.{swift,h}`
- `SwiftBridgeCore.{swift,h}` も `generated/` 直下に生成される

### C.3: src/lib.rs 実装

#### 公開 API (extern "Rust" ブロック)
- **Database API**: `bridge_open_database` → `Result<BridgeDatabase, BridgeFfiError>`
- **Scan API**: `bridge_scan_directory` → `ImageEntryList` + count/get アクセサ
- **ImageEntry アクセサ**: id/path/filename/is_raw/file_size/modified_unix/created_unix/has_jpg_partner/shot_id
- **EXIF API**: `bridge_fetch_exif` (DB キャッシュ + ファイルフォールバック) + 各フィールドアクセサ
- **XMP API**: `bridge_read_xmp` / `bridge_write_xmp`
- **pHash API**: `bridge_compute_phash_from_luma` / `bridge_fetch_phash` / `bridge_store_phash`
- **Thumbnail cache API**: `bridge_fetch_cached_thumbnail` / `bridge_store_cached_thumbnail`
- **RAW embedded JPEG API**: `bridge_extract_raw_jpeg` (quality: 0=Thumb/1=Preview/2=Full)
- **Shot grouping API**: `bridge_reindex_shot_groups` → `ShotGroupsMap` + count/shot_id_at/members_for
- **Utilities**: `bridge_is_raw` / `bridge_developed_keywords`

#### 生成された Swift bindings の概要
- 768行の Swift ファイル + 149行の C ヘッダーが自動生成される
- `bridge_open_database` → `throws -> BridgeDatabase` として Swift 側に露出
- 各 opaque type は `Foo` / `FooRef` / `FooRefMut` の3クラスが Swift 側に生成される

## swift-bridge 0.1.59 の制約と対処

### 制約1: `Box<T>` は戻り値型として使えない
- **NG**: `fn make_foo() -> Box<Foo>;`
- **OK**: `fn make_foo() -> Foo;`
- swift-bridge のパーサーが `Box < Foo >` の `>` を型名として誤認識する

### 制約2: `Result<Box<T>, E>` は使えない
- **NG**: `fn open(...) -> Result<Box<Foo>, String>;`
- **OK**: `fn open(...) -> Result<Foo, FooError>;` (opaque types)
- `BuiltInResult::from_str_tokens` が `rsplit_once(",")` で分割するため
  `Box<T>` の `>` が `Result` の外側の `>` と混同される

### 制約3: `#[doc(...)]` / `///` コメントは extern "Rust" ブロック内で使えない
- build.rs の `parse_bridges` がファイル全体を `syn` でパースし、
  `#[swift_bridge::bridge]` モジュールを `syn::parse2` で再パースする際に
  `#[doc(...)]` 属性が `ParseError` になる
- **対処**: `//` コメントのみ使用

### 制約4: `associated_to = T` コンストラクタの Rust 実装
- `associated_to = T` を付けた関数は Swift 側で `T.funcName()` の static メソッドになる
- Rust 実装は `impl T { fn func_name() }` のメソッドか、
  シグネチャが一致するグローバル関数として定義する必要がある
- **対処**: 今回はすべてトップレベル関数として定義し、`associated_to` は使用しない

## BridgeDatabase の設計変更

要件仕様では `Arc<Mutex<rusqlite::Connection>>` を保持するとしていたが、
bridge-core の各関数が内部で接続を開閉する設計 (WAL モード) になっているため、
`BridgeDatabase` は `db_path: PathBuf` のみを保持するシンプルな構造に変更した。

- `rusqlite` を bridge-ffi の直接依存として追加しなくてよい
- bridge-core の既存 API (fetch_or_index, store_thumb 等) をそのまま使える
- マルチスレッド安全性は rusqlite の WAL モードに委ねる

## 生成ファイルのパス

```
crates/bridge-ffi/generated/
├── SwiftBridgeCore.h       (swift-bridge ランタイムの C ヘッダー)
├── SwiftBridgeCore.swift   (swift-bridge ランタイムの Swift ラッパー)
└── bridge-ffi/
    ├── bridge-ffi.h        (API の C ヘッダー)
    └── bridge-ffi.swift    (API の Swift ラッパー)
```

## Swift 側で対応が必要なこと

### 1. Xcode プロジェクトへの組み込み
- `cargo build --release -p bridge-ffi` でビルドした `libbridge_ffi.a` を Xcode に追加
- `generated/` 以下の 4 ファイルをすべて Xcode プロジェクトに追加
- `SwiftBridgeCore.swift` と `bridge-ffi.swift` は Swift ターゲットに追加
- `SwiftBridgeCore.h` と `bridge-ffi.h` は bridging header に include

### 2. Bridging Header の設定
```c
#include "SwiftBridgeCore.h"
#include "bridge-ffi.h"
```

### 3. Swift 側での使い方 (例)
```swift
import Foundation

// DB を開く
let db = try bridge_open_database("/path/to/cache.db")

// ディレクトリスキャン
let list = bridge_scan_directory(db, "/path/to/photos")
let count = image_entry_list_count(list)

for i in 0..<count {
    let entry = image_entry_list_get(list, i)
    let path = ffi_image_entry_path(entry).toString()
    let isRaw = ffi_image_entry_is_raw(entry)
    // ...
}

// EXIF 取得
let exif = bridge_fetch_exif(db, "/path/to/photo.jpg")
if ffi_exif_found(exif) {
    let model = ffi_exif_model(exif).toString()
}

// XMP 書き込み (rating=4, label=Red, flag=None)
let ok = bridge_write_xmp("/path/to/photo.arw", 4, 1, 0)

// pHash 計算 (Swift 側で 32x32 grayscale を生成後)
// let pixels: [UInt8] = ... (1024 bytes)
// let hash = bridge_compute_phash_from_luma(pixels)
```

### 4. RustString → Swift String 変換
swift-bridge の `RustString` は直接 Swift の `String` ではないため、
`.toString()` メソッドで変換が必要:
```swift
let s: String = ffi_exif_make(exif).toString()
```

### 5. XCFramework としての配布 (将来)
- `swift_bridge_build::create_package` を使って XCFramework + Swift Package を生成できる
- 現状は Xcode プロジェクトに直接リンクする方法を推奨

## 残課題

1. **Xcode プロジェクト作成**: `xcode/` ディレクトリに SwiftUI プロジェクトを作成し、
   bridge-ffi を組み込む (Phase D の作業)

2. **macOS 向けサムネイル生成 (Swift 側)**: bridge-lite のサムネイル生成は
   macOS の `CGImageSource` / `CGImage` を使うため、Swift 側で実装し
   `bridge_store_cached_thumbnail` でキャッシュに保存するフローが必要

3. **非同期化**: `bridge_scan_directory` は現在同期 (blocking) で動作する。
   Swift 側で `Task { }` や `DispatchQueue` で別スレッドに逃がすことを推奨

4. **エラー型の拡充**: `BridgeFfiError.code` は `CoreErrorId as u32` だが、
   Swift 側で `enum BridgeLiteError` として wrap することを推奨

5. **Vec<u64> の Swift 側アクセス**: `shot_groups_map_members_for` は `Vec<u64>` を返すが、
   swift-bridge では `RustVec<UInt64>` になる。Swift 側で `Array` に変換する際は
   `RustVec` の `toArray()` または イテレーションを使う

6. **ビルドスクリプト**: Release ビルド用の Makefile または sh スクリプトを作成する
   ```sh
   cargo build --release -p bridge-ffi --target aarch64-apple-darwin
   cargo build --release -p bridge-ffi --target x86_64-apple-darwin
   lipo ... # universal binary 作成 (必要な場合)
   ```
