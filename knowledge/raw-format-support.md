# RAW フォーマット対応状況

> 実装（クロスプラットフォーム共有）: `crates/bridge-core/src/raw_thumb.rs`
> スキャン拡張子: `crates/bridge-core/src/scanner.rs` `RAW_EXTENSIONS`
> テスト: `crates/bridge-core/tests/integration_rawsamples.rs`
> サンプルファイル: `test/rawsamples/`（raw.pixls.us / rawsamples.ch ほか）
> 最終実測監査: **2026-06-18**（`test/rawsamples/` 全 24 ファイルに `extract()` を実走）
>
> **重要**: プレビュー抽出ロジックは Rust 製の `bridge-core` に集約され、macOS/iOS/**Windows 版で共有**される。
> ここに挙げる対応状況・懸念は全プラットフォーム共通。プラットフォーム差は「Rust が `None` を返したあとの
> フォールバック」だけ（macOS はプロプライエタリ RAW で ImageIO を**使わない**＝Rust が唯一の供給源。
> 詳細は末尾「Windows 版への反映」）。

---

## 対応状況サマリ（全形式マトリクス）

「スキャン」= `scanner.rs RAW_EXTENSIONS` に含まれ一覧に出るか。「プレビュー」= `extract()` が
デコード可能な JPEG を返すか。実測は 2026-06-18 の監査値。

| 拡張子 | メーカー | スキャン | プレビュー抽出 | 実測 / 備考 |
|--------|----------|:------:|:------:|------|
| ARW | Sony | ✅ | ✅ | 〜4608×3072 |
| CR2 | Canon | ✅ | ⚠ | 160×120 のみ（埋込が小サムネだけ） |
| CR3 | Canon | ✅ | ✅ | 1620×1080（ISOBMFF PRVW） |
| NEF | Nikon | ✅ | ✅ | 〜6048×4024。Z6 III も P=1620×1080 / F=3984×2656（2026-06 修正） |
| NRW | Nikon | ✅ | ⚠ | 未検証（TIFF 経路に乗る想定） |
| ORF | Olympus/OM | ✅ | ✅ | 3200×2400（2026-06 マーカー検証で修正） |
| RW2 | Panasonic | ✅ | ✅ | 1920×1440 |
| RWL | Leica | ✅ | ✅ | 1920×1440（V-Lux 4）。**Panasonic RW2 と同一マジック(0x0055)** → RW2 経路で対応（2026-06 追加） |
| RAF | Fujifilm | ✅ | ✅ | 〜4416×2944 |
| PEF | Pentax | ✅ | ✅ | 7360×4912 |
| SRW | Samsung | ✅ | ✅ | 3648×2736 |
| DNG（標準/Leica） | Adobe/Leica ほか | ✅ | ✅ | 〜5952×3968（M10） |
| DNG（Apple ProRAW/iPhone） | Apple | ✅ | ✅ | **2026-06 修正**（BE + Compression=7 主IFD）。iPhone12Pro=4032×3024 / XS=852×640 |
| 3FR | Hasselblad | ✅ | ✅ | 320×240（H3D）。**非圧縮RGB→JPEG エンコードで対応**（2026-06 追加・懸念3） |
| FFF | Hasselblad | ✅ | ✅ | 1288×966（H6D-100c）。同上（RGB→JPEG） |
| IIQ | Phase One | ✅ | ✅ | 296×220〜456×342。同上（RGB→JPEG） |
| MOS | Leaf | ✅ | ❌ | ~330×240 の小 JPEG は有るが生データと混在・非標準位置（懸念4・優先度低） |
| CRW | Canon (旧/CIFF) | ✅ | ❌ | スキャンのみ追加。プレビューは CIFF 未対応（サンプルも非標準で exiftool もエラー） |
| X3F | Sigma (Foveon) | ❌ | ❌ | **非対応**（サンプル未入手で検証不能）。`RAW_EXTENSIONS` から除外 |
| MRW | Minolta | ❌ | ❌ | **非対応**（同上）。`RAW_EXTENSIONS` から除外 |
| SR2 / SRF / ERF / DCR / KDC / MEF / GPR / 汎用 RAW | Sony旧/Epson/Kodak/Mamiya/GoPro ほか | ❌ | ❌ | 拡張子未登録＝スキャンされない（DNG 併用機なら DNG で可） |

凡例: ✅ 動作 / ⚠ 制限あり / ❌ 非対応。

> **依存追加（2026-06）**: 3FR/FFF/IIQ の非圧縮RGBプレビューを JPEG 化するため、純 Rust の
> `jpeg-encoder` クレートを `bridge-core` に追加。プラットフォーム非依存なので Windows でもそのまま動く。

---

## 対応フォーマット一覧（実測 OK・詳細）

実測でデコード可能な JPEG プレビューが取れた形式。「最大解像度」は `Quality::Full` の SOF 実測値。

| 拡張子 | メーカー | 抽出方式 | 最大プレビュー（実測） | 状態 |
|--------|----------|----------|----------|------|
| ARW    | Sony     | TIFF IFD1 + SubIFD | 4608×3072（ILCE-7M5） | ✅ |
| CR2    | Canon    | TIFF IFD1 (kamadak-exif) | **160×120 のみ**（埋込は小サムネのみ） | ⚠ サムネ品質止まり |
| CR3    | Canon    | ISOBMFF uuid PRVW | 1620×1080 | ✅ |
| DNG    | Leica/標準 | TIFF SubIFD (Compression=7) | 5952×3968（M10） | ✅ ※Apple 系は別記 |
| NEF    | Nikon    | TIFF SubIFD (JPEGInterchangeFormat) | 6048×4024 | ✅ |
| ORF    | Olympus/OM | JPEG SOI スキャン（要マーカー検証） | 3200×2400 | ✅（2026-06 修正） |
| PEF    | Pentax   | TIFF IFD (In(2)) | 7360×4912 | ✅ |
| RAF    | Fujifilm | 独自ヘッダ offset/size | 4416×2944 | ✅ |
| RW2    | Panasonic | IFD0 tag 0x002E ブロブ | 1920×1440 | ✅ |
| SRW    | Samsung  | TIFF IFD | 3648×2736（EX1） | ✅ |

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

**2026-06 一般化（NEF / DNG / Apple ProRAW を統一処理）**: `extract_tiff_subifd` は当初 IFD0 の
SubIFD（0x014A）しか見なかったが、以下を全走査する IFD ツリーウォーカに拡張した:
- **主 IFD チェーン**（IFD0 → IFD1 → … を NextIFD で追跡）＋各 IFD の SubIFD
- 各 IFD で `JPEGInterchangeFormat(0x0201/0x0202)` か `Compression=7 + StripOffsets/ByteCounts` を候補化
- **endian 安全**: SHORT タグは型を見て `u16` で読む（BE の Apple DNG 対策、`tag_scalar`）
- **生データ除外**: `Compression=7` 候補は `PhotometricInterpretation ∈ {RGB, YCbCr}` のみ採用
  （CFA/LinearRaw のロスレス JPEG＝センサー生データを誤検出しない）
- 各候補は SOI 検証してから採用。サイズ順にソートし Quality で選択。

Apple ProRAW / iPhone DNG はプレビューが**主 IFD 側**に `Compression=7` で入るため、この一般化で対応。

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

**⚠ 2026-06 バグと修正（OM-5 MarkII で発覚）**:
`collect_jpegs` は当初 `FF D8 FF` の 3 バイトしか見ておらず、4 バイト目（本来は JPEG マーカー）を
検証していなかった。OM-5 MarkII の ORF は本物プレビューの手前（オフセット 27053）に
`FF D8 FF **2A**` という**偽の SOI 列**を含み、これを JPEG と誤検出。`find_jpeg_eoi` が後方の
偶発 `FF D9` まで歩いて約 1 MB の**非デコード塊**（本物の 160×120 と 3200×2400 を巻き込む）を返し、
ImageIO がデコードできず **ORF だけサムネが出ない**状態になった（`sips` でも `pixelWidth: <nil>`）。

**修正**: SOI 直後の 4 バイト目が正規マーカー（`>= 0xC0`：APPn/DQT/DHT/SOF/COM …）であることを要求。
偽の `…2A`（< 0xC0）を弾く。RW2・CR3 の同関数経由の誤検出にも有効。exiftool の
`PreviewImageStart` と一致を確認済み。

```rust
// collect_jpegs 内
if data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF && data[i + 3] >= 0xC0 {
```

**スキャン結果（実測）:**

| 機種 | オフセット | サイズ / 解像度 | 内容 |
|------|-----------|--------|------|
| E-M5 | – | 8 KB / 160×120 | サムネイル |
| E-M5 | 52224 | 1048 KB / 3200×2400 | プレビュー |
| OM-5 MarkII | 27053 | （偽 `FFD8FF2A`） | 修正後は無視 |
| OM-5 MarkII | 34688 | 7 KB / 160×120 | サムネイル |
| OM-5 MarkII | 52224 | 1008 KB / 3200×2400 | プレビュー |

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

**RWL（Leica）も同じ経路**: Leica の RWL は Panasonic RW2 のリブランドで、マジックも `II + 0x0055` と
同一。`extract()` はマジックで分岐するため、`rwl` を `RAW_EXTENSIONS` に足すだけで `extract_rw2` が
そのまま機能する（V-Lux 4 で 1920×1440 を確認）。

---

### 中判の非圧縮 RGB プレビュー（3FR / FFF / IIQ）

これらは埋込 JPEG を持たず、TIFF IFD に**非圧縮・8bit・インターリーブ RGB**のプレビューだけを持つ
（PI=RGB / Compression=1 / 単一ストリップ）。`extract_tiff_rgb_preview` が IFD ツリーを走査して
最大の RGB 画像を選び、`jpeg-encoder` で JPEG 化して返す。安全策として `strip_len == W×H×3` と
`PlanarConfiguration==1` を検証し、合致しない（16bit/planar 等）ものはスキップ。JPEG 経路が全滅した
ときの**最終フォールバック**として実行するため、本物の埋込 JPEG を上書きしない。

| 機種 | プレビュー実測 |
|------|--------|
| Hasselblad H3D (3FR) | 320×240 |
| Hasselblad H6D-100c (FFF, BE) | 1288×966 |
| Phase One P65+ (IIQ) | 296×220 |
| Phase One IQ140 (.TIF) | 456×342 |

---

## サンプルファイルの場所と出典

`test/rawsamples/` に各社サンプルを配置（raw.pixls.us / rawsamples.ch ほか）。
2026-06 に Apple/Hasselblad/Phase One/Leaf/Samsung/追加 Sony・Nikon・Fujifilm を追加済み。
これらは `.gitignore` に追加してリポジトリには含めない（合計 ~2 GB）。
テスト実行時にファイルが存在しない場合は自動的にスキップされる。

---

## 実測監査結果（2026-06-18・全サンプルに `extract()` 実走）

「最大解像度」は返却 JPEG の SOF を実パースした値。`None` は抽出失敗。

| ファイル | T / P / F 実測 | 判定 |
|---|---|---|
| Sony ILCE-7M5 ARW | 160×120 / 1616×1080 / **4608×3072** | ✅ |
| Sony DSLR-A550 ARW | 160×120 / 1616×1080 | ✅ |
| Nikon Z6 III NEF | 160×120 / 1620×1080 / 3984×2656 | ✅（2026-06 修正・旧 P/F=160×120） |
| Nikon D2Xs NEF | 4288×2848 | ✅ |
| Fujifilm GFX100RF / X-T30 III RAF | 4000×3000 / 4416×2944 | ✅ |
| Canon CR2 / CR3 | 160×120 / 1620×1080 | ✅（CR2 はサムネのみ） |
| Pentax K-1 PEF | 7360×4912 | ✅ |
| Panasonic GH6 RW2 | 1920×1440 | ✅ |
| Olympus E-M5 ORF | 3200×2400 | ✅（修正後） |
| Leica M10 DNG | 160×120 / 1440×960 / 5952×3968 | ✅ |
| Samsung EX1 SRW | 3648×2736 | ✅ |
| **Apple iPhone 12 Pro DNG** | 4032×3024 | ✅ **2026-06 修正**（旧 None） |
| **Apple iPhone XS DNG** | 852×640 | ✅ **2026-06 修正**（旧 None。埋込プレビューが元々小さい） |
| Leica V-Lux 4 RWL | 1920×1440 | ✅ **2026-06 追加**（RW2 経路） |
| **Hasselblad H3D 3FR** | 320×240 | ✅ **2026-06 追加**（RGB→JPEG） |
| **Hasselblad H6D-100c FFF** | 1288×966 | ✅ **2026-06 追加**（RGB→JPEG, BE） |
| **Phase One IQ140 / P65+ IIQ** | 456×342 / 296×220 | ✅ **2026-06 追加**（RGB→JPEG） |
| Leaf AFi-II / Aptus 75 MOS | **None** | ❌ 小 JPEG が生データと混在・非標準位置（懸念4・優先度低） |
| Canon PowerShot CRW | **None** | ❌ スキャンのみ。CIFF 非対応（サンプルも非標準） |

---

## 懸念事項（全プラットフォーム共通）

### 1. ✅【修正済 2026-06】Apple ProRAW / iPhone DNG が表示されない
iPhone の DNG は `PreviewImage`（iPhone 12 Pro = 5.3 MB / XS = 222 KB, `Compression=JPEG`）を持つのに
`extract()` が `None` だった。**真因は 2 つ**:

1. **ビッグエンディアン（MM）の SHORT タグ誤読** — iPhone DNG は `MM`（BE）。`Compression`/`PhotometricInterpretation`
   は SHORT(type 3) で値が 4 バイト値フィールドの**上位 2 バイト**に左詰めされる。これを `u32` で読むと
   `値 << 16` になり（例: Compression 7 → `0x00070000`）、`compression == 7` が成立しなかった。
   → タグ型を見て SHORT は `u16` で読む `tag_scalar` を導入。
2. **プレビューが主 IFD チェーン側にある** — iPhone のプレビューは SubIFD ではなく IFD0/IFD1 側に
   `Compression=7`＋`StripOffsets` で格納。`extract_tiff_subifd` を「主 IFD チェーン（NextIFD 追跡）＋
   各 SubIFD」を全走査する IFD ツリーウォーカに一般化。

加えて **CFA/LinearRaw の生データ（ロスレス JPEG＝FFD8 始まり）を誤って拾わない**よう、`Compression=7`
ストリップ候補は `PhotometricInterpretation ∈ {RGB(2), YCbCr(6)}` のみ採用するゲートを追加
（これが無いと Leica M10 の Full が 14bit 29MB の生データに化ける退行が出た）。
`JPEGInterchangeFormat(0x0201)` 候補は定義上 JPEG なので無条件採用。実測: iPhone 12 Pro=4032×3024 /
XS=852×640、Leica/NEF/ARW 等は不変、`integration_rawsamples` の thumb/preview/full 全通過。

### 2. ✅【修正済 2026-06】Nikon Z6 III NEF で Preview/Full が 160×120 に縮退
新しめの NEF は IFD0 に小さな 160×120 JPEG を持ち、`extract_from_ifd(PRIMARY)` がそれを返して
短絡するため、SubIFD の大プレビューに到達できなかった。**修正**: TIFF 0x002A 経路の Preview/Full は
IFD ツリー全走査（`extract_tiff_subifd`）を**先に**実行し最大サイズを選ぶ（kamadak-exif は fallback）。
ツリーウォークは IFD0/1/2 の JpegInterchangeFormat も内包するため上位互換。実測 P=1620×1080 / F=3984×2656。

### 3. ✅【修正済 2026-06】中判（Hasselblad 3FR/FFF・Phase One IIQ）— 埋込 JPEG が無い
これらは**非圧縮 8bit RGB プレビュー**のみ（PI=RGB・Compression=1・単一ストリップ）で埋込 JPEG が無い。
`extract_tiff_rgb_preview` を追加し、IFD ツリーから最大の RGB 画像を読んで `jpeg-encoder` で JPEG 化。
`strip_len == W×H×3` と `PlanarConfiguration==1` を検証して 16bit/planar を除外、JPEG 経路が全滅した
ときの最終フォールバックとして実行。実測: 3FR=320×240 / FFF=1288×966 / IIQ=296×220〜456×342。
（バイト走査案は CFA 生データのロスレス JPEG を誤検出するため**不採用**。）

### 4. ⚠ Leaf MOS — 小さな JPEG はあるが生データと混在（未対応・優先度低）
MOS（MM 0x002A）は ~330×240 の小 JPEG プレビュー（24〜55 KB）を持つが、標準 IFD タグ位置に無く、
同時に巨大な生データ（ロスレス JPEG 5160×7752 等）も含む。RGB でもないため RGB フォールバックにも
乗らない。安全に小プレビューだけを取る判定が要るが、価値が小さく優先度低。

### 5. ✅【対応方針確定 2026-06】Sigma X3F / Minolta MRW — 非対応化
サンプル未入手でパーサ検証ができないため、`RAW_EXTENSIONS` から **x3f / mrw を除外**（スキャンしない＝
壊れたサムネで一覧に出さない）。サンプルが入手でき次第、拡張子を戻して `extract()` の magic 分岐に
`FOVb`(X3F) / `MRM`(MRW) を追加する。

### 6. ⚠ スキャン拡張子と抽出対応の不一致（縮小したが CRW が残る）
x3f/mrw を除外し 3fr/fff/iiq を対応したため不一致はほぼ解消。残るは **CRW**（スキャンするが CIFF
プレビュー未対応 → 無サムネ）。CRW は legacy かつ提供サンプルが非標準（exiftool もエラー）のため、
当面はプレースホルダ表示で許容。UI 側で「対応形式だがプレビュー無し」を区別すると親切。

### 7. Swift フォールバックの拡張子リストが Rust と不一致
`ScanPipeline.swift` / `FolderWatcher.swift` / `ThumbnailPipeline.swift` の Swift 側リストは
10 種（`arw cr2 cr3 nef nrw rw2 orf pef raf dng`）で、Rust 側（下記）と乖離。macOS は通常 Rust
経路なので実害は出にくいが、フォールバック時に挙動が変わる。一元管理が望ましい（FFI で Rust の
`RAW_EXTENSIONS` を公開して Swift から参照する等）。**RWL/CRW 追加・x3f/mrw 除外も Swift 側へ未反映。**

### 8. 拡張子自体が未登録（＝ファイルが一覧に出ない）
2026-06 に **CRW（Canon 旧）・RWL（Leica）を `RAW_EXTENSIONS` へ追加**。残る未登録は
`SR2`/`SRF`(Sony 旧)・`ERF`(Epson)・`DCR`/`KDC`(Kodak)・`MEF`(Mamiya)・`GPR`(GoPro, 中身は DNG)・
`MDC`(Minolta)・汎用 `RAW`。SR2/ERF はサンプル未入手のため対応保留（ユーザー判断で対応不要）。
※現行 Leica/Ricoh/DJI/Sigma fp/スマホ ProRAW の多くは DNG も吐けるので DNG なら可。

---

## 既知の制限

- **ORF**: MakerNote を解析せず SOI スキャンに依存（先頭 10% にプレビューが無い機種では失敗し得る）。
  4 バイト目マーカー検証は導入済みだが、根本的には MakerNote/IFD 解析が望ましい。
- **RAF**: Thumbnail / Preview の Quality 区別をしていない（常に同じ大 JPEG を返す）。
- **DNG**: 複数 SubIFD の中サイズ選択は `candidates[len/2]` 依存で、機種により意図しないサイズの可能性。

---

## Windows 版への反映

- プレビュー抽出は **`bridge-core`（Rust）に集約**されているため、本ドキュメントの対応状況・修正・懸念は
  **そのまま Windows 版に適用**される。ORF の `collect_jpegs` 修正・上記懸念の修正は 1 箇所直せば全 OS に効く。
- プラットフォーム差は「`extract()` が `None` のときのフォールバック」だけ:
  - **macOS**: プロプライエタリ RAW では ImageIO を**使わない**（`ThumbnailPipeline.generateWithImageIO` が
    `arw/cr2/cr3/nef/nrw/rw2/orf/pef/raf` で `nil` を返す＝macOS 26 のクラッシュ回避）。よって Rust が唯一の
    プレビュー供給源で、Rust が `None` ＝ 無サムネに直結する（今回の ORF 不具合の効き方が大きかった理由）。
  - **Windows**: OS 側 RAW コーデック（WIC / Microsoft Raw Image Extension）に頼れない前提で設計すべき。
    結局 Rust の `extract()` が頼りになるので、上記の修正が Windows でも体感品質を直接左右する。
- 依存追加 `jpeg-encoder`（中判 RGB→JPEG 用）は純 Rust でプラットフォーム非依存＝Windows でもそのまま動く。
- **Swift 側のみ未反映**（懸念7）: RWL/CRW 追加・x3f/mrw 除外は Rust の `RAW_EXTENSIONS` のみ。Swift の
  フォールバック拡張子リスト（および Windows 側に同等のものを作る場合）も合わせること。
- 検証手順（再現可能な監査）: `test/rawsamples/` に各社サンプルを置き、`extract()` を全ファイルに走らせて
  返却 JPEG の SOF（解像度）をパースする監査を回す（本調査でも使用）。OS 非依存で実行できる。
