# 写真 ID 使い回しによる「別フォルダの写真が開く」バグ

## 症状

複数フォルダを行き来した後、グリッドのサムネイルを単体ビューで開くと、**クリックした写真とは無関係の、1 つ前に開いていたフォルダの写真**が開くことがある。サムネイル自体は正しく見えているのに、開くと別物になる。間欠的で、フォルダを跨ぐほど再現しやすい（macOS 版 v0.5.0 まで再現）。

## 根本原因

写真 ID（`UInt64`）が **スキャナの連番でフォルダを開くたびに 1 から振り直され、フォルダ間で再利用**されていた。

- 単体ビュー（ViewerView）は ID 依存で写真を解決していた: `selectedID (= primaryID) → entries[id] → entry.url`。
- フォルダ切替の非同期処理中に、前フォルダ由来の ID 参照が残ったり、`.task(id: selectedID)` が「ID 番号が変わっていない」（例: 両フォルダの先頭がともに id=1）と判断して再ロードしないことがある。
- ID がフォルダ間で再利用されているため、その取り残し参照が **「同じ ID 番号を持つ別フォルダの実在ファイル」に化けて解決**される。

**重要な洞察**: ID がグローバルに一意なら、取り残し参照は `entries[staleId] == nil` で**安全に失敗（何も表示しない）**するはず。再利用しているせいで「もっともらしい別の写真」が表示されてしまう。これがこのバグを「無害なちらつき」ではなく「誤った写真の表示」にしている。

## macOS の修正（2026-06）

ブランチ `fix/global-unique-photo-ids`（コミット `5716171` 系）。**Rust core（bridge-core）は無変更。すべて Swift 側の path 結合変換。**

1. **ID の一意化**: スキャナ連番を `LibraryStore.ingest()` でセッション内単調増加する `nextEntryID` へ remap し、store ID をグローバル一意化。`shotId` も同マップで付け替え。
2. **`reset()` の `nextEntryID = 1` を撤廃**（フォルダ横断で単調増加を維持）。`nextEntryID` が 1 に戻るのは LibraryStore インスタンス生成時（＝タブ生成時）のみ。
3. **Rust ID 空間で結果を返す境界を path 結合で変換**してから適用:
   - EXIF バッチ（`fetchExifBatch`）→ `remapExifBatchToStoreIDs`
   - グルーピング（`reindexShotGroups`）→ グループ適用を `applyRustReindexedGroups` に一本化（初回スキャン・`regroup()`・PairingPipeline・reconcile の全 4 経路）。メンバーのみ store ID へ変換、グループキー(shotId)は `shotGroups` の照合トークンなので Rust 空間のまま（`entries[shotId]` のような entry 参照には使われないことを確認済み）。
   - 共通ヘルパー `rustToStoreIDMap(list:)`（imageList の Rust ID → path → 現 `entries` の store ID）。
4. **保険**: ViewerView のフル解像度ロードに `scanGeneration` ＋ `selectedID` ガードを追加し、await 中のフォルダ切替で前フォルダ画像が現在表示を上書きするのを防ぐ。

### 影響を受けないことを確認した箇所

サムネイル（URL 結合 + `entry.id`）・輝度スコア（store ID）・pHash（DB は path キー）・XMP（entry 経由）・スクロールのホットパス（`ThumbnailGridView`/`ThumbnailCellView` 無変更）。ID は `UInt64` のまま数値が大きくなるだけで、辞書引き・Set 判定・等値比較は値非依存 O(1)。性能影響なし。

## ⚠️ iced 版（Rust・クロスプラットフォーム / Windows 含む）への注意

この根本原因は **「スキャナがフォルダごとに ID を 1 から振り直す」というプラットフォーム非依存のロジック設計**に起因する。iced 版（`scanner.rs` + ELM `app.rs`）が同じ ID 採番パターンを持ち、かつビュー（単体ビュー・選択状態）を ID 依存で解決している場合、**同種のバグが存在しうる**。

移植・実装時のチェックリスト:

- [ ] スキャンで採番する画像 ID は **フォルダ横断でセッション内一意**か？（フォルダを開くたびに 0/1 から振り直していないか）
- [ ] 単体ビュー／選択状態が参照する ID は、フォルダ切替時に確実にクリア／無効化されるか？
- [ ] 取り残した ID 参照は **nil/None で安全に失敗**するか？（別フォルダの実在エントリに化けないか）
- [ ] フォルダ切替（世代/generation）をまたぐ非同期ロードが、前フォルダの結果で現在表示を上書きしないか？

## 関連

- ブランチ `fix/global-unique-photo-ids` は回帰時の切り戻し用に**削除せず保持**している。
- コアの scan/index/group パイプラインを横断する変更のため、グルーピング/EXIF 回帰の検証ポイント: フォルダ往復後の単体ビュー表示・RAW+JPG グルーピング・EXIF 表示/フィルタ・設定再グルーピング・フォルダ監視(reconcile)後のグルーピング。
