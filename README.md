# bridge-lite

RAW+JPG 同時撮影向けの軽量画像セレクトビュワー。Rust コアロジック + SwiftUI GUI のハイブリッド構成で、Adobe Bridge より高速なサムネイル表示を macOS ネイティブ API で実現する。

## 設計原則

- **閲覧・評価に徹する** — 現像・編集は行わない
- **ファイルは変更しない** — XMP サイドカーへのレーティング書き込みのみ許可
- **RAW+JPG を一枚として扱う** — ペアリングと現像バリアントを自動グルーピング
- **macOS ネイティブ API 優先** — CGImageSource / Metal / SQLite WAL

詳細アーキテクチャは [CORE-GUI.md](CORE-GUI.md) を参照。

## 動作要件

- macOS 14 (Sonoma) 以降
- Xcode 16 以降
- Rust toolchain (`rustup` 経由、`aarch64-apple-darwin` ターゲット)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## ビルド手順

### 1. Rust ライブラリをビルド

```sh
./tools/build-rust-xcframework.sh --release
```

`xcode/BridgeLite/Generated/` に `libbridge_ffi.a` と FFI ヘッダが生成される。

### 2. Xcode プロジェクトを生成（初回または `project.yml` 変更時）

```sh
cd xcode/BridgeLite
xcodegen generate
```

### 3. Xcode でビルド・実行

```sh
open xcode/BridgeLite/BridgeLite.xcodeproj
```

Xcode で `Cmd+B` (ビルド) → `Cmd+R` (実行)。

## 開発上の注意

### ❌ 禁止: `project.pbxproj` を直接編集する

```sh
# やってはいけない
vim xcode/BridgeLite/BridgeLite.xcodeproj/project.pbxproj
python3 edit_pbxproj.py   # 外部スクリプトも同様
```

このプロジェクトは **XcodeGen** (`project.yml`) でプロジェクトファイルを管理している。  
`project.pbxproj` を直接編集すると以下の問題が発生する:

1. Xcode が外部変更を検知してプロジェクトを再読み込みしようとする
2. SPM パッケージ解決処理が走り `Package.resolved` が削除される
3. 再解決に失敗すると `Package.resolved` が消えたまま残る
4. 以降 Xcode が「Couldn't load project」エラーを出し続ける
5. その状態の Xcode は SPM ディレクトリを監視し続けるため、`Package.resolved` を手動で置いても即座に削除されてしまう

**正しい方法**: Swift ファイルの追加・削除・グループ変更はすべて `project.yml` を編集してから `xcodegen generate` を実行する。

```sh
# ファイルを追加したいとき
vim xcode/BridgeLite/project.yml   # sources に追記
cd xcode/BridgeLite
xcodegen generate                  # project.pbxproj を再生成
```

### `Package.resolved` が消えて Xcode が起動できなくなった場合の復旧手順

```sh
# 1. Xcode を完全に終了する（必須）
#    Xcode が起動中だと書き込んでも即削除される

# 2. Package.resolved を復元する
git checkout HEAD -- "xcode/BridgeLite/BridgeLite.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# 3. Xcode を再度開く
open xcode/BridgeLite/BridgeLite.xcodeproj
```

## テスト

```sh
# Rust ユニット / 統合テスト (31件)
cargo test -p bridge-core

# ワークスペース全体
cargo build --workspace
```

## プロジェクト構成

```
bridge-lite/
├── crates/
│   ├── bridge-core/    # Rust コアロジック (scanner, pairing, xmp, db, phash …)
│   └── bridge-ffi/     # swift-bridge による FFI 層
├── xcode/BridgeLite/   # SwiftUI アプリ
├── vendor/xmp_toolkit/ # Adobe XMP Toolkit SDK (パッチ済み)
├── tools/              # ビルドスクリプト
├── test/               # テスト用サンプル画像
└── knowledge/          # 移行ログ・過去ドキュメント
```

## 機能一覧

| 機能 | 詳細 |
|---|---|
| サムネイルグリッド | CGImageSource + SQLite キャッシュ (三層) |
| RAW+JPG ペアリング | stem / EXIF タイムスタンプ / pHash による自動グルーピング |
| XMP レーティング | 0–5 星 / 5色ラベル / Pick・Reject フラグ (Adobe Bridge 互換) |
| フィルタ | カメラ機種 / ISO / 焦点距離 / 日付 / 評価 / ラベル / フラグ |
| フルレズビューア | Space キーで開閉、←/→ ナビゲーション |
| キーバインド | 0–5 (星) / 6–9 (ラベル) / P (Pick) / X (Reject) / Tab (バリアント切替) |
| 多言語対応 | 日本語 / 英語 |
