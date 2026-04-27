# グルーピング & Tier アルゴリズム設計書

## 目的

bridge-lite は **RAW + JPG 同時撮影** のセレクト作業を想定している。  
同一シャッターから生まれた複数ファイル (SOOC JPG / RAW / 現像済 JPG / DxO DNG 等) を
**1 枚の「ショット」** として認識し、グリッドに代表 1 枚だけを表示する。  
バリエーション strip でファイルを横並びに切り替えて比較できるようにする。

---

## グルーピング全体フロー

```
┌───────────────────────────────────────────────────────────────┐
│ openDirectory()                                                │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Stage 0  スキャン                                             │
│  scanner.rs::scan_directory                                   │
│                                                               │
│  各ファイルのステムを正規化 → shot_id (u64) を付与              │
│  DSE06384.ARW                   ┐                             │
│  DSE06384.JPG                   ├─ normalize_stem             │
│  DSE06384-DxO_DeepPRIME XD2s.dng┘  → "dse06384"              │
│                                     → compute_shot_id()       │
│                                     → 同一 shot_id ✓          │
│                                                               │
│  ファイルを mtime DESC でソート後に連番 id を付与               │
└────────────────────────┬──────────────────────────────────────┘
                         │ PhotoEntry[] を Swift 側に渡す
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Stage 1  初期取り込み                                          │
│  LibraryStore.ingest()                                        │
│                                                               │
│  shot_id → [member ids] の初期グループを構築                    │
│  (スキャン順 = mtime DESC で各グループに積まれる)               │
└──────┬───────────────────────────────┬──────────────────────┘
       │ EXIF バッチ (並行)              │ サムネイル → pHash チェーン
       ▼                               ▼
┌──────────────────┐          ┌────────────────────────────────┐
│ fetchExif (全件) │          │ ThumbnailPipeline.loadAll      │
│ readXmp  (全件) │          │   ↓ サムネ完了後                 │
└──────┬───────────┘          │ PHashPipeline.enqueue (全件)   │
       │ 完了                  │   ↓ pHash 全件完了後            │
       └──────────────────────┘                                │
              ↓ EXIF完了 && pHash完了 で1回だけ                  │
              └──────────────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Stage 2〜6  reindex_shot_groups                               │
│  pairing.rs — 全件 EXIF + pHash が揃った後に 1 回だけ実行       │
└───────────────────────────────────────────────────────────────┘
```

---

## reindex_shot_groups 詳細 (4 フェーズ)

```
入力: images[] (全ファイル) + exif_by_id + phash_by_id
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Phase 1 — stem ベースの seed group を読み込む                  │
│                                                               │
│  images[].shot_id を キーにして                                │
│  groups: HashMap<u64, Vec<usize>> を構築                       │
│                                                               │
│  ※ この時点では scanner.rs が計算した「ステム正規化 shot_id」    │
│    が基準。異なる stem の同一シャッターはまだ別グループ。         │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Phase 2 — 時間スパンによる分割 (split)                          │
│  定数: SPLIT_THRESHOLD_SECS = 10                               │
│                                                               │
│  同 stem グループ内で最古〜最新の datetime 差 > 10 秒 ?         │
│                                                               │
│       YES → 時系列クラスターに分割                              │
│              EXIF datetime 無しのメンバーは最古クラスターに合流  │
│              新 cluster id = hash(base_id, min_timestamp)     │
│                                                               │
│       NO  → そのまま維持                                        │
│                                                               │
│  [目的] 連番リセットされたファイル名 (例: img_0001 の衝突) を救済 │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Phase 3 — (datetime, subsec) 完全一致によるマージ              │
│                                                               │
│  全グループを走査し                                             │
│  (datetime, subsec) が同一のグループを union-find で統合         │
│                                                               │
│  ⚠️ subsec が無いファイルはマージ対象外                          │
│     → 1 秒以内の連写で誤統合しないためのガード                   │
│                                                               │
│  [目的] ステム正規化漏れ (未知ソフト名など) をリカバリ           │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Phase 4 — pHash 類似度によるマージ                             │
│  定数: PHASH_HAMMING_THRESHOLD = 2                             │
│        PHASH_DATETIME_WINDOW_SECS = 2                          │
│                                                               │
│  全グループの代表 pHash = bit ごとの多数決 (majority vote)       │
│  全ペア (i, j) を比較:                                          │
│                                                               │
│  hamming(pHash_i, pHash_j) ≤ 2                                │
│      AND                                                      │
│  |earliest_datetime_i − earliest_datetime_j| ≤ 2 秒           │
│      → 統合 (小さい shot_id を canonical root に)              │
│                                                               │
│  ⚠️ Phase 4 は merge のみ。split しない。                       │
│  ⚠️ datetime が両グループに無ければ対象外。                      │
│                                                               │
│  [目的] Phase 3 でも拾えなかった同一ファイルのコピー・リネームを  │
│         画像類似度で救済 (subsec 無しカメラ向け)                 │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Phase 5 — グループ内ソート (sort_groups)                        │
│                                                               │
│  各グループのメンバーを以下のキーで昇順ソート:                    │
│  1. filesystem mtime  ← ⚠️ 現状の実装                          │
│  2. is_raw (false=0 < true=1) → 非 RAW 先                     │
│  3. filename lowercase 昇順                                    │
│                                                               │
│  ※ 期待する「SOOC → RAW → 現像」順にするには                     │
│    キー 1 を「EXIF datetime + developed_flag」にする必要がある   │
│    (現状バグ候補 → 要検討)                                       │
└────────────────────────┬──────────────────────────────────────┘
                         │
                         ▼
┌───────────────────────────────────────────────────────────────┐
│  Stage 6 — Swift 側に適用                                      │
│  LibraryStore.applyReindexedGroups()                          │
│                                                               │
│  entries[*].shotId を更新 + shotGroups を差し替え               │
└───────────────────────────────────────────────────────────────┘
```

---

## ステム正規化 (normalize_stem) 詳細

```
入力: ファイルステム (例: "DSE06384-DxO_DeepPRIME XD2s")
  │
  ├─ lowercase → "dse06384-dxo_deepprime xd2s"
  │
  └─ loop: strip_one_suffix() が true を返す間繰り返す
       │
       ├─ " (N)" パターン → Finder コピー除去
       │    例: "IMG (2)" → "IMG"
       │
       ├─ 完全一致サフィックス
       │    -copy / _copy / -enhanced / -edit / _edit
       │
       ├─ 数字付きサフィックス
       │    -v2 / _v3 / -edit2 / _edit3  など
       │
       └─ ソフトウェアマーカー (find して以降を truncate)
            -dxo / _dxo
            -pureraw / _pureraw
            -lightroom / _lightroom
            -captureone / -capture_one / _captureone
            -photolab / _photolab
            -topaz / _topaz
            -on1 / _on1
            -luminar / _luminar
            -affinity / _affinity
            -silkypix / _silkypix
            -denoise / _denoise
            -gigapixel / _gigapixel
            -sharpen / _sharpen
            -processed / _processed

  結果 ≥ 3 文字 → 正規化ステムを返す
  結果 < 3 文字 → 元の lowercase を返す (衝突防止)

例:
  "DSE06384"                     → "dse06384"
  "DSE06384-DxO_DeepPRIME XD2s" → "dse06384"  (同じ shot_id)
  "DSE06384-DxO_DeepPRIME XD2s.jpg" (retouch/) → "dse06384"  (同じ)
  "DSC_0001"                     → "dsc_0001"
  "DSC_0002"                     → "dsc_0002"  (別 shot_id)
```

---

## Tier アルゴリズム (代表選択)

グリッドには shot group あたり 1 ファイルだけを代表として表示する。  
`LibraryStore.computeRepresentatives()` が `visibleIDs` アクセスのたびに動的に計算する。

```
入力: groups (shot_id → [memberIds]) + entries + exifData + xmpData

各 group に対して:
  │
  ├─ Tier 1 — 現像済 非 RAW
  │
  │   groupMinDate = グループ全メンバーの createdDate の最小値
  │
  │   members をフィルタ (!entry.isRaw が前提):
  │
  │   [1-a] ファイル名サフィックス (同期・即時)
  │          entry.hasDevelopedSuffix == true
  │          stem に "-dxo" / "-lightroom" 等が含まれる
  │
  │   [1-b] XMP developed フラグ (非同期ロード後)
  │          xmpData[id]?.developed == true
  │          DxO 名前空間 / crs:RawFileName / Lightroom 編集履歴 等で判定
  │
  │   [1-c] EXIF Software キーワード (非同期ロード後)
  │          exifData[id]?.software に developedKeywords が含まれる
  │
  │   [1-d] birthtime 相対差 (同期・即時)
  │          entry.createdDate − groupMinDate > 60 秒
  │          同一カードから一括コピーされたファイル群は数秒以内に収まる
  │
  │   いずれか true → devs に追加
  │   devs 非空 → .first (createdDate 新しい順) を代表に採用 → NEXT GROUP
  │
  ├─ Tier 2 — 非 RAW (SOOC JPG / HEIC 等)
  │   members をフィルタ: entries[id]?.isRaw == false
  │   ヒット → .first を代表に採用 → NEXT GROUP
  │
  └─ Tier 3 — fallback
      members[0] (sort 済み先頭) を代表に採用

developedKeywords (BridgeCoreConstants / developed.rs):
  "lightroom" / "capture one" / "captureone" / "dxo" / "pureraw" /
  "photoshop" / "camera raw" / "luminar" / "on1" / "affinity" /
  "topaz" / "silkypix" / "darktable" / "rawtherapee" /
  "rawpower" / "picktorial" / "iridient" / "exposure x"

softwareFilenameMarkers (BridgeCoreConstants / scanner.rs SOFTWARE_MARKERS):
  "-dxo" / "_dxo" / "-pureraw" / "_pureraw" /
  "-lightroom" / "_lightroom" / "-captureone" / "_captureone" /
  "-photolab" / "_photolab" / "-topaz" / "_topaz" /
  "-on1" / "_on1" / "-luminar" / "_luminar" /
  "-affinity" / "_affinity" / "-silkypix" / "_silkypix" /
  "-denoise" / "_denoise" / "-gigapixel" / "_gigapixel" /
  "-sharpen" / "_sharpen" / "-processed" / "_processed"
```

### Tier 1 各シグナルの特性比較

| シグナル | 信頼性 | 速度 | 備考 |
|---------|--------|------|------|
| [1-a] ファイル名サフィックス | ★★★☆☆ | 同期 | 命名規則依存。リネームで無効化 |
| [1-b] XMP developed フラグ | ★★★★☆ | 非同期 | DxO 名前空間等で包括的に判定 |
| [1-c] EXIF Software キーワード | ★★★★★ | 非同期 | ソフトが書くため最権威 |
| [1-d] birthtime 相対差 > 60s | ★★★★☆ | 同期 | rsync --preserve-times や逆転コピーで無効化 |

[1-a] と [1-d] は EXIF/XMP ロード前でも即時発火するため、初回描画での誤選択を防ぐ。  
[1-c] と [1-b] が最終的な権威ある判定となる。  
複数グループが devs に入る場合は createdDate が最も新しいファイルを採用する（最新の現像版が優先）。

### Tier 適用例 (DSE06384 グループ)

```
グループメンバー (sort 後の順):
  [0] DSE06384.ARW        isRaw=true   software=nil
  [1] DSE06384.JPG        isRaw=false  software="ILCE-7RM5 v4.00"  ← SOOC
  [2] DSE06384-DxO…dng   isRaw=true   software="DxO PureRAW 4.6"
  [3] DSE06384-DxO….jpg  isRaw=false  software="DxO PureRAW 4.6"  ← 現像済

Tier 1: !isRaw && software contains "dxo"
  → [3] DSE06384-DxO….jpg ✓  → 代表採用

グリッドには DSE06384-DxO….jpg が表示される
バリエーション strip には [0][1][2][3] が横並び
```

---

## バリエーション strip のバッジ

```swift
// SidebarView.swift — VariationThumbView

let badge = entry.isRaw ? "R" : (isDev ? "DEV" : "J")
// 配色: RAW=orange / DEV=green / J=ultraThinMaterial
```

| ファイル | isRaw | isDev | バッジ | 色 |
|---|---|---|---|---|
| DSE06384.JPG | false | false | J | ultraThinMaterial |
| DSE06384.ARW | true | — | R | orange |
| DSE06384-DxO…dng | true | — | R | orange |
| DSE06384-DxO….jpg | false | true | DEV | green |

---

## 定数の根拠

### Phase 2: `SPLIT_THRESHOLD_SECS = 10`

同一ショットの RAW + JPG はカメラ内部で同時生成されるため EXIF datetime は完全一致する。  
ファイル名が衝突している「別の日のカット」を分割するための閾値で、10 秒は下記を満たす最小値として選定：

- RAW + JPG ペアの datetime 差: 常に 0 秒
- 1 秒以内の高速連写 (20 fps): 差は最大 1 秒未満
- 秒針が変わる瞬間に連写: 最大 1 秒
- 別セッションで偶然ファイル名が重複: 通常は数時間〜数日の差

**10 秒にした理由:** 同一ショット対 (差 = 0) と誤名衝突 (差 ≥ 数時間) の間に十分な余裕がある。カメラの時刻ズレ・タイムゾーン設定ミスを考慮しても 10 秒を超えるケースは誤設定でしか起きない。

---

### Phase 3: subsec 必須条件

同一秒内に連写した別ショットが (datetime 完全一致) で誤マージされないよう、  
`SubSecTimeOriginal` が存在する場合のみマージ対象とする。

- `subsec` あり: (datetime, subsec) の完全一致 → 事実上ゼロコリジョン
- `subsec` なし: 連写誤マージリスクがあるためマージしない (under-merge を許容)

---

### Phase 4: `PHASH_HAMMING_THRESHOLD = 2`

**目的:** Phase 3 で拾えなかった「同一ファイルのコピー・リネーム」を救済する。  
例: `DSE0001.jpg` → `本番.jpg` のようにファイル名が変わった同一 JPEG。

**なぜ 2 か:**

| ケース | pHash ハミング距離 | 説明 |
|--------|-------------------|------|
| 同一ファイルのコピー/リネーム | **0** | ビット完全一致 |
| 軽微な再圧縮 (同一画像を JPEG 再保存) | **1〜2** | 量子化誤差のみ |
| 連続撮影の類似シーン | **4〜20** | カメラ移動・被写体動き・露出ムラが必ず出る |
| 別シーン | **20 以上** | 明確に遠い |

閾値 8 (変更前) では連続撮影の類似ショット (例: DSE06419/DSE06420) が誤マージされた。  
閾値 2 で「真の複製」のみを拾い、連続撮影の別ショットは分離できる。

**Phase 3 との関係:**
- `subsec` ありカメラ → Phase 3 がリネームケースを補足済み。Phase 4 は不要だが害もない。
- `subsec` なしカメラ → Phase 4 (閾値 2) が唯一のリネーム救済手段。

---

### Phase 4: `PHASH_DATETIME_WINDOW_SECS = 2`

pHash が近くても datetime が離れていれば「別のシーンで偶然似た構図」の可能性が高い。  
同一ショットの RAW + JPG は datetime 差 = 0 のため、2 秒は十分な余裕。

---

### Tier 1-d: `birthtime 相対差 > 60 秒`

同一カードから Finder / `cp` でコピーされたファイル群は、macOS APFS が birthtime を  
コピー実行時刻に設定するため、数秒以内に揃う。  
現像ソフト (DxO / Lightroom) が後日出力したファイルは明確に birthtime が遅れる。

- 同一コピーセッション内の誤差: 通常 < 5 秒
- 60 秒を閾値にすることで誤検知リスクをゼロに近づける

**無効化されるケース (フォールバックが必要な理由):**
- `rsync --preserve-times` や `cp -p`: birthtime はコピー時刻になるが mtime は保持される（birthtime 差はゼロになる）
- 原本を後日コピー: 現像済みファイルより birthtime が新しくなり逆転する

いずれのケースでも [1-a] ファイル名サフィックス / [1-b] XMP / [1-c] EXIF Software が補完する。

---

## 現在の既知バグ / 設計上の懸念点

| # | 箇所 | 内容 | 影響 |
|---|---|---|---|
| B2 | `sort_groups` (pairing.rs) | filesystem createdDate を主キーにしているため、原本を後日コピーすると createdDate が逆転し **現像 → SOOC → RAW** の逆順になる | バリエーション strip の並び順が期待と逆 |
| B3 | `computeRepresentatives` (LibraryStore) | `visibleIDs` アクセスのたびに再計算。EXIF/XMP ロード完了前は [1-a][1-d] のみで判定されるため、ロード後に代表が切り替わることがある | グリッドが非同期でチラつき更新される |
| 制約 | Phase 3 | subsec が無いカメラでは (datetime) 一致だけではマージされない | 古い RAW や一部スマホで under-merge になる可能性 |
| 制約 | Phase 4 | datetime が無いファイルは pHash マージ対象外 | EXIF 未記録ファイルは stem 一致のみが頼り |
| 制約 | Tier 1-d | rsync --preserve-times や 原本後日コピーで birthtime 差が逆転する | birthtime シグナルが発火しない場合がある (他シグナルで補完) |

---

## データフロー概要図

```
SD カード / HDD
      │
      │ WalkDir (max_depth=10)
      ▼
┌──────────────────────────────────────────────────────┐
│ scanner.rs::scan_directory                           │
│  拡張子フィルタ + normalize_stem + shot_id            │
│  is_raw / has_jpg_partner の判定                      │
│  id = 連番 (mtime DESC ソート後)                      │
└──────────────────────────┬───────────────────────────┘
                           │ ImageEntryList (FFI)
                           ▼
┌──────────────────────────────────────────────────────┐
│ LibraryStore.ingest()                                │
│  entries: [UInt64: PhotoEntry]                       │
│  orderedIDs: [UInt64]   ← mtime DESC 順              │
│  shotGroups: [UInt64: [UInt64]]  ← stem ベース初期    │
└──────┬───────────────────────────┬────────────────────┘
       │ 並行 Task                  │ 並行 Task
       ▼                           ▼
┌─────────────────┐      ┌──────────────────────────────┐
│ fetchExif 全件   │      │ ThumbnailPipeline.loadAll    │
│ readXmp  全件   │      │   ↓                           │
│                 │      │ PHashPipeline.enqueue 全件    │
└─────┬───────────┘      └──────────────┬───────────────┘
      │ noteExifReady                   │ notePhashReady
      └──────────────┬──────────────────┘
                     │ 両方揃ったら 1 回だけ
                     ▼
┌──────────────────────────────────────────────────────┐
│ BridgeCore.reindexShotGroups                         │
│  (bridge_reindex_shot_groups FFI)                    │
│  Phase 1〜5 実行                                      │
│  → [UInt64: [UInt64]] (shot_id → sorted member ids) │
└──────────────────────────┬───────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│ LibraryStore.applyReindexedGroups                    │
│  entries[*].shotId 更新 + shotGroups 差し替え          │
└──────────────────────────┬───────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────┐
│ visibleIDs (computed property, 毎回)                  │
│  computeRepresentatives → 代表 ID セット              │
│  orderedIDs でフィルタ → フィルタ条件適用              │
│  → ThumbnailGridView に表示                           │
└──────────────────────────────────────────────────────┘
```
