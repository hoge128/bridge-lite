# bridge-lite 実装 TODO

> ⚠️ **移植時の必読落とし穴**: 写真 ID をフォルダごとに 1 から振り直すと「別フォルダの写真が開く」バグになる。
> 画像 ID は**フォルダ横断でセッション内一意**にし、スタール参照は None で安全に失敗させること。
> 詳細・チェックリスト: `knowledge/photo-id-reuse-bug.md`（macOS 版で 2026-06 に修正済み、同根本原因が iced 版にも存在しうる）。

## Phase 1: コア描画基盤 ✅ 完了

- [x] `cargo init` でプロジェクト初期化
- [x] 依存 crate 追加 (iced, tokio, rayon, kamadak-exif, rusqlite, notify, image, dirs-next)
- [x] `src/` ディレクトリ構成
  - `main.rs` — エントリポイント
  - `app.rs` — iced Application (ELM Model/Update/View)
  - `scanner.rs` — ディレクトリスキャン・ファイル一覧取得
  - `thumbnail.rs` — サムネイル生成パイプライン
  - `metadata.rs` — EXIF 読み取り (kamadak-exif)
  - `db.rs` — SQLite メタデータインデックス (スキーマのみ、Phase 2 で使用)
- [x] iced ウィンドウ表示 (wgpu バックエンド)
- [x] ディレクトリ入力バー + 「開く」ボタン
- [x] ファイル一覧取得 (JPEG/PNG/TIFF/WebP/BMP/GIF + RAW プレースホルダー)
- [x] サムネイル生成 (image crate、中央クロップ、tokio spawn_blocking)
- [x] GPU テクスチャへアップロード → 5列グリッド表示
- [x] EXIF サイドバー (カメラ・日時・露出・F値・ISO・焦点距離)
- [x] スライディングウィンドウキャッシュ (THUMB_CONCURRENCY=16 並列キュー、VecDeque で順序保持)
- [ ] RAW 埋め込み JPEG 抽出 (Phase 4)

## Phase 2: メタデータ ✅ 完了

- [x] kamadak-exif で EXIF 読み取り (撮影日時・カメラ・焦点距離・ISO)
- [x] SQLite (rusqlite) でメタデータインデックス構築 + WAL モード
- [x] バックグラウンドで全画像の EXIF を並列インデックス (DB キャッシュあり)
- [x] サイドバーにメタデータ即時表示 (2回目以降は DB から)
- [x] ステータスバーにインデックス進捗を表示
- [ ] rexiv2 で XMP 読み取り (レーティング・キーワード) → Phase 3 で検討

## Phase 3: フィルタリング ✅ 完了

- [x] 再帰ディレクトリスキャン (walkdir, depth 10)
- [x] カメラ機種フィルタ (チェックボックス、インデックス完了後に動的表示)
- [x] ISO 範囲フィルタ (最小/最大テキスト入力)
- [x] 焦点距離範囲フィルタ mm (最小/最大テキスト入力)
- [x] 日付範囲フィルタ (YYYY-MM-DD 入力)
- [x] フィルタパネル表示/非表示トグル
- [x] ステータスバーに「X / Y 枚 (フィルタ中)」表示
- [x] フィルタリセットボタン
- [ ] XMP レーティングフィルタ → Phase 4 で検討

## Phase 3.5: キーボードナビ + プレビュー ✅ 完了

- [x] ← → キーで filtered 画像間を循環ナビゲーション (iced keyboard::listen)
- [x] 画像選択時にサイドバーへ中解像度プレビュー表示 (最大 1000px, 非同期ロード)
- [x] RAW ファイルはサムネイルをプレビューに流用
- [x] ステータスバーに「← → キーで移動」ヒント表示

## Phase 4: RAW サムネイル + プレビュー ✅ 完了

- [x] RAW ファイルの埋め込み JPEG 抽出 (src/raw_thumb.rs)
  - IFD1 (In(1), ~8 KB) → サムネイル用 (高速)
  - IFD0 (In(0), ~174 KB) → サイドバープレビュー用
  - IFD2 (In(2), ~3 MB) → Phase 5 フル解像度用に予約
- [x] Sony ARW (DSE06383.ARW) で動作確認 (全3オフセット有効 JPEG 確認済み)
- [x] RAW ファイルがグリッドでもサムネイル表示 ("RAW" プレースホルダー廃止)
- [x] RAW クリック時にサイドバーへ 174KB 中解像度プレビュー表示
- [x] IFD2 の 3MB JPEG をフルスクリーンビューアで使用 (Space/EnterViewer、Escape で閉じる)
- [ ] LibRaw (rsraw) フルサイズ RAW デコード → Phase 5 で検討

## Phase 5: SMB / ネットワーク対応

- [ ] ネットワーク遅延対策の完全非同期化
- [x] キャッシュの永続化 (SQLite BLOB) — thumbnails テーブル、mtime 検証付き、JPEG 85% 品質

## macOS 最適化 (Phase 1 後半)

- [x] CGImageSource FFI 実装 (src/macos_thumb.rs, pure unsafe C extern)
  - `CGImageSourceCreateThumbnailAtIndex()` → JPEG 高速サムネイル (EXIF 回転自動適用)
  - 非RAW JPEG/PNG/TIFF のサムネイル・プレビュー・フルスクリーンに適用
  - 非macOS / 失敗時は image crate へフォールバック
- [x] EXIF 回転補正 (thumbnail::apply_exif_orientation) — フォールバック・RAW パスで使用
- [ ] Apple Silicon 統合メモリ活用 (ゼロコピー GPU upload)

## Phase 6: キャッシュ整合性の自動化

### 背景

現在 `thumbnails` テーブルは `path + mtime` でしかキャッシュ整合性を取っていないため、次の 2 ケースで壊れる:

1. **エンコードパイプラインの変更で過去のキャッシュが不整合になる** — 2026-04-24 に `src/macos_thumb.rs` の Y 軸 CTM フリップを削除した際、既存の ~2974 件の JPEG が v-flipped のまま残留し、手動で `rm ~/Library/Application\ Support/bridge-lite/cache.db` を案内する必要があった。今後 JPEG 品質変更・カラースペース変更・サムネイルサイズ変更などでも同じ問題が再発する。
2. **mtime が信頼できないケース** — `rsync --times` / `cp -p` / Lightroom のフォルダ移動などで mtime が保存されたままソースが差し替わった場合、古いキャッシュを返し続ける。特に Phase 5 (SMB / ネットワーク共有) で顕在化するリスクが高い。

### 実装候補 (検討済み、優先度順)

- [ ] **パイプラインバージョン定数** (本命): `src/db.rs` に `meta(key TEXT PRIMARY KEY, value TEXT)` テーブルを追加し、`init_db()` で `pipeline_version` を現行定数と比較 → 不一致なら `DELETE FROM thumbnails` + バージョン書き換え。`src/thumbnail.rs` に `pub const PIPELINE_VERSION: u32 = 1;` を置き、エンコード方式を変えるたびにインクリメント。実装コスト +10 行程度、人間が意図的に「キャッシュを壊す」宣言をする形なので誤爆しない。
- [ ] **ソース内容ハッシュをキーに含める**: mtime の代わりに `blake3` / `xxhash` の先頭+末尾+サイズハッシュを使う。mtime 偽装 (rsync 等) 耐性が付く。Phase 5 のネットワーク共有対応と合わせて導入するのが自然。
- [ ] (参考) `build.rs` で `macos_thumb.rs` / `thumbnail.rs` のソース SHA256 を自動計算して env var 化する案もあったが、無関係なコメント修正でも誤爆するので却下寄り。

## Phase 7: PaneGrid による自由配置レイアウト

### 背景

現在のレイアウトは `row![filter_panel, grid, sidebar]` の固定 3 カラム構成で、ツールバーの ▲/▼ ボタンで表示/非表示のみ切替可能。VSCode のように **ドラッグでパネルを並び替え・分割** したいというユーザー要望がある。

### 実装方針

- `iced::widget::pane_grid::PaneGrid` に移行する。
  - 各パネル (filter / grid / sidebar) を `PaneGrid` の State として管理。
  - ドラッグハンドルでパネル間仕切りを動かしてリサイズ可能。
  - ドロップでパネルを入れ替え可能。
- `PaneGrid::on_drag` / `on_resize` / `on_click` の各コールバックを `Message` にマップ。
- 現在の `App.show_filters` / `show_grid` / `show_sidebar` フラグは `PaneGrid::State` の close 操作に置き換わる。

### 実装コスト

- `src/app.rs` の `view()` ほぼ全面書き換え (+ PaneGrid State の追加)。
- `filter_panel()` / `thumbnail_grid()` / `sidebar()` の各 view 関数本体は流用可能。
- 優先度: ユーザーが「位置をドラッグで変えたい」とフィードバックしたら着手。

## Phase 8: UI アーキテクチャ刷新 (後日対応)

### 背景

現在の iced 0.14 (wgpu) ベースの UI には以下の構造的制約があり、将来的に SwiftUI への移行を検討する。

### 8-1: Liquid Glass / macOS ネイティブ UI

macOS 26 の Liquid Glass (すりガラス + 光屈折) を本格対応するには:

- **NSVisualEffectView 統合** (中): objc2-app-kit 経由で winit の NSWindow に差し込む。ウィンドウ全体に macOS vibrancy (backdrop blur) を適用可能。実装 ~80 行。ただし「すりガラス」どまりで光屈折は出ない。
- **wgpu カスタムシェーダー** (大): multi-pass rendering (scene → blur pass → glass composite)。iced の render pipeline を fork して改造しない限り、バックバッファへのアクセス手段がないため現実的でない。
- **SwiftUI 移行** (大、推奨): `.glassEffect()` modifier でネイティブ Liquid Glass がそのまま出る。Rust コアロジックは UniFFI / swift-bridge 経由で再利用。

### 8-2: Rust (コア) + Swift (UI) 分離アーキテクチャ

- **方針**: `scanner` / `db` / `thumbnail` / `metadata` / `raw_thumb` は Rust ライブラリとして維持。`app.rs` / `menu.rs` を SwiftUI に置き換える。
- **ブリッジ**: [UniFFI](https://github.com/mozilla/uniffi-rs) (Mozilla 製、実績最大) または [swift-bridge](https://github.com/chinedufn/swift-bridge) でバインディング自動生成。
- **ビルド**: Xcode Build Phase で `cargo build --release` を呼び、生成した `.a` をリンク。
- **非同期**: Rust の tokio async ↔ Swift async/await はコールバック経由でブリッジ。UniFFI の async サポートが 2024 以降改善済み。
- **工数目安**: FFI 境界設計 2日 + UniFFI セットアップ 3日 + SwiftUI UI 書き直し 1〜2週間 + Liquid Glass 適用 1〜2日。

### 8-3: PaneGrid による自由配置レイアウト (iced 継続の場合)

(Phase 7 参照) iced を継続する場合のみ検討。SwiftUI 移行を選択した場合は不要。

### 8-4: i18n の改善点

- システムロケールからの自動言語検出 (`sys_locale` crate 導入)。現状は初回起動時に一律 Japanese。
- `PredefinedMenuItem` (Undo/Copy/Quit 等) は macOS のシステム言語に従う。ユーザーがアプリ内で English を選んでも Predefined 項目はシステム言語のまま。SwiftUI 移行後は `LocalizedStringKey` で統一的に解決できる。

### 8-5: アクセシビリティ

iced はネイティブ Accessibility API (VoiceOver) との連携が限定的。SwiftUI は標準でアクセシビリティ対応。

---

## Phase 9: 評価機能 (XMP レーティング)

設計詳細は `~/.claude/plans/1-2-5-buzzing-shell.md` を参照。

### 9-1: 読み込み基盤 ✅ 完了 (2026-04-24)

- [x] `src/xmp.rs` 新設 (XmpData / Label / Flag 型、`read_sidecar()`、stem-only 命名の Adobe 互換)
- [x] `src/db.rs` に `migrate_xmp_columns()` 追加 (images テーブルに `rating`/`xmp_label`/`xmp_flag` 列)
- [x] `src/i18n.rs` に `sidebar_rating`/`sidebar_label`/`sidebar_flag` 文言追加
- [x] `src/app.rs` に `xmp_data: HashMap<usize, XmpData>` 状態、`XmpBatchLoaded` メッセージ、サイドバー表示 (★☆)
- [x] `DirectoryScanned` 時に XMP バッチ読み込みタスクを並走

### 9-2: 書き込み基盤 ✅ 完了 (2026-04-24)

- [x] `Cargo.toml` に `xmp_toolkit = "1.12.1"` 追加 (Adobe XMP Toolkit SDK バインディング)
- [x] `Cargo.toml` に `libc = "0.2"` 追加 (btime 保全用)
- [x] `src/btime.rs` 新設 — macOS `setattrlist(ATTR_CMN_CRTIME)` で btime 保全
- [x] `src/xmp.rs` に `write_sidecar(image_path, XmpData) -> Result<()>` 実装
  - パス検証 `debug_assert!` (.xmp 拡張子必須、画像本体と同ディレクトリ)
  - atomic write (`.xmp.tmp` → `fs::rename`) + `preserve_btime` でラップ
  - 既存属性温存、rating/label/flag のみ差し替え
  - `photoshop:LabelColor` + `xmp:Label` を両方書き込み (Bridge 互換)
- [x] DB `update_xmp()` 追加 (書き込み後に rating/xmp_label/xmp_flag をキャッシュ)
- [x] `Label::from_label_color()` 追加、`from_str()` に Bridge 英語値マッピング追加

### 9-3: キーボード入力 ✅ 完了 (2026-04-24)

- [x] `src/app.rs` の `KeyboardEvent` ハンドラに以下を追加:
  - `0`〜`5`: 星設定 (0 で解除)
  - `6`: Red / `7`: Yellow / `8`: Green / `9`: Blue (トグル)
  - `P`: Pick トグル / `X`: Reject トグル
- [x] キー入力後に `write_metadata` 非同期呼び出し → `state.xmp_data` 更新 → DB 更新
- [x] `apply_rating_key()` / `toggle_label()` ヘルパー実装

### 9-4: フィルタ拡張 ✅ 完了 (2026-04-24)

- [x] `FilterState` に `filter_ratings: HashSet<u8>` / `filter_labels: HashSet<Label>` / `filter_flags: HashSet<Flag>` 追加
- [x] `passes(&self, exif, xmp)` に XMP フィルタロジック追加
- [x] `filter_panel()` に評価 (checkbox 6択: 未評価〜★★★★★)・ラベル (checkbox 5色)・フラグ (checkbox 2種) セクション追加
- [x] `is_active()` と `FilterReset` を新フィールド対応に更新
- [x] `Message::RatingFilterToggled` / `LabelFilterToggled` / `FlagFilterToggled` 追加

### 9-5: JPG 埋め込み XMP 対応 ✅ 完了 (2026-04-24)

- [x] `read_embedded()` — `XmpMeta::from_file` で JPG/TIFF/PNG の APP1 XMP を読み取り
- [x] `write_embedded()` — `XmpFile::open_file(for_update, use_smart_handler)` で埋め込み書き込み、`preserve_btime` でラップ
- [x] `read_metadata()` / `write_metadata()` ディスパッチャ追加
  - 非 RAW: 埋め込み優先 (→ サイドカーフォールバックは移行期互換用)
  - RAW/HEIC: 従来どおりサイドカー
- [x] `src/app.rs` の XMP バッチ読み取り・書き込み呼び出し側を `read_sidecar/write_sidecar` → `read_metadata/write_metadata` に差し替え
- [x] テスト追加 (8 件全パス):
  - `reads_embedded_jpg_rating` — Bridge 埋め込み星3 を正常に読み取り
  - `roundtrip_embedded_jpg` — 埋め込み書き込み→読み返し一致
  - `embedded_write_preserves_btime` — btime 不変を確認
  - `roundtrip_embedded_jpg` — サイドカーを作成しないことを確認

### 9-6: 手動検証

- [ ] `test/20260221/jpg/DSE06419.JPG` を開く → サイドバーに星3 が表示されること
- [ ] `test/20260221/jpg/DSE06420.JPG` を開く → Bridge の埋め込み Rating=0 が表示 (サイドカーより優先)
- [ ] JPG に bridge-lite で星5 を設定 → JPG 内 XMP 更新・サイドカー不作成・btime 不変
- [ ] Bridge で開いて星5 が反映されていること
- [ ] `test/20260221/raw/DSE06383.ARW` に評価 → 従来どおりサイドカー更新・ARW 本体不変
- [ ] フィルタ: 星★★★ のみ → 3星のみ表示
- [ ] フィルタ: 「未評価」+「★★★★★」同時選択 → 両方表示

---

## Phase 10: RAW+JPG+現像バリエーション切替

設計詳細は `~/.claude/plans/1-2-5-buzzing-shell.md` を参照。

### Phase 10-A ✅ 完了 (2026-04-24)

- [x] `src/scanner.rs` の `ImageEntry` に `shot_id: u64` 追加
- [x] `normalize_stem()` / `compute_shot_id()` 実装:
  - 末尾から剥がす: `-edit\d*` / `_edit\d*` / `-v\d+` / `_v\d+` / ` (N)` (Finder コピー) / `-copy` / `_copy` / `-Edit` / `-Enhanced`
  - 末尾数字は剥がさない (DSC_0001/DSC_0002 誤結合防止)
  - 正規化後 stem が 2 文字以下なら正規化前を採用
  - scanner::tests に 4 件テスト追加、全通過
- [x] `App.shot_groups: HashMap<u64, Vec<usize>>` — DirectoryScanned 時に構築
- [x] `pair_visible()` → `is_representative()` に再設計 (JPG > RAW > EDIT の優先順位)
- [x] `show_lone_raw` チェックボックス・Message・状態・i18n 文言を削除
  - 新ロジックで「JPG なしグループ → RAW が自動的に代表」となるため不要
- [x] `Message::CyclePairVariant { reverse: bool }` 追加
- [x] `Tab` (正方向) / `Shift+Tab` (逆方向) でバリエーション循環
  - `show_settings` / `show_about` 表示中は無反応 (focus-chain 保護)
- [x] サイドバーにバリエーションサムネイル strip (50×40px ボタン、クリックで直接切替)
- [x] サイドバーに `1/2 · JPG` バッジ
- [x] `nav_hint` i18n に `Tab でバリエーション切替` を追加

### Phase 10-A2 ✅ 完了 (2026-04-24)

DxO PureRAW / Lightroom などで現像されたファイルを同一 shot としてグルーピングし、現像済み JPG を代表画像として表示する。

- [x] `src/scanner.rs` の `strip_one_suffix()` に現像ソフトサフィックス剥がしを追加
  - `-dxo*`, `-lightroom*`, `-captureone*`, `-photolab*`, `-topaz*`, `-on1*`, `-luminar*`, `-affinity*`, `-denoise*`, `-gigapixel*`, `-sharpen*` (および `_` バリアント)
  - 例: `DSE06384-DxO_DeepPRIME XD2s` → `DSE06384` と同 shot_id
  - `software_suffix_stripping` テスト追加（合計 13 件パス）
- [x] `src/metadata.rs` に `ExifData.software: Option<String>` 追加 (`Tag::Software` から抽出)
- [x] `src/db.rs` に `software TEXT` カラム追加（`init_schema` + `migrate_xmp_columns` でマイグレーション）
  - `fetch_exif_batch`、`query_exif`、`upsert` の SELECT/INSERT 文を更新
- [x] `src/app.rs` に `DEVELOPED_SOFTWARE_KEYWORDS` + `is_developed()` 追加
  - 対象: Lightroom, DxO, Capture One, Photoshop, Camera Raw, Topaz, ON1, Luminar, Affinity, Darktable, RawTherapee
- [x] `representative_id_of()` を EXIF Software タグベースの 3 段 tier 判定に変更
  - Tier 0: 非 RAW かつ EXIF Software が現像ソフトキーワードを含む（確定済み現像版）
  - Tier 1: その他の非 RAW（カメラ撮影 JPG、EXIF 未ロード）
  - Tier 2: RAW
- [x] サイドバーの vtype バッジを EXIF Software ベースに変更（"EDIT" → "DEV"）
- [x] バリエーション並び順を撮影日時昇順に変更（SOOC JPG → RAW → 現像）
- [x] DxO 出力 DNG のプレビュー対応（macOS CGImageSource フォールバック）

### Phase 10-A2.1 ✅ 完了 (2026-04-25)

- [x] メタデータパネルのプレビュー欄リセット改善
  - `select_image` で `preview_handle = None` を削除 — 前画像を新画像ロード完了まで表示し続ける
  - `Message::PreviewLoaded` を `{ id, handle }` struct variant に変更し stale ロード対策
  - 写真切替時のレイアウトシフト・灰色フラッシュが消える
- [x] バリエーションサムネに J/R/D バッジ（右上隅オーバーレイ）
  - `iced::widget::stack!` で `Image` の上に色付きバッジをオーバーレイ
  - `variant_badge_for()` ヘルパーで EXIF Software タグ基準に判定
  - 青=JPG (J) / 赤=RAW (R) / 緑=現像済み (D)、テーマパレットから色を取得

### Phase 10-A2.2 ✅ 完了 (2026-04-25)

- [x] Fix A: `src/db.rs` に `meta(key, value)` テーブルと `EXIF_SCHEMA_VERSION = 2` を追加
  - 既存 DB (バージョンなし = v1 扱い) では `DELETE FROM images` で一回だけ全件再インデックス
  - サムネイルキャッシュは温存（mtime 検証独立）
  - 2 回目以降の起動は meta テーブルのバージョン一致で DELETE をスキップ
- [x] Fix B: `src/xmp.rs` に `XmpData.developed: bool` 追加、`detect_developed()` 実装
  - `crs:RawFileName` / `crs:HasSettings` — Lightroom / DxO 共通の現像済みフィンガープリント
  - `DxO:WhiteLevel` / `DxO:AdobeWhiteLevel` — DxO 固有プロパティ
  - `xmpMM:History[N]/stEvt:softwareAgent` キーワードマッチ（固定 1〜10 インデックス走査）
  - EXIF Software が `imanage` 等で上書きされていても XMP 経由で DEV を正しく検出
- [x] `src/app.rs` の `is_developed()` を EXIF + XMP 合成版に更新
- [x] `representative_id_of`・`variant_badge_for`・サイドバー vtype に `xmp` を引き渡し
- [x] 単体テスト 3 件追加（crs / DxO / 非現像の 3 ケース）

### 10-A2 手動検証チェックリスト

- [x] `test/20260221/` を開く → `DSE06384.ARW`/`.JPG`/`-DxO_DeepPRIME XD2s.jpg`/`-DxO_DeepPRIME XD2s.dng` が 1 セルに畳まれる
- [x] EXIF ロード完了後（数秒以内）、グリッドのサムネイルが `-DxO_DeepPRIME XD2s.jpg` に切り替わる
- [x] Tab で 4 バリエーション間を循環、Shift+Tab で逆方向
- [x] サイドバーバッジが `1/4 · DEV` / `2/4 · JPG` / `3/4 · RAW` / `4/4 · RAW` のように切り替わる
- [x] EXIF 未ロード時点でもクラッシュしない（tier 1 同点フォールバック）
- [x] 既存 DB を持つ状態で起動 → `ALTER TABLE ADD COLUMN software` が冪等に動作

### Phase 10-B ✅ 完了 (2026-04-25) — EXIF タイムスタンプによる再編成

- [x] `src/pairing.rs` 新設 — `reindex_shot_groups()` 実装、5 件テスト
- [x] `ExifData.subsec: Option<String>` 追加 (`Tag::SubSecTimeOriginal`) + DB v3 マイグレーション
- [x] `Message::ReindexShotGroups` 追加 — 全 EXIF インデックス完了時に自動発火
  - 発火タイミング: `all_exif_indexed()` = `indexed_count >= images.len()`
  - `ExifBatchLoaded`（ミスなし）と最後の `ExifIndexed`（ミスあり）の両経路に対応
- [x] 再編成アルゴリズム:
  - **Split**: stem グループ内でタイムスタンプが 10 秒超離れていれば分割（EXIF 欠損は最早クラスタへ）
  - **Merge**: 異グループ間で `(datetime, subsec)` が一致 → 統合（subsec なし = マージ禁止、連写安全側）
  - EXIF 欠損エントリは stem ベース shot_id を維持
  - `state.shot_groups` を全面再構築、`entry.shot_id` を更新 → UI 再描画

### Phase 10-C ✅ ピクセルベースの類似判定 (2026-04-25)

- [x] `image_hasher 3.1` クレートで pHash (64 bit, DCT 8x8) を計算、`phashes` テーブルに mtime 検証付きキャッシュ
- [x] shot_group 再編成時に「ファイル名違い + hamming ≤ 8 かつ datetime ≤ 2 秒」で統合
  - Phase 10-B（EXIF タイムスタンプ）と連携し精度を向上
  - 代表 pHash は bit-wise majority vote で合成（AEB 露出違いに耐性）
  - `parse_datetime_secs` を chrono::NaiveDateTime で正しく実装（月跨ぎバグ修正）
  - `PHASH_CONCURRENCY = 4` — サムネイル生成完了後に逐次計算 (CPU 飽和回避)

### 10-A 手動検証チェックリスト

- [ ] `test/20260221/` を開く → JPG/ARW 同 stem ペアが 1 セルに畳まれる
- [ ] ペア選択 → サイドバーに `1/2 · JPG` バッジとサムネイル strip が表示される
- [ ] `Tab` → RAW に切替、バッジが `2/2 · RAW`
- [ ] `Tab` → JPG に戻る (循環)
- [ ] `Shift+Tab` → 逆方向に循環
- [ ] 設定画面でTab → フォーカス移動のみ (バリエーション切替は無反応)
- [ ] `test/20260221/raw/` のみで開く → RAW が代表として自動表示 (show_lone_raw 削除済みを確認)
- [ ] `foo.jpg` + `foo-edit.jpg` → 1 セル、Tab で切替
- [ ] `DSC_0001.jpg` + `DSC_0002.jpg` (別ショット) → 別々に表示、Tab 無反応

---

## Phase 11: UX 改善 (4 サブ機能)

設計詳細は `~/.claude/plans/1-2-5-buzzing-shell.md` を参照。

### 11-1: スクロールバー固定化

- [ ] `state.images` がスキャン中に増える挙動を再確認 (既に一括代入の可能性あり)
- [ ] サムネイル未ロード時の placeholder 寸法を 180×180 に完全一致させる
- [ ] 大量フォルダ (1000+ 枚) で scroll thumb が動かないことを検証

### 11-2: 日付オーバーレイ (年ガター)

- [ ] `state.scroll_offset: f32` を `scrollable::on_scroll(Viewport)` で保持
- [ ] `state.year_anchors: Vec<(usize, i32)>` を事前計算
- [ ] グリッド脇に固定幅 24px の `year_gutter()` ウィジェットを Stack 配置
- [ ] 年ラベルクリックで `scrollable::scroll_to` ジャンプ

### 11-3: プレビュー拡大

- [ ] `SIDEBAR_WIDTH` 定数を `state.sidebar_width: f32` へ可変化
- [ ] サイドバー左端にドラッグハンドル (`mouse_area`)
- [ ] プレビュー `height(220.0)` 固定を解除 → `width: Length::Fill` + `ContentFit::Contain`

### 11-4: masonry / タイルモード

- [ ] `state.view_mode: ViewMode { Grid, Masonry }` enum
- [ ] メニューバーに切替トグル (`src/menu.rs`)
- [ ] greedy row-packing: 各行の幅合計が window 幅に近づくまで画像を詰める
- [ ] 表示高固定 (240px)、幅は EXIF の aspect ratio に従う
- [ ] EXIF 未ロード画像は正方形プレースホルダー
- [ ] アスペクト比サムネイル生成の検討 (Phase 別出し候補)

### 11-5: 未解決事項

- [ ] カラーラベル・フラグのキーバインド (Adobe 流 `6-9`+`P`/`X` vs macOS 流 `Cmd+1〜5`) の最終決定
- [ ] masonry 用の縦長サムネイル生成 (現状 180px 正方形)
- [ ] Phase B 再編成中の選択状態維持 (shot_id ベースの追跡設計)

---

## 検証目標

- 1000 枚フォルダで Adobe Bridge より 5 倍以上速いサムネイル表示
- アイドル時メモリ < 100MB
- 60fps スクロール維持
