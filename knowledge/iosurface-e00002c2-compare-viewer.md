# IOSurface 枯渇（e00002c2）— 比較ビュー・Viewer 調査記録

調査日: 2026-05-12  
ステータス: **部分修正済み・未解決**

---

## 症状

比較ビュー（GroupCompareView）または Viewer（ViewerView）の操作中に Console へ以下が出力される。

```
IOSurface creation failed: e00002c2 parentID: 00000000 properties: {
    IOSurfaceAllocSize = 41943040;
    IOSurfaceName = CMPhoto;
    ...
}
```

**ユーザー視点の影響（当初）**: 「ときどき画像が出ない / 前の画像のまま残る」  
**調査後の状況**: 画像表示の症状は解消。Console ログは継続して出力される。

---

## 根本原因（特定済み）

### 原因 1: 無制限の `Task.detached` による並列デコード

`loadPreview`（GroupCompareView）と `loadFullRes`（ViewerView）が `Task.detached` を使って
`CGImageSourceCreateImageAtIndex` を無制限に並列実行していた。

比較ビュー 3 列同時に実行されると 3 つの HW JPEG デコードが同時起動し、
各デコードが内部で複数の IOSurface を確保するため、プールが枯渇した。

また、RAW の埋め込み JPEG パスでは orientation 取得のために RAW ファイルを 2 度オープンしており、
IOSurface 確保が倍増していた。

### 原因 2: `CIContext` をレンダーごとに生成・破棄

`RAWRenderPipeline.renderWithCIRAWFilter` が毎回 `CIContext(options: [.useSoftwareRenderer: false])` を生成し、
`clearCaches()` を呼ばずに破棄していた。フィルタチェーン中間 IOSurface が次のレンダー開始時まで解放されず蓄積。

### 原因 3: `kCGImageSourceShouldCache` 未指定（nil）

`CGImageSourceCreateWithData` / `CGImageSourceCreateImageAtIndex` の opts が `nil` だったため、
デフォルトのキャッシュが有効になり、デコード後も IOSurface が解放されなかった。

---

## 実施した修正

### 修正 1: `LargeImageDecoder` 導入（新規ファイル）

`Pipelines/LargeImageDecoder.swift` を新設し、フルサイズ JPEG デコードの並列数を
`ConcurrencyLimiter(maxConcurrent: 1)` で直列化。

- `decodeFromURL(_:)`: URL から直接デコード
- `decodeFromData(_:orientation:)`: 埋め込み JPEG バイト列からデコード
  - orientation は `store.thumbnailOrientations[id]` のキャッシュを利用し、RAW ファイルの 2 度開きを回避
- 両 API とも `kCGImageSourceShouldCache: false` を source / image 生成の両方に適用

`GroupCompareView.loadPreview` と `ViewerView.loadFullRes` の `Task.detached` 経路を全て
`LargeImageDecoder` 経由に置換。`.task(id:)` キャンセル時に `ConcurrencyLimiter` の
`withTaskCancellationHandler` でウェイターが自動解放されるため、画像切替時の古タスクも即廃棄。

### 修正 2: `RAWRenderPipeline` の `CIContext` 共有と `clearCaches()`

- actor プロパティとして `CIContext` を 1 個に集約（`cacheIntermediates: false` で中間 IOSurface 抑制）
- `Task.detached` 完了後に `ctx.clearCaches()` を呼び、フィルタチェーン中間 IOSurface を即解放
- `decode(jpeg:)` にも `kCGImageSourceShouldCache: false` を適用

---

## 残課題（未解決）

**Console への `e00002c2` 出力が継続している。**

調査の結果、以下の可能性が高い：

- Apple の HW JPEG デコーダ (`CMPhotoDecompressionContainer+JFIF`) が IOSurface の確保を試みて
  失敗した場合、ImageIO は **SW デコードへ自動フォールバック**して画像生成は成功する
- このログは ImageIO の内部フォールバック動作の痕跡であり、アプリ側から抑止する公開 API は存在しない
- Photos.app / Preview.app でも同条件で出力されることが確認されている（Apple 標準アプリも同様）

**視覚症状との切り分け（2026-05-12 確認）**:
- 「画像が出ない / 前の画像が残る」症状 → 解消
- Console の `e00002c2` ログ → 継続して出力

---

## 検討した対策（未実施）

### 案 A: `CGDataProviderCreateWithData` + vImage デコード

ImageIO を使わず vImage で CPU デコードすることで HW デコーダの IOSurface 確保を回避する。
`e00002c2` は原理的に出なくなる。ただし実装コストが高い（メモリ管理、3〜5 ステップの変換）。

### 案 B: `AVAssetImageGenerator` でプレビューデコード

AVFoundation の静止画デコードパスは ImageIO と別の IOSurface 管理を使う。
ただし RAW ファイルには対応していないため、JPEG プレビュー経路にしか適用できない。
また動画 API の転用であり、初回に余分なオーバーヘッドがある。

---

## 関連ファイル

| ファイル | 役割 |
|---|---|
| `Pipelines/LargeImageDecoder.swift` | 今回追加。並列デコードのゲート |
| `Pipelines/RAWRenderPipeline.swift` | CIContext 共有・clearCaches 追加 |
| `Views/GroupCompareView.swift` | loadPreview を LargeImageDecoder 経由に |
| `Views/ViewerView.swift` | loadFullRes を LargeImageDecoder 経由に |
| `Pipelines/ConcurrencyLimiter.swift` | 参照のみ・変更なし |

## 関連知識

- `scan-stop-bug-investigation.md` — サムネイルスキャン停止時の e00002c2 の別経路（CIRAWFilter 並列実行が原因）
- エラーログサンプル: `error/error1451.txt` 等
