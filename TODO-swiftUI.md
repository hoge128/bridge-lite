# TODO-swiftUI.md — Rust core + SwiftUI GUI 移行タスク管理

## 0. 概要 / 移行原則

### ゴール

既存 iced + Rust の全機能を Rust core + SwiftUI に移行する。技術負債ゼロで完了させる。

### 維持する技術資産

- **Adobe XMP Toolkit** (vendor/ 済み、macOS 26 `RawCameraException` パッチ適用済み)
- **shot grouping アルゴリズム** (`pairing.rs`、Phase 1–4 Union-Find + タイムスタンプ分割 + pHash マージ + AEB 分離)
- **SQLite スキーマ** (`images` / `thumbnails` / `phashes` / `meta` テーブル、WAL モード)
- **既存テスト 25 件** (pairing 9件 / xmp 8件 / scanner 5件 / phash 3件)

### 廃止する技術資産

- `iced 0.14` および `wgpu` テクスチャ管理
- `muda` ベースのメニューバー
- `memory_guard.rs` (iced/wgpu メモリ問題の回避策)
- `macos/cgimage_shim.cpp` (C++ ブリッジ)
- `image` クレート (GUI 経路のみ。bridge-core への依存は完全除去)
- `i18n.rs` (独自国際化実装)
- `theme.rs` (iced テーマ定義)
- `dirs-next` (bridge-core から除去。DB パスは引数で受ける)

### 完了の定義

- [ ] SwiftUI 版が iced 版の全機能をカバーしている
- [ ] `cargo test -p bridge-core` が全件パスする
- [ ] `crates/iced-app` が workspace の `members` から削除されている

### ブランチ戦略

`feat/swiftui-migration` ブランチで作業。`main` への merge は Phase F 完了後。

---

## Phase A: Workspace 化

**目的**: 現在の単一クレート構成をワークスペース構成に移行し、bridge-core / bridge-ffi を追加できる土台を作る。

- [ ] **A.1** `Cargo.toml` をワークスペースルート化。`members` に `bridge-core` / `bridge-ffi` / `iced-app` を追加し `resolver = "2"` を指定する

  ```toml
  [workspace]
  members = ["crates/bridge-core", "crates/bridge-ffi", "crates/iced-app"]
  resolver = "2"

  [patch.crates-io]
  xmp_toolkit = { path = "vendor/xmp_toolkit" }
  ```

- [ ] **A.2** 現 `src/` 全体を `crates/iced-app/src/` に移動。現 `Cargo.toml` (パッケージセクション) を `crates/iced-app/Cargo.toml` に移動。パッケージ名は `bridge-lite-iced` に変更

- [ ] **A.3** `vendor/xmp_toolkit` の `patch.crates-io` をワークスペース `Cargo.toml` に昇格 (各クレートの `Cargo.toml` から削除)

- [ ] **A.4** `crates/bridge-core/` を空の Rust lib として作成

  ```
  crates/bridge-core/
  ├── Cargo.toml   # [lib], edition = "2024"
  └── src/lib.rs   # pub mod stub のみ
  ```

- [ ] **A.5** `crates/bridge-ffi/` を空の staticlib として作成 (後フェーズで実装)

  ```toml
  # crates/bridge-ffi/Cargo.toml
  [lib]
  crate-type = ["staticlib", "cdylib"]
  ```

- [ ] **A.6** `tools/build-rust-xcframework.sh` を空のシェルスクリプトとして作成 (後フェーズで実装)

**完了基準**:
- `cargo build --workspace` がグリーン
- `cargo test --workspace` で既存 25 件がパス

---

## Phase B: bridge-core への純粋ロジック切り出し

**目的**: iced に依存しない純粋ロジックを bridge-core へ移植し、GUI から独立してテストできるようにする。

- [ ] **B.1** `crates/bridge-core/src/error.rs` を新規作成

  ```rust
  use thiserror::Error;

  #[derive(Debug, Error)]
  pub enum CoreError {
      #[error("I/O: {0}")]
      Io(#[from] std::io::Error),
      #[error("unsupported format: {path}")]
      UnsupportedFormat { path: String },
      #[error("XMP parse: {0}")]
      XmpParse(String),
      #[error("XMP write: {0}")]
      XmpWrite(String),
      #[error("database: {0}")]
      Db(#[from] rusqlite::Error),
      #[error("thumbnail decode: {path}")]
      ThumbnailDecode { path: String },
      #[error("not found: {path}")]
      NotFound { path: String },
      #[error("cancelled")]
      Cancelled,
  }

  #[repr(u32)]
  pub enum CoreErrorId {
      Io = 1, UnsupportedFormat = 2, XmpParse = 3, XmpWrite = 4,
      Db = 5, ThumbnailDecode = 6, NotFound = 7, Cancelled = 8,
  }
  ```

- [ ] **B.2** `scanner.rs` を bridge-core へ移植
  - `use crate::app::` の参照を削除
  - `RAW_EXTENSIONS` を `pub const` として公開
  - `iced` / `image` クレートへの参照をすべて除去

- [ ] **B.3** `pairing.rs` を bridge-core へ移植
  - `app::` モジュール参照を削除
  - `ExifData` / `ImageEntry` は `bridge_core::` から取得するよう修正
  - Union-Find ロジック (Phase 1–4) はそのまま維持

- [ ] **B.4** `metadata.rs` を bridge-core へ移植
  - `kamadak-exif` 依存はそのまま維持
  - `iced` 型への参照を除去

- [ ] **B.5** `btime.rs` を bridge-core へ移植
  - `libc::setattrlist` 依存はそのまま維持
  - `CoreError::Io` でエラーを wrap

- [ ] **B.6** `raw_thumb.rs` を bridge-core へ移植
  - 戻り値を `Result<Vec<u8>, CoreError>` に統一 (JPEG バイト列のみ返す)
  - `image` クレートへの依存を除去 (デコードは Swift 側の CGImageSource が担当)

- [ ] **B.7** `xmp.rs` を bridge-core へ移植
  - `crate::app::DEVELOPED_SOFTWARE_KEYWORDS` を `bridge_core::developed` モジュールに分離
  - Adobe XMP Toolkit への依存はそのまま維持

- [ ] **B.8** `db.rs` を bridge-core へ移植
  - `db_path()` 関数を削除 (ディレクトリ解決は Swift 側の責務)
  - シグネチャ変更: `open_database(db_path: &Path) -> Result<Database, CoreError>`
  - `dirs-next` 依存を bridge-core から完全除去

- [ ] **B.9** `phash.rs` を bridge-core へ移植
  - **新設**: `pub fn compute_phash_from_luma_32x32(luma: &[u8; 1024]) -> u64`
    - 引数: Swift 側が CGBitmapContext で生成した 32×32 luma バイト列
    - 処理: DCT 平均ビット方式の pHash 計算
  - 移行期ラッパとして既存 `compute_phash_sync` は残す (Phase G で削除)

- [ ] **B.10** `thumbnail.rs` の `is_raw()` のみ bridge-core に出す
  - `ThumbResult` と生成ロジック (CGImage 系) は iced-app 側に残す
  - `is_raw(path: &Path) -> bool` は scanner.rs と共有できるよう `RAW_EXTENSIONS` を参照

- [ ] **B.11** `ImageEntry` の型変更
  - `id: usize` → `id: u64` (SQLite rowid との整合)
  - `mtime: SystemTime` → `mtime: i64` (Unix seconds, FFI 友好)

- [ ] **B.12** `crates/bridge-core/tests/` に既存ユニットテストを統合テストとして移植

  ```
  crates/bridge-core/tests/
  ├── pairing_test.rs    # 9件
  ├── xmp_test.rs        # 8件
  ├── scanner_test.rs    # 5件
  └── phash_test.rs      # 3件
  ```

- [ ] **B.13** `crates/iced-app/Cargo.toml` に bridge-core への path 依存を追加

  ```toml
  [dependencies]
  bridge-core = { path = "../bridge-core" }
  ```

**完了基準**:
- `cargo test -p bridge-core` が全件パス
- `cargo run -p bridge-lite-iced` で従来と同じ動作 (リグレッションなし)

---

## Phase C: Xcode プロジェクト + bridge-ffi

**目的**: swift-bridge による FFI 自動生成と Xcode プロジェクトのセットアップ。SwiftUI で最低限のグリッド表示を実現する。

- [ ] **C.1** swift-bridge を bridge-ffi の依存に追加

  ```toml
  # crates/bridge-ffi/Cargo.toml
  [dependencies]
  bridge-core = { path = "../bridge-core" }
  swift-bridge = "0.1"

  [build-dependencies]
  swift-bridge-build = "0.1"
  ```

- [ ] **C.2** `bridge-ffi/src/lib.rs` に `#[swift_bridge::bridge]` マクロで API を定義

  ```rust
  #[swift_bridge::bridge]
  mod ffi {
      extern "Rust" {
          // スキャン
          async fn scan_directory(path: String) -> Result<Vec<FfiImageEntry>, CoreError>;

          // DB
          type Database;
          fn open_database(path: String) -> Result<Database, CoreError>;

          // EXIF
          async fn fetch_exif_batch(db: &Database, ids: Vec<u64>) -> Vec<FfiExifData>;
          async fn index_exif(db: &Database, path: String) -> Result<FfiExifData, CoreError>;

          // XMP
          fn read_xmp(path: String) -> Result<FfiXmpData, CoreError>;
          async fn write_xmp(path: String, data: FfiXmpData) -> Result<(), CoreError>;

          // pHash
          fn compute_phash_from_luma_32x32(luma: Vec<u8>) -> u64;
          async fn fetch_phash_batch(db: &Database, ids: Vec<u64>) -> Vec<FfiPhashEntry>;
          fn store_phash(db: &Database, id: u64, mtime: i64, hash: u64) -> Result<(), CoreError>;

          // サムネイルキャッシュ
          fn fetch_cached_thumbnail(db: &Database, id: u64, mtime: i64) -> Option<Vec<u8>>;
          fn store_cached_thumbnail(db: &Database, id: u64, mtime: i64, jpeg: Vec<u8>) -> Result<(), CoreError>;

          // RAW 埋め込み JPEG
          fn extract_raw_embedded_jpeg(path: String) -> Result<Vec<u8>, CoreError>;

          // Shot grouping
          fn reindex_shot_groups(entries: Vec<FfiImageEntry>) -> Vec<FfiShotGroup>;
      }
  }
  ```

- [ ] **C.3** `bridge-ffi/build.rs` で swift-bridge-build を使ったコード生成を設定

  ```rust
  // bridge-ffi/build.rs
  fn main() {
      let bridges = vec!["src/lib.rs"];
      swift_bridge_build::parse_bridges(bridges)
          .write_all_concatenated(swift_bridge_build::swiftPackageDir(), "BridgeCoreFFI");
  }
  ```

- [ ] **C.4** `tools/build-rust-xcframework.sh` の実装

  ```sh
  #!/bin/sh
  set -e
  cargo build -p bridge-ffi --release --target aarch64-apple-darwin
  cargo build -p bridge-ffi --release --target x86_64-apple-darwin
  lipo -create \
      target/aarch64-apple-darwin/release/libbridge_ffi.a \
      target/x86_64-apple-darwin/release/libbridge_ffi.a \
      -output target/libbridge_ffi_universal.a
  xcodebuild -create-xcframework \
      -library target/libbridge_ffi_universal.a \
      -headers generated/BridgeCoreFFI/ \
      -output xcode/BridgeLite/Frameworks/BridgeCoreFFI.xcframework
  ```

- [ ] **C.5** `xcode/BridgeLite/BridgeLite.xcodeproj` を新規作成 (xcodegen または Xcode で手動作成)

  ```yaml
  # project.yml (xcodegen)
  name: BridgeLite
  targets:
    BridgeLite:
      type: application
      platform: macOS
      deploymentTarget: "14.0"
      sources: [BridgeLite]
      dependencies:
        - framework: Frameworks/BridgeCoreFFI.xcframework
  ```

- [ ] **C.6** Xcode に XCFramework をリンク、swift-bridge 生成の Bridging Header または Swift Package を取り込む

- [ ] **C.7** `xcode/BridgeLite/BridgeLite/Bridging/BridgeCore.swift` を実装

  ```swift
  // FfiImageEntry → PhotoEntry への 1 回マッピング
  extension PhotoEntry {
      init(_ ffi: FfiImageEntry) {
          self.id       = ffi.id
          self.path     = URL(filePath: String(ffi.path))
          self.shotId   = ffi.shot_id
          self.isRaw    = ffi.is_raw
          self.fileSize = ffi.file_size
          self.mtime    = ffi.mtime
      }
  }
  ```

- [ ] **C.8** `Models/` を実装

  ```swift
  // PhotoEntry.swift — Sendable な値型
  struct PhotoEntry: Identifiable, Hashable, Sendable {
      let id: UInt64
      let path: URL
      let shotId: UInt64
      let isRaw: Bool
      let fileSize: Int64
      let mtime: Int64
  }

  // ExifData.swift
  struct ExifData: Sendable {
      var camera: String?
      var datetime: String?
      var exposureTime: String?
      var fNumber: Double?
      var iso: Int?
      var focalLength: Double?
      var width: Int?
      var height: Int?
  }

  // XmpData.swift
  struct XmpData: Sendable {
      var rating: Int          // 0–5
      var label: XmpLabel      // .none / .red / .yellow / .green / .blue / .purple
      var flag: XmpFlag        // .none / .pick / .reject
  }

  // ShotGroup.swift
  struct ShotGroup: Identifiable, Sendable {
      let id: UInt64
      var memberIds: [UInt64]
      var representativeId: UInt64
  }

  // FilterCriteria.swift
  struct FilterCriteria: Sendable {
      var cameras: Set<String> = []
      var isoRange: ClosedRange<Int>? = nil
      var focalRange: ClosedRange<Double>? = nil
      var dateRange: ClosedRange<Date>? = nil
      var ratings: Set<Int> = []
      var labels: Set<XmpLabel> = []
      var flags: Set<XmpFlag> = []

      func matches(_ entry: PhotoEntry, exif: ExifData?, xmp: XmpData?) -> Bool { /* ... */ }
  }
  ```

- [ ] **C.9** `LibraryStore` / `ScanPipeline` / `ThumbnailPipeline` (最小実装) を実装

  ```swift
  @MainActor @Observable final class LibraryStore {
      var entries: [PhotoEntry] = []
      var shotGroups: [ShotGroup] = []
      var selectedId: UInt64? = nil
      var filterCriteria = FilterCriteria()
      private var db: DatabaseHandle?
  }

  actor ScanPipeline {
      func scan(url: URL) async throws -> [PhotoEntry] { /* Rust scan_directory */ }
  }

  actor ThumbnailPipeline {
      private let limiter = ConcurrencyLimiter(max: 6)
      func thumbnail(for entry: PhotoEntry, size: CGSize) async throws -> CGImage { /* ... */ }
  }
  ```

- [ ] **C.10** 最低限の `LazyVGrid` グリッドビューを実装

  ```swift
  // ThumbnailGridView.swift
  struct ThumbnailGridView: View {
      let columns = [GridItem(.adaptive(minimum: 120))]
      var body: some View {
          ScrollView {
              LazyVGrid(columns: columns) {
                  ForEach(store.visibleEntries) { entry in
                      ThumbnailCell(entry: entry)
                          .glassEffect()  // Liquid Glass
                  }
              }
          }
      }
  }
  ```

**完了基準**:
- SwiftUI 版で `~/work/bridge-lite/test/20260221` を開いて RAW+JPG ペアがグリッド表示される

---

## Phase D: メタデータ + XMP 編集

**目的**: EXIF サイドバー表示と XMP レーティング編集を実装し、Adobe Bridge との相互運用を確認する。

- [ ] **D.1** `ExifPipeline` を実装 (バッチ取得 + キャッシュミス個別読み)

  ```swift
  actor ExifPipeline {
      func fetchBatch(ids: [UInt64]) async -> [UInt64: ExifData] {
          // 1. fetch_exif_batch (DB バッチ)
          // 2. キャッシュミス分を index_exif で個別取得
          // 3. ExifStore (actor) に保存して通知
      }
  }
  ```

- [ ] **D.2** `SidebarView` に EXIF 7行表示を実装

  ```swift
  struct SidebarView: View {
      var body: some View {
          VStack(alignment: .leading, spacing: 8) {
              ExifRow(label: "Camera",    value: exif?.camera)
              ExifRow(label: "Date",      value: exif?.datetime)
              ExifRow(label: "Exposure",  value: exif?.exposureTime)
              ExifRow(label: "F-number",  value: exif?.fNumber.map { "f/\($0)" })
              ExifRow(label: "ISO",       value: exif?.iso.map { "\($0)" })
              ExifRow(label: "Focal",     value: exif?.focalLength.map { "\($0)mm" })
              ExifRow(label: "Resolution",value: resolutionText)
          }
      }
  }
  ```

- [ ] **D.3** `XmpStore` (楽観更新 + Rust 書き戻し + 失敗時 revert) を実装

  ```swift
  actor XmpStore {
      private var cache: [UInt64: XmpData] = [:]

      func setRating(_ rating: Int, for entry: PhotoEntry) async throws {
          let old = cache[entry.id]
          cache[entry.id]?.rating = rating           // 楽観更新
          do {
              try await BridgeCore.writeXmp(path: entry.path, rating: rating)
          } catch {
              cache[entry.id] = old                  // revert
              throw error
          }
      }
  }
  ```

- [ ] **D.4** `SidebarView` に XMP 編集 UI を実装
  - Rating: ★ ★ ★ ★ ★ (タップで 0–5 設定)
  - Label: 色付きドット 6種 (none/red/yellow/green/blue/purple)
  - Flag: ピック旗 (P) / リジェクト (X) / クリア (U) ボタン

- [ ] **D.5** キーバインドを `ThumbnailGridView` に追加

  ```swift
  .onKeyPress(.init("0")) { store.setRating(0); return .handled }
  .onKeyPress(.init("1")) { store.setRating(1); return .handled }
  // ... 2–5
  .onKeyPress(.init("p")) { store.setFlag(.pick);   return .handled }
  .onKeyPress(.init("x")) { store.setFlag(.reject);  return .handled }
  .onKeyPress(.init("u")) { store.setFlag(.none);    return .handled }
  .onKeyPress(.init("6")) { store.setLabel(.red);    return .handled }
  // ... 7=yellow, 8=green, 9=blue
  ```

- [ ] **D.6** Adobe Bridge 相互運用検証

  ```sh
  # DSE06383.xmp に photoshop:LabelColor="red" が含まれること
  grep 'LabelColor' test/20260221/DSE06383.xmp

  # DSE06419.JPG の埋め込み XMP で xmp:Rating="3" が読めること
  # → XmpStore.cache[DSE06419.id].rating == 3 を XCTest で確認
  ```

**完了基準**:
- Adobe Bridge でレーティングを設定したファイルを bridge-lite SwiftUI 版で開くと同じ値が表示される

---

## Phase E: Shot grouping + pHash + Filter

**目的**: iced 版と同等の shot grouping、pHash 類似判定、フィルタパネルを実装する。

- [ ] **E.1** `PairingPipeline` を実装 (watermark カウンタ方式)

  ```swift
  actor PairingPipeline {
      private var exifDoneCount = 0
      private var phashDoneCount = 0

      func notifyExifDone(count: Int) async {
          exifDoneCount = count
          await checkWatermark()
      }

      func notifyPhashDone(count: Int) async {
          phashDoneCount = count
          await checkWatermark()
      }

      private func checkWatermark() async {
          guard exifDoneCount == totalCount && phashDoneCount == totalCount else { return }
          let groups = BridgeCore.reindexShotGroups(entries: allEntries)
          await MainActor.run { store.shotGroups = groups }
      }
  }
  ```

- [ ] **E.2** `representative_id_of` の Swift 版を実装 (DEV > JPG > RAW の 3-tier 優先)

  ```swift
  // ShotGroup.swift
  func representativeId(entries: [PhotoEntry], xmpStore: XmpStore) -> UInt64 {
      // 1. 現像バリアント (DEVELOPED_SOFTWARE_KEYWORDS で判定) があればそちら
      // 2. なければ JPG
      // 3. なければ RAW
      // 4. 全員 RAW なら id が最小のもの
  }
  ```

- [ ] **E.3** グリッドで代表のみ表示する `is_representative` ロジックを実装

  ```swift
  // LibraryStore.swift
  var visibleEntries: [PhotoEntry] {
      entries.filter { entry in
          guard let group = shotGroup(for: entry) else { return true }
          return group.representativeId == entry.id
      }
  }
  ```

- [ ] **E.4** `SidebarView` にバリアントストリップを実装

  ```swift
  // VariantStripView.swift — 50×40 サムネ + R/D/J バッジ
  struct VariantStripView: View {
      let group: ShotGroup
      var body: some View {
          HStack(spacing: 4) {
              ForEach(group.memberIds, id: \.self) { id in
                  ZStack(alignment: .bottomTrailing) {
                      ThumbnailImage(id: id, size: CGSize(width: 50, height: 40))
                      VariantBadge(id: id)  // "R" / "D" / "J"
                  }
                  .onTapGesture { store.selectedId = id }
              }
          }
      }
  }
  ```

- [ ] **E.5** Tab / Shift+Tab でバリアント循環を実装

  ```swift
  .onKeyPress(.tab) {
      store.cycleVariant(forward: true)
      return .handled
  }
  .onKeyPress(.init(.tab, modifiers: .shift)) {
      store.cycleVariant(forward: false)
      return .handled
  }
  ```

- [ ] **E.6** `FilterPanelView` を実装

  ```swift
  struct FilterPanelView: View {
      @Binding var criteria: FilterCriteria
      var body: some View {
          Form {
              Section("Camera") {
                  ForEach(availableCameras, id: \.self) { cam in
                      Toggle(cam, isOn: criteriaBinding(camera: cam))
                  }
              }
              Section("ISO") {
                  RangeSlider(range: $criteria.isoRange, bounds: 50...102400)
              }
              Section("Focal Length") {
                  RangeSlider(range: $criteria.focalRange, bounds: 8...800)
              }
              Section("Date") {
                  DatePicker("From", selection: fromBinding, displayedComponents: .date)
                  DatePicker("To",   selection: toBinding,   displayedComponents: .date)
              }
              Section("Rating") {
                  ForEach(0...5, id: \.self) { r in
                      Toggle("\(r) Stars", isOn: criteriaBinding(rating: r))
                  }
              }
              Section("Label") { /* 色ドット toggle */ }
              Section("Flag")  { /* pick/reject/none toggle */ }
              Button("Reset") { criteria = FilterCriteria() }
          }
      }
  }
  ```

**完了基準**:
- iced 版と SwiftUI 版で同じディレクトリの `shot_groups` 件数が一致する

---

## Phase F: ビューア + 設定 + i18n 完成

**目的**: フルレズビューア・設定画面・About 画面・多言語対応・メニューバーを完成させ、iced 版との機能パリティを達成する。

- [ ] **F.1** `ViewerView` を実装

  ```swift
  struct ViewerView: View {
      @Binding var isPresented: Bool
      let entry: PhotoEntry
      @State private var fullImage: CGImage? = nil

      var body: some View {
          VStack(spacing: 0) {
              // 上部バー
              HStack {
                  Button("Close") { isPresented = false }
                  Spacer()
                  Text(entry.path.lastPathComponent).font(.headline)
                  Spacer()
                  NavigationButtons()
              }
              .padding()
              // フルレズ表示 (max 4000px)
              if let img = fullImage {
                  Image(img, scale: 1, label: Text(""))
                      .resizable()
                      .scaledToFit()
              } else {
                  ProgressView()
              }
          }
          .task { fullImage = try? await loadFullRes(entry) }
          .onDisappear { fullImage = nil }   // ARC で即解放
      }
  }
  ```

  `Space` キーで開閉:

  ```swift
  .onKeyPress(.space) {
      isViewerPresented.toggle()
      return .handled
  }
  ```

- [ ] **F.2** `SettingsView` を実装

  ```swift
  struct SettingsView: View {
      @AppStorage("defaultPath") var defaultPath = ""
      @AppStorage("language")    var language    = "system"
      @AppStorage("theme")       var theme       = "auto"

      var body: some View {
          Form {
              TextField("Default Folder", text: $defaultPath)
              Picker("Language", selection: $language) {
                  Text("System").tag("system")
                  Text("日本語").tag("ja")
                  Text("English").tag("en")
              }
              Picker("Theme", selection: $theme) {
                  Text("Auto").tag("auto")
                  Text("Light").tag("light")
                  Text("Dark").tag("dark")
              }
          }
      }
  }
  ```

- [ ] **F.3** `AboutView` を実装

  ```swift
  struct AboutView: View {
      var body: some View {
          VStack(spacing: 16) {
              // B モノグラム (SF Symbols または カスタムシンボル)
              Image(systemName: "photo.on.rectangle.angled")
                  .font(.system(size: 64))
              Text("bridge-lite").font(.largeTitle.bold())
              Text(Bundle.main.version).foregroundStyle(.secondary)
              Text(String(localized: "about.description"))
                  .multilineTextAlignment(.center)
              Button("Close") { dismiss() }
          }
          .padding(40)
          .frame(width: 360)
      }
  }
  ```

- [ ] **F.4** `Localizable.xcstrings` に ja/en 完備

  ```json
  {
    "sourceLanguage": "en",
    "strings": {
      "error.io":              { "ja": "ファイルの読み書きに失敗しました" },
      "error.unsupportedFormat": { "ja": "未対応のファイル形式です" },
      "error.xmpParse":        { "ja": "XMP の読み込みに失敗しました" },
      "error.xmpWrite":        { "ja": "XMP の書き込みに失敗しました" },
      "error.db":              { "ja": "データベースエラーが発生しました" },
      "error.thumbnailDecode": { "ja": "サムネイルの生成に失敗しました" },
      "error.notFound":        { "ja": "ファイルが見つかりません" },
      "about.description":     { "ja": "RAW+JPG の高速セレクト専用ビューア" }
    }
  }
  ```

- [ ] **F.5** `CommandMenu` / `CommandGroup` を完成させる

  ```swift
  // BridgeLiteApp.swift
  var commands: some Commands {
      CommandGroup(replacing: .newItem) {
          Button("Open Folder…") { openFolder() }
              .keyboardShortcut("o")
      }
      CommandMenu("View") {
          Button("Show Filter Panel") { store.showFilter.toggle() }
          Button("Toggle Grid/Single") { store.viewMode.toggle() }
          Button("Toggle Sidebar")     { store.showSidebar.toggle() }
          Divider()
          Button("Enter Fullscreen")   { toggleFullscreen() }
              .keyboardShortcut("f", modifiers: [.control, .command])
      }
      CommandMenu("Rate") {
          ForEach(0...5, id: \.self) { r in
              Button("\(r) Stars") { store.setRating(r) }
                  .keyboardShortcut(KeyEquivalent(Character("\(r)")))
          }
      }
  }
  // Preferences は Settings Scene で自動的に Cmd+, に割り当て
  ```

- [ ] **F.6** 機能パリティ手動チェックリスト

  | 機能 | iced 版 | SwiftUI 版 |
  |---|---|---|
  | フォルダ開く (Cmd+O) | ✓ | |
  | サムネイルグリッド表示 | ✓ | |
  | RAW/JPG ペア表示 | ✓ | |
  | EXIF サイドバー 7行 | ✓ | |
  | XMP レーティング (0-5) | ✓ | |
  | XMP ラベル (6色) | ✓ | |
  | フラグ (pick/reject) | ✓ | |
  | キーバインド (0-9, p, x, u) | ✓ | |
  | フィルタパネル | ✓ | |
  | フルレズビューア (Space) | ✓ | |
  | バリアントストリップ | ✓ | |
  | Tab でバリアント循環 | ✓ | |
  | 設定画面 (Cmd+,) | ✓ | |
  | About 画面 | ✓ | |
  | ja/en 多言語対応 | ✓ | |
  | Adobe Bridge XMP 互換 | ✓ | |

**完了基準**:
- iced 版の全機能を SwiftUI 版でカバーしている

---

## Phase G: iced-app 廃止 + クリーンアップ

**目的**: iced 関連の技術負債をゼロにし、クリーンな Rust core + SwiftUI 構成に仕上げる。

- [ ] **G.1** `crates/iced-app/` を workspace の `members` から外し、ディレクトリを削除

  ```toml
  # Cargo.toml — iced-app を削除
  [workspace]
  members = ["crates/bridge-core", "crates/bridge-ffi"]
  ```

- [ ] **G.2** bridge-core から移行期ラッパを削除
  - `phash.rs` の `compute_phash_sync` 削除
  - その他 `#[deprecated]` マークした移行期関数を削除

- [ ] **G.3** bridge-core から `dirs-next` 依存を削除確認

  ```sh
  cargo tree -p bridge-core | grep dirs-next  # 出力なし
  ```

- [ ] **G.4** bridge-core から `image` クレート依存を削除

  ```sh
  cargo tree -p bridge-core | grep '^image '  # 出力なし
  ```

  RAW JPEG バイト列は `Vec<u8>` で返すだけ。デコードは Swift 側の `CGImageSource` が担う。

- [ ] **G.5** `macos/cgimage_shim.cpp` を削除

  ```sh
  find . -name '*.cpp' -not -path '*/vendor/*'  # 出力なし
  ```

- [ ] **G.6** `assets/icons/*.svg` / `assets/fonts/*` を削除
  - iced 向けカスタムアイコンは SF Symbols に置換済み
  - 残すべきアイコンがある場合は `xcode/BridgeLite/BridgeLite/Assets.xcassets/` に移動

- [ ] **G.7** ルートの `build.rs` (cc 経由の C++ コンパイル設定) を削除

- [ ] **G.8** `README.md` を更新
  - ビルド方法: `tools/build-rust-xcframework.sh && xcodebuild ...`
  - 依存関係: Xcode 16+, Rust 1.80+, Adobe XMP Toolkit (vendor 済み)
  - 旧 `cargo run` の手順を削除

- [ ] **G.9** `CORE-GUI.md` / `TODO-swiftUI.md` を最終更新
  - 実際に削除したファイルのリストを反映
  - 完了したタスクにチェックを入れる

**完了基準**:

```sh
# iced/muda/image 依存が bridge-core に残っていないこと
cargo tree -p bridge-core | grep -E '(iced|muda|image_hasher|image)'
# → 出力なし

# C++ ファイルが vendor 外に残っていないこと
find . -name '*.cpp' -not -path '*/vendor/*'
# → 出力なし

# Rust テスト全パス
cargo test -p bridge-core
# → test result: ok. 25 passed; 0 failed

# Swift テスト全パス
xcodebuild test -scheme BridgeLite
# → ** TEST SUCCEEDED **
```

---

## 検証チェックリスト (全フェーズ共通)

| チェック項目 | 対象フェーズ | 状態 |
|---|---|---|
| `cargo test --workspace` | Phase A | [ ] |
| `cargo test -p bridge-core` | Phase B 以降 | [ ] |
| `cargo run -p bridge-lite-iced` (従来動作維持) | Phase G まで | [ ] |
| `xcodebuild test -scheme BridgeLite` | Phase C 以降 | [ ] |
| Adobe Bridge XMP 互換: `DSE06383.xmp` (`photoshop:LabelColor="red"`) | Phase D | [ ] |
| Adobe Bridge XMP 互換: `DSE06419.JPG` (`xmp:Rating=3`) | Phase D | [ ] |
| btime 保全: XMP 書き込み前後で `st_birthtime` が変わらない | Phase D | [ ] |
| shot grouping 正確性: iced 版と SwiftUI 版の件数一致 | Phase E | [ ] |
| メモリ使用量: Activity Monitor で 5,000 枚スキャン後 1,500 MB 未満 | Phase F | [ ] |

---

## 並行作業マップ

```
Phase A → Phase B → Phase C → Phase D ─┐
                                         ├─→ Phase F → Phase G
                              Phase E ──┘
```

### 作業方針

- **Phase C 以降は iced-app のメンテを凍結する** (バグ修正のみ受け付ける)
- **D と E は独立して並行着手可能**
  - D: EXIF/XMP 編集 (Swift actor + Rust write_xmp)
  - E: shot grouping / pHash / フィルタパネル (Rust reindex_shot_groups)
- **F.4 (Localizable.xcstrings の骨組み)** は Phase C 完了直後に作成し、D・E の実装中に文字列を追加していく
- **Phase G は Phase F の全機能確認後に実施** (削除は不可逆なため)

### 各フェーズの目安工数

| フェーズ | 内容 | 目安 |
|---|---|---|
| A | Workspace 化 | 0.5 日 |
| B | bridge-core 切り出し | 2–3 日 |
| C | Xcode + bridge-ffi + 最小グリッド | 2–3 日 |
| D | EXIF/XMP 編集 UI | 2 日 |
| E | Shot grouping + pHash + フィルタ | 2–3 日 |
| F | ビューア + 設定 + i18n 完成 | 2 日 |
| G | iced-app 廃止 + クリーンアップ | 0.5 日 |
| **合計** | | **約 12–14 日** |
