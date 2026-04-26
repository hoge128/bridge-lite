# Lightroom Classic カタログ統合による現像済み検出

## 問題の背景

Lightroom Classic はデフォルトで現像設定をカタログ (`.lrcat`) 内部にのみ保存し、
RAW ファイルや XMP サイドカーには書き戻さない。

bridge-lite は現在 XMP/EXIF タグから現像済みを判定するため、
**「XMP に書き込む」設定が OFF のまま Lightroom で現像した RAW は
現像済みとして認識されない**。

具体的には:

- グリッドに "R" バッジが表示され、"DEV" にならない
- `computeRepresentatives` の Tier-1 (DEV 優先) が発動せず、
  現像済みの RAW がペアの JPG より後回しになる可能性がある

## ユーザーへの現行ワークアラウンド

Lightroom Classic で以下のいずれかを行うと bridge-lite が正しく検出できる:

1. `環境設定 → カタログ設定 → メタデータ → 変更を自動的に XMP に書き込む` を ON
2. 選択ファイルに `メタデータ → ファイルにメタデータを保存` (Cmd+S) を実行

## 将来的な実装案: `.lrcat` クエリ

Lightroom カタログは SQLite データベースであるため、
ファイルパスと紐付いた現像設定の有無を直接クエリできる。

### クエリ例

```sql
SELECT ai.hasDevelopSettings
FROM Adobe_images ai
JOIN AgLibraryFile af   ON af.id_local   = ai.rootFile
JOIN AgLibraryFolder fo ON fo.id_local   = af.folder
WHERE af.baseName  = 'DSE06419'
  AND af.extension = 'ARW'
```

`hasDevelopSettings = 1` であれば現像済み。

### 実装上の課題

| 課題 | 詳細 |
|---|---|
| カタログの場所の探索 | デフォルトは `~/Pictures/Lightroom/*.lrcat` だが任意の場所に変更可能 |
| ロック競合 | Lightroom 起動中はカタログに書き込みロックがかかる (読み取りは可能な場合が多い) |
| スキーマの安定性 | Lightroom バージョンアップでスキーマが変わる可能性 |
| 複数カタログ | ユーザーが複数カタログを管理している場合の対応 |
| パフォーマンス | フォルダスキャンのたびにカタログを毎回クエリするとスローになる |

### 実装方針 (案)

1. ユーザー設定で Lightroom カタログのパスを指定させる
2. 初回スキャン時に `.lrcat` を読み取り専用でオープン
3. スキャン結果の `baseName` + `extension` でバッチクエリ
4. `hasDevelopSettings = 1` のファイルを `developed = true` として扱う
5. カタログが更新されたら次回スキャン時に再クエリ

Rust 側は `rusqlite` クレートで実装可能。FFI 経由で Swift に渡す。

## 優先度

**低** — LR の「XMP 自動書き込み」設定 ON というワークアラウンドで実用上は解決できるため、
現時点では実装コストに見合わない。ユーザーからの需要が高まったら着手する。
