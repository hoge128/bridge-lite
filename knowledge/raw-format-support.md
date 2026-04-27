# RAW フォーマット対応状況

> 実装: `crates/bridge-core/src/raw_thumb.rs`
> テスト: `crates/bridge-core/tests/integration_rawsamples.rs`
> サンプルファイル: `test/rawsamples/`（raw.pixls.us より取得）

---

## 対応フォーマット一覧

| 拡張子 | メーカー | 代表機種 | 抽出方式 | 状態 |
|--------|----------|----------|----------|------|
| ARW    | Sony     | α7R IV   | TIFF IFD1 (kamadak-exif) | ✅ |
| CR2    | Canon    | EOS 5D III | TIFF IFD1 (kamadak-exif) | ✅ |
| CR3    | Canon    | EOS R5   | ISOBMFF uuid PRVW ボックス | ✅ |
| DNG    | Leica ほか | M10   | TIFF SubIFD (Compression=7) | ✅ |
| NEF    | Nikon    | Z6 II    | TIFF SubIFD (JPEGInterchangeFormat) | ✅ |
| ORF    | Olympus  | E-M5     | JPEG SOI スキャン | ✅ |
| PEF    | Pentax   | K-1      | TIFF IFD1 (kamadak-exif) | ✅ |
| RAF    | Fujifilm | X-T5     | 独自ヘッダの offset/size フィールド | ✅ |
| RW2    | Panasonic | GH6     | IFD0 tag 0x002E ブロブスキャン | ✅ |

---

## エントリポイント

```rust
pub fn extract(path: &Path, quality: Quality) -> Option<Vec<u8>>
```

`Quality` は `Thumbnail`（グリッド用）/ `Preview`（サイドバー用）/ `Full` の 3 段階。
戻り値は JPEG バイト列。失敗時は `None`。

### フォーマット判定順序

1. ヘッダ先頭 16 バイトが `FUJIFILMCCD-RAW ` → RAF
2. オフセット 4〜8 が `ftyp` → ISOBMFF → CR3
3. TIFF バイトオーダーマーク (`II` / `MM`) を確認し、magic バイトで分岐
   - `0x0055` → RW2（Panasonic 独自）
   - `0x4F52` → ORF（Olympus 独自）
   - `0x002A` → 標準 TIFF（kamadak-exif → SubIFD フォールバック）

---

## フォーマット別詳細

### ARW / CR2 / PEF — 標準 TIFF

**magic**: `II + 0x002A`

kamadak-exif ライブラリの `read_from_container` で IFD チェーンを解析。
`JPEGInterchangeFormat` + `JPEGInterchangeFormatLength` を IFD1（Thumbnail）または IFD0（Preview）から取得。

---

### CR3 — Canon ISOBMFF コンテナ

**magic**: `ftyp` ボックス（オフセット 4〜8）

Canon EOS R シリーズから採用された、MP4 と同じ ISOBMFF コンテナ形式。
TIFF パーサは完全に無効なため、ボックスウォーカーを独自実装。

**構造:**
```
[0]  ftyp (24 bytes)
[24] moov (35296 bytes)
     └─ uuid 85c0b687... (Canon metadata)
[35320] uuid be7acfcb... (XPacket XML)
[100880] uuid eaf42b5e... (PRVW preview JPEG) ← ここを抽出
[401288] free
[401392] mdat (raw image data)
```

**PRVW uuid ボックスの内部レイアウト:**
```
[+0 ..  +8]  ボックスサイズ + "uuid"
[+8 .. +24]  UUID = eaf42b5e1c984b88b9fbb7dc406e4d16
[+24 .. +28] version (0x00000000)
[+28 .. +32] flags
[+32 .. +36] データ全体サイズ
[+36 .. +40] 内部識別子 "PRVW" (0x50525657)
[+40 .. +44] 不明
[+44 .. +48] 幅・高さ情報
[+48 .. +52] 幅・高さ情報
[+52 .. +56] JPEG サイズ (big-endian u32) ← ここを読む
[+56 ..]     JPEG データ (SOI = 0xFF 0xD8)
```

JPEG サイズはボックスの末尾に 4 バイトのパディングがあるため、`box_size - 56` では正確なサイズを得られない。ボックス +52 の u32 を使う必要がある。

---

### DNG — Adobe Digital Negative (TIFF ベース)

**magic**: `II + 0x002A`

外見は通常 TIFF と同じだが、プレビュー JPEG は標準の IFD1 ではなく
**SubIFD**（IFD0 tag `0x014A`）に格納されている。

DNG の SubIFD はさらに Nikon NEF と異なり、`JPEGInterchangeFormat` タグを使わず、
`Compression=7`（JPEG）+ `StripOffsets` + `StripByteCounts` の組み合わせで JPEG を指す。

**Leica M10 の SubIFD 構成:**

| SubIFD | 解像度 | サイズ | 用途 |
|--------|--------|--------|------|
| [2]    | 160×120 | 15 KB | サムネイル |
| [1]    | 1440×960 | 476 KB | サイドバープレビュー |
| [0]    | 5952×3968 | 2.4 MB | フルサイズ |

kamadak-exif のフォールバックとして `extract_tiff_subifd` を実装。
SubIFD を全件走査して JPEG サイズ順にソート、Quality に応じて選択。

---

### NEF — Nikon Electronic Format (TIFF ベース)

**magic**: `II + 0x002A`

DNG と同様に SubIFD にプレビューが格納されるが、こちらは標準の
`JPEGInterchangeFormat` + `JPEGInterchangeFormatLength` タグを使用。
IFD0 の NextIFD が 0（IFD1 なし）のため、kamadak-exif では取得不可。

**Nikon Z6 II の SubIFD 構成:**

| SubIFD | サイズ | 用途 |
|--------|--------|------|
| [2]    | 941 KB | サイドバープレビュー |
| [0]    | 2968 KB | フルサイズ |

`extract_tiff_subifd` のフォールバックで対応。

---

### ORF — Olympus RAW Format

**magic**: `II + 0x4F52`（`'OR'` = Olympus 独自）

TIFF と同じ構造だが magic が `0x002A` でないため kamadak-exif が即座に失敗。
IFD0 に `JPEGInterchangeFormat` タグが存在せず、プレビューは MakerNote 経由で管理されているが解析が複雑。

**対応方針**: ファイル先頭 10%（最大 128 KB + ファイルサイズ/10）を JPEG SOI スキャンし、
見つかった JPEG を `collect_jpegs` でサイズ順にソートして返す。

**Olympus E-M5 のスキャン結果:**

| オフセット | サイズ | 内容 |
|-----------|--------|------|
| 19808 | 8 KB | サムネイル |
| 52224 | 1048 KB | プレビュー |

---

### RAF — Fujifilm RAW

**magic**: `FUJIFILMCCD-RAW ` (16 バイト文字列)

TIFF でも ISOBMFF でもない完全独自フォーマット。
ヘッダの固定位置にプレビュー JPEG の offset と size が記録されている。

**ヘッダレイアウト（すべて big-endian）:**
```
[  0.. 16] "FUJIFILMCCD-RAW " 署名
[ 16.. 20] フォーマットバージョン (例: "0201")
[ 20.. 28] カメラ ID
[ 28.. 60] カメラモデル文字列
[ 60.. 84] (各種フィールド)
[ 84.. 88] JPEG プレビュー オフセット (ファイル先頭からのバイト数)
[ 88.. 92] JPEG プレビュー サイズ
[ 92.. 96] CFA (ベイヤーデータ) オフセット
[ 96..100] CFA サイズ
```

X-T5 (バージョン 0201) の場合、JPEG はオフセット 148 に 3.9 MB で格納される。
この JPEG は EXIF APP1 ブロックを含み、その中に小さなサムネイルが埋め込まれているが、
Thumbnail / Preview ともに全体の JPEG を返す（キャッシュ側でスケーリング）。

---

### RW2 — Panasonic RAW

**magic**: `II + 0x0055`（Panasonic 独自）

`0x002A` ではないため kamadak-exif が失敗。
標準の `JPEGInterchangeFormat` タグは存在しない。

**構造:**
IFD0 の tag `0x002E`（Panasonic 独自）が、プレビュー JPEG を含むブロブ全体の
offset と size を指す。ブロブは 1 枚の大きな JPEG（1920×1440 など）で、内部の
EXIF APP1 に小さなサムネイルが埋め込まれている。

ブロブを丸ごと読んで `collect_jpegs` で SOI/EOI ペアを検出。
単純に `0xFF 0xD9` を検索すると EXIF 内サムネイルの EOI を誤検出するため、
JPEG マーカーを正しくウォークして APP1 ブロック全体をスキップする必要がある。

---

## サンプルファイルの場所と出典

```
test/rawsamples/
  RAW_CANON_EOS_5DMARK3.CR2   (rawsamples.ch)
  RAW_CANON_EOS_R5.CR3        (raw.pixls.us)
  RAW_NIKON_Z6II.NEF          (raw.pixls.us)
  RAW_SONY_ILCE7RM4.ARW       (raw.pixls.us)
  RAW_PANASONIC_GH6.RW2       (raw.pixls.us)
  RAW_FUJIFILM_XT5.RAF        (raw.pixls.us)
  RAW_OLYMPUS_EM5.ORF         (raw.pixls.us)
  RAW_PENTAX_K1.PEF           (raw.pixls.us)
  RAW_LEICA_M10.DNG           (raw.pixls.us)
```

これらは `.gitignore` に追加してリポジトリには含めない。
テスト実行時にファイルが存在しない場合は自動的にスキップされる。

---

## 未対応フォーマット

| 拡張子 | メーカー | 備考 |
|--------|----------|------|
| NRW    | Nikon (Coolpix) | NEF と近似。未検証 |
| SRF / SR2 | Sony (旧機種) | ARW 以前の形式 |
| MRW    | Minolta / Konica Minolta | 現在市場からほぼ消滅 |
| X3F    | Sigma (Foveon) | 独自コンテナ |
| IIQ    | Phase One | 中判デジタルバック |
| 3FR    | Hasselblad | 中判デジタルバック |
| RWL    | Leica (旧) | DNG 移行前の形式 |

---

## 既知の制限

- **ORF**: MakerNote を解析せず SOI スキャンに依存しているため、
  ファイル先頭 10% に JPEG が存在しない機種では失敗する可能性がある。
- **RAF**: Thumbnail / Preview の Quality 区別をしていない（常に同じ 3.9 MB JPEG を返す）。
  EXIF 内サムネイルの抽出は未実装。
- **DNG**: SubIFD が複数ある場合の「中サイズ JPEG」は `candidates[len/2]` で選択しており、
  機種によっては意図しないサイズが選ばれる可能性がある。
