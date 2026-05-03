# グルーピングアルゴリズム（Tier 1〜4）

> 実装: `crates/bridge-core/src/pairing.rs`, `crates/bridge-core/src/scanner.rs`
> テスト: `crates/bridge-core/src/pairing.rs` の `#[cfg(test)]`

---

## アルゴリズム概要

`reindex_shot_groups()` が EXIF・pHash インデックス完了後に呼び出され、shot グループを確定する。

| Tier | 条件 | 動作 |
|---|---|---|
| 1 | 同 `normalize_stem` ∧ EXIF datetime スパン ≤ 2s | 同グループ |
| 2 | 同 `normalize_stem` ∧ EXIF datetime スパン > 2s | タイムスタンプで時系列クラスタに分割 |
| 3 | `normalize_stem` が異なる | 常に別グループ（pHash は使用しない） |
| 4 | 全メンバーが EXIF datetime なし（IAD）∧ confirmed グループと pHash 類似 | IAD を confirmed に吸収 |

**Tier 4 の目的**: 現像ソフト（DxO PureRAW・Lightroom 等）が EXIF を削除した画像を元 RAW グループに紐付ける。例: `portrait_edit.jpg`（EXIF なし）が `DSC02086.ARW`（EXIF あり）と pHash が近ければ同グループにする。

---

## IAD グループの定義

`is_iad_group()`: グループの**全メンバー**が EXIF datetime を持たない状態。  
1 枚でも EXIF datetime があれば **confirmed** グループ。

IAD→IAD マージは行わない。IAD→confirmed のみ。

---

## Tier 4 の制約: カメラ DCF 命名パターンによるスキップ

### 問題（2026-04-28 発見）

`DSC02086.ARW` + `DSC02086.JPG` + `DSC02087.JPG` が 1 グループになるバグ。

- `DSC02086.JPG` と `DSC02087.JPG` は EXIF datetime を持たないテストファイル
- `DSC02086.ARW` は EXIF datetime あり → DSC02086 グループは confirmed
- `DSC02087.JPG` は全員 EXIF なし → IAD グループ
- Tier 4: `DSC02087.JPG`（IAD）が `DSC02086` グループ（confirmed）と pHash が近い → 誤吸収

### 解決策（2026-05-03 実装）

IAD グループと confirmed グループの**両方**が DCF 命名規則に一致する場合、Tier 4 マージをスキップする。

```rust
// scanner.rs
pub fn is_camera_generated_stem(stem: &str) -> bool
```

**DCF パターン**: `(任意の _)` + 英字のみのプレフィックス + 4〜7 桁の連続数字、全体 5〜9 文字。

```
DSC02087（IAD）+ DSC02086（confirmed）→ 両方 DCF → スキップ → 別グループ ✅
portrait_edit（IAD）+ DSC02086（confirmed）→ IAD 側が非 DCF → Tier 4 発火 ✅
```

---

## 主要メーカーの DCF 命名パターン

| メーカー | sRGB | Adobe RGB | RAW 拡張子 |
|---|---|---|---|
| Sony | `DSC02087` | `_DSC0001` | `.ARW` |
| Canon | `IMG_0001` | `_MG_0001` | `.CR2` / `.CR3` |
| Nikon | `DSC_0001` | `_DSC0001` | `.NEF` |
| Fujifilm | `DSCF0001` | `_DSF0001` | `.RAF` |
| Olympus / OM System | `PB040001`（P + 月 + 日 + 連番） | `_B040001` | `.ORF` |
| Panasonic | `P1000001`（P + フォルダ番号 + 連番） | — | `.RW2` |
| Ricoh / Pentax | `IMGP0001` | — | `.PEF` / `.DNG` |
| Leica | `L1000001` | — | `.DNG` |

DCF 標準（JEITA CP-3461）: 8 文字（英数字 4 文字プレフィックス + 4 桁数字）。  
Sony は例外的に `DSC` + 5 桁（合計 8 文字）。  
Olympus / Panasonic は日付やフォルダ番号をエンコードするため英数字混在になるが、全体は 8 文字。

---

## 定数・閾値

| 定数 | 値 | 用途 |
|---|---|---|
| `DEFAULT_SPLIT_THRESHOLD_SECS` | 2 | Tier 2: 同ステムグループを分割する EXIF datetime スパン閾値 |
| `DEFAULT_PHASH_HAMMING_THRESHOLD` | 15 | Tier 4: IAD rescue の pHash ハミング距離閾値 |
