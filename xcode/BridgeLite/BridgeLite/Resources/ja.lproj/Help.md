<!--
  bridge-lite Help — 日本語版
  編集時のメモ:
  - AttributedString(markdown:) で対応できる記法: **太字**、*イタリック*、`インラインコード`、[リンク](url)、- 箇条書き
  - ## 見出しはフォントサイズが変わらない（AttributedString の制限）
    → swift-markdown-ui (SPM: gonzalezreal/swift-markdown-ui) を導入すれば ## 見出しや画像埋め込みに対応できる
    → 導入する場合: Package.swift に .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0") を追加
  - テーブル・水平線・チェックボックスは AttributedString 非対応（swift-markdown-ui なら対応）
  - 画像は ja.lproj / en.lproj に別々のファイルを置き、Bundle.main.url(forResource:withExtension:) で読み込む
-->

## ナビゲーション

- **← →** 前後の写真に移動
- **↑ ↓** 前後の写真に移動（グリッドでは行単位）
- **Shift + ← → ↑ ↓** 範囲選択しながら移動
- **Cmd + ← →** グループ内の先頭・末尾へジャンプ

## 選択

- **クリック** 写真を選択
- **Cmd + クリック** 選択のトグル（追加／解除）
- **Shift + クリック** 範囲選択
- **Cmd + A** すべて選択
- **Cmd + Option + A** すべて選択解除

## レーティング・ラベル

- **0〜5** 星レーティングを付ける（0 でクリア）
- **6〜9** カラーラベル（6=赤、7=黄、8=緑、9=青）

## 表示モード

- **Space** ビューアモードを開始
- **Escape** ビューアモードを終了
- **Return** 比較モードを開始
- **ダブルクリック** 比較モードを開始
- **Tab** RAW / JPG / 現像済みを切り替え（Shift で逆順）

## 比較モード

- **Ctrl + Tab** グループ・メンバー間を移動
- **Ctrl + Shift + Tab** 逆方向に移動
- **Escape** 比較モードを終了

## ファイル操作

- **Cmd + C** 選択した写真をコピー
- **Delete** または **Ctrl + D** 選択した写真をゴミ箱へ移動
- **Cmd + Z** 操作を元に戻す

## その他

- **フォルダをウィンドウへドロップ** フォルダを開く
- **右クリック（またはサブコントロールクリック）** コンテキストメニューを表示
