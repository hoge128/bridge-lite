# サムネイルキャッシュ上限と IOSurface 枯渇は無関係（旧コメント撤回）

調査日: 2026-06-06

## 結論（TL;DR）

- `thumbnailCacheMB`（設定画面のスライダー＝`NSCache.totalCostLimit`）を上げても、
  かつて 50 枚止まりを起こした **IOSurface プール枯渇は再発しない**。
- 上限を上げて増えるのは **常駐 RAM だけ**。IOSurface の保持数とは独立。
- よって旧コメント「**300MB だと IOSurface プールが逼迫する**」は **現状のコードでは根拠を失っており撤回**。
- デフォルトを **150MB → 512MB** に引き上げた（低 RAM 機向けに `physicalMemory/10` でクランプ）。
- 実機の裏付け: ユーザーが Mac Studio で **3GB に設定しても 50 枚止まりが再発しない**ことを確認済み。

## 背景: 50 枚止まり（IOSurface 枯渇）の本当の原因

詳細は `knowledge/scan-stop-bug-investigation.md`。要点は、停止の原因が
「キャッシュに溜め込んだ画像のサイズ」ではなく、
**デコード／RAW 現像が瞬間的に確保する IOSurface の枚数**だったこと。

当時の連鎖:

```
CANON(CR2) フォルダを開く
  → autoRenderRawSidebar = true で CIRAWFilter が自動起動（macOS 15 は CR2 を実処理）
  → RAWRenderPipeline 内の Task.detached が actor 直列性を破り CIRAWFilter が並列暴走
  → 大量の IOSurface を確保
  → 同時にサムネイル生成も CreateThumbnailFromImageAlways で IOSurface を使用
  → 約 50 枚で IOSurface プール枯渇（IOSurface creation failed: e00002c2）→ スキャン停止
```

## なぜ今はキャッシュサイズと無関係なのか（コード根拠）

### 1. NSCache に入る CGImage は IOSurface backed ではない

- スキャン中に格納する経路（`ThumbnailPipeline.swift` の `loadAll` → `store`）は
  `scaledToFit` が生成した CGImage を入れる。これは
  `CGContext(data: nil, …)` + `ctx.makeImage()` による **ヒープ上のビットマップ実体**で、
  IOSurface ではない（`ThumbnailPipeline.swift` `scaledToFit`）。
- スクロール時のキャッシュミス・デコード経路 `CGImage.fromJPEGData` は
  **`kCGImageSourceShouldCache: false`** を明示し、
  「IOSurface バックのデコード済みピクセルを抱え込ませない」(`ThumbnailPipeline.swift` `fromJPEGData`)。

→ 上限 150 / 512 / 900 / 3000 MB と上げても、増えるのは通常 RAM であって
  IOSurface の保持数ではない。これが旧コメントの前提が崩れた最大のポイント。

### 2. IOSurface を実際に確保する瞬間的な並列度はキャッシュサイズと独立に上限済み

| 経路 | 制限 | 場所 |
|---|---|---|
| サムネイル生成 | `ConcurrencyLimiter(maxConcurrent: 2)`（Burst で 4）| `ThumbnailPipeline.swift` |
| RAW 現像（CIRAWFilter）| `ConcurrencyLimiter(maxConcurrent: 1)` | `RAWRenderPipeline.swift` |

### 3. 50 枚止まりの 2 大根本原因はどちらも修正済み

- **修正A**: `autoRenderRawSidebar` / `Compare` を移行コードで強制 OFF
  （`SettingsStore.swift` の `autoRenderRawSidebarMigrated_v1`）。
- **修正B**: `RAWRenderPipeline` を `maxConcurrent: 1` で直列化し CIRAWFilter の並列暴走を封じた。

## キャッシュ上限を上げて実際に変わること（唯一のトレードオフ）

IOSurface ではなく **常駐 RAM**。

- NSCache の cost は `bytesPerRow * height`。512MB なら ~256px サムネイルで概ね 2,000 枚弱、
  900MB で ~3,500 枚、3GB でその約 3.3 倍のビットマップを保持。
- RAM が増えてもメモリ圧迫時は `DispatchSourceMemoryPressure` が
  **warning で半減・critical で全消去**して自動回収する（`ThumbnailDecodeCache.swift`）。
- 影響するのは設計目標「アイドル時メモリ < 100MB」との兼ね合いのみで、スキャン停止には繋がらない。

## 適用した変更（2026-06-06）

- `ThumbnailDecodeCache.swift` init: デフォルト 150 → 512MB、`maxMB` クランプ追加、コメント刷新。
- `SettingsStore.swift` `thumbnailCacheMB`: デフォルト 150 → 512MB、`maxMB` クランプ、コメント刷新。
- 両者は起動時に独立して既定値を算出するため、必ず同じ値・同じロジックに保つこと
  （SettingsStore の didSet は init では発火せず、起動時の実上限は ThumbnailDecodeCache 側が決める）。

## 完全な実機確認をしたい場合

「上限を 512MB（または 900MB）のまま **macOS 15 + CANON(CR2) フォルダ**を開き、
50 枚を越えてスキャン完走するか」を見るのが当時の発症条件に対する確実なテスト。
3GB で再現しなければ、より小さい 512/900MB はさらに安全側。
