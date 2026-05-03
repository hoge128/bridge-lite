# bridge-lite キャッシュアーキテクチャ

## 概要

bridge-lite は 2 層のキャッシュを持つ。それぞれ役割・格納場所・ライフタイムが異なる。

```
ディスク上の元ファイル (RAW / JPEG / etc.)
    │
    │ 初回スキャン時にサムネイル生成
    ▼
┌─────────────────────────────────────────────┐
│  SQLite キャッシュ（ディスク）               │
│  ~/Library/Application Support/BridgeLite/  │
│  cache.db                                   │
│                                             │
│  thumbnails テーブル  JPEG blob 50〜200 KB  │
│  images テーブル      EXIF テキスト          │
│  phashes テーブル     知覚ハッシュ u64       │
│  rendered_thumbnails  RAW 現像済みサムネイル │
└─────────────────────────────────────────────┘
    │
    │ NSCache ミス時に JPEG をデコード
    ▼
┌─────────────────────────────────────────────┐
│  ThumbnailDecodeCache（メモリ）              │
│  NSCache<NSNumber, CGImage>                 │
│  展開済みピクセル 約 1.38 MB / 枚           │
└─────────────────────────────────────────────┘
    │
    │ Metal テクスチャ転送
    ▼
  画面描画
```

---

## 層ごとの詳細

### 1. SQLite キャッシュ（ディスクキャッシュ）

**場所**: `~/Library/Application Support/BridgeLite/cache.db`（WAL モード）

**テーブル**:

| テーブル | キー | 内容 | サイズ感 |
|---|---|---|---|
| `thumbnails` | path (絶対パス) | JPEG blob | 50〜200 KB/枚 |
| `images` | path | EXIF テキスト各種 | 数百 B/枚 |
| `phashes` | path | 知覚ハッシュ u64 | 8 B/枚 |
| `rendered_thumbnails` | (path, engine, width) | RAW 現像サムネイル JPEG | 100〜500 KB/枚 |
| `meta` | key | スキーマバージョン等 | 無視できる |

**有効性の確認方法**: ファイルの mtime（`file_mtime()` = Unix 秒）をキャッシュ行の `mtime` と比較。一致すればキャッシュヒット、不一致なら再生成。

**`cached_at` カラム** (thumbnails / phashes): `store_thumb` / `store_phash` 呼び出し時（=サムネイル書き込み時）に `strftime('%s','now')` で記録。TTL 削除の判定に使用。

**注意**: `cached_at` は書き込み時にのみ更新される。ファイルが変更されなければ `store_thumb` は呼ばれないため、頻繁に閲覧するフォルダでも `cached_at` は最初にキャッシュした日付のまま。TTL を超えると削除・再生成される。

---

### 2. ThumbnailDecodeCache（メモリキャッシュ）

**実装**: `NSCache<NSNumber, CGImage>` (`ThumbnailDecodeCache.swift`)

**キー**: `UInt64`（PhotoEntry の id）

**コスト計算**: `img.bytesPerRow * img.height`
- 720×480 px (3:2 横位置) RGBA: `2880 × 480 = 1,382,400 bytes ≈ 1.38 MB`

**上限**: ユーザー設定（`SettingsStore.thumbnailCacheMB`、デフォルト 300 MB）
- 設定変更時は `ThumbnailDecodeCache.shared.updateLimit(mb:)` で即時反映（再起動不要）
- 上限は物理メモリの 10%（`ProcessInfo.processInfo.physicalMemory / 10`）

**自動エビクション**: `NSCache` は OS のメモリプレッシャー時に自動でオブジェクトを破棄する。`totalCostLimit` はソフト上限（ヒントであり厳密な強制ではない）。

---

## キャッシュキー

SQLite の全テーブルでキーはファイルの**絶対パス**（`path.to_string_lossy()`）。

### 同一ファイルでキーが一致するケース
- `AAA/BBB/001.jpg` を含むフォルダとして `AAA` を開く場合も `BBB` を開く場合も、絶対パスは `/path/to/AAA/BBB/001.jpg` で同一 → **同じキャッシュ行を使用**

### 同一ファイルでキーが異なるケース（重複蓄積が起きる）

| ケース | 例 |
|---|---|
| SD カード再マウント | `/Volumes/SD_CARD/001.jpg` → `/Volumes/SD_CARD 1/001.jpg` |
| シンボリックリンク経由 | `/Users/user/Photos/001.jpg` と `/Volumes/Storage/001.jpg` |
| フォルダ移動後 | 旧パスの行が孤立して TTL まで残る |

`canonicalize()` は再マウント問題を解決できない（別マウントポイントはシンボリックリンクではないため）。本質的な解決には volume UUID + inode ベースのキーが必要（→ `TODO-swiftUI.md` Cache-3 参照）。

---

## キャッシュ制御

### TTL による自動削除（起動時）

`ContentView.task {}` → `BridgeCore.pruneCache(dbPath:maxAgeDays:)` がバックグラウンドで実行される。

```sql
DELETE FROM thumbnails WHERE COALESCE(cached_at, 0) < {cutoff};
DELETE FROM phashes    WHERE COALESCE(cached_at, 0) < {cutoff};
VACUUM;
```

`cutoff = now - (maxAgeDays × 86400)`

**設定**: General タブ「キャッシュ保持期間」Picker（30 / 60 / 90 / 180 / 365日、デフォルト 90日）

### 手動削除

| 対象 | 場所 | 動作 |
|---|---|---|
| 全キャッシュ | General タブ「Clear Cache」 | `cache.db` ファイルを削除 |
| RAW 現像キャッシュのみ | General タブ「Clear Render Cache」 | `rendered_thumbnails` テーブルを DELETE |
| メモリキャッシュ | 自動（OS 管理） | NSCache が適宜エビクション |

---

## アプリ終了後の挙動

| キャッシュ | アプリ終了後 |
|---|---|
| SQLite | 残る（TTL まで保持） |
| ThumbnailDecodeCache (NSCache) | 消える（メモリは解放） |

Activity Monitor に表示されるメモリ使用量に影響するのは **NSCache のみ**。SQLite はディスク容量に影響する。

---

## 将来課題

`TODO-swiftUI.md` の「Post-Migration: キャッシュ改善」セクション参照。

- **Cache-1**: `fetch_thumb` ヒット時の `cached_at` 更新（より正確な LRU）
- **Cache-2**: SQLite キャッシュのサイズ上限（TTL に加えて）
- **Cache-3**: ボリューム UUID + inode ベースのキャッシュキー（SD カード再マウント対策）
