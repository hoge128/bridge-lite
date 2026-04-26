# Phase A: Cargo Workspace 化 — 作業メモ

## 実施日時
2026-04-25

## 概要
単一クレートの Rust プロジェクトを Cargo workspace 構成に移行した。
ブランチ: feat/swiftui-migration

## 作成したディレクトリ
- crates/iced-app/
- crates/iced-app/src/
- crates/bridge-core/
- crates/bridge-core/src/
- crates/bridge-ffi/
- crates/bridge-ffi/src/
- tools/
- xcode/

## 移動・コピーしたファイル

### src/ → crates/iced-app/src/
- app.rs
- btime.rs
- config.rs
- db.rs
- i18n.rs
- macos_thumb.rs
- main.rs
- memory_guard.rs
- menu.rs
- metadata.rs
- pairing.rs
- phash.rs
- raw_thumb.rs
- scanner.rs
- theme.rs
- thumbnail.rs
- xmp.rs

### その他
- build.rs → crates/iced-app/build.rs
- macos/ → crates/iced-app/macos/
- assets/ → crates/iced-app/assets/  ※ include_bytes! の相対パス解決のため

## 新規作成ファイル
- Cargo.toml (workspace 設定に置き換え)
- crates/iced-app/Cargo.toml (旧 Cargo.toml をベースに name="bridge-lite-iced"、[patch] 削除、bridge-core 依存追加)
- crates/bridge-core/Cargo.toml
- crates/bridge-core/src/lib.rs
- crates/bridge-core/src/error.rs
- crates/bridge-ffi/Cargo.toml
- crates/bridge-ffi/src/lib.rs
- tools/build-rust-xcframework.sh

## 修正事項

### assets/ パス問題
crates/iced-app/src/theme.rs 等で `include_bytes!("../assets/...")` を使用しており、
パッケージルート (crates/iced-app/) に assets/ が存在しないとコンパイルエラーになった。
→ assets/ を crates/iced-app/assets/ にコピーして解決。

### build.rs のパス
crates/iced-app/build.rs 内の `macos/cgimage_shim.cpp` は cargo が
パッケージルート (crates/iced-app/) 基準で解決するため、変更不要だった。

## ビルド結果
```
cargo build --workspace → Finished (エラー 0)
cargo test --workspace  → 29 passed; 0 failed
```

## 残課題
- Phase B: bridge-core に実際のコアロジックを移植する
- Phase C: bridge-ffi に swift-bridge FFI 実装、tools/build-rust-xcframework.sh を完成させる
- Xcode プロジェクトの作成 (xcode/ ディレクトリ)
- 元の src/、build.rs、macos/ (workspace ルート) はそのまま残っている
  → Phase B 移植完了後に削除を検討
- assets/ が workspace ルートと crates/iced-app/ の両方に存在する重複状態
  → Phase B で整理予定
