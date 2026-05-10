# Sparkle 2 統合ガイド

## なぜ Sparkle を選んだか

bridge-lite は GitHub Releases で DMG を配布し、Developer ID 署名 + Notarization まで運用している。  
この品質水準に対して「アップデートを手動でダウンロード・ドラッグ」は一貫性を欠く。  
Sparkle 2 は ad-hoc 署名でも動くが、Notarization 済みの環境ではフル自動更新（ダウンロード→インストール→再起動）が問題なく機能するため採用。  
自前 GitHub API 実装も選択肢だったが、「ユーザー体験のために運用コストを払う」価値観を既に選択しているなら Sparkle が一貫する。

## アーキテクチャ概要

```
BridgeLiteApp.init()
  └── UpdaterController.shared (シングルトン)
        └── SPUStandardUpdaterController(startingUpdater: true)
              └── Sparkle が起動時に scheduled check を実行
                    └── SUFeedURL = https://hoge128.github.io/bridge-lite/appcast.xml
```

UI 接点:
- `BridgeLite` メニュー → `Check for Updates…` → `UpdaterController.shared.checkForUpdates()`
- Settings → General → Updates セクション（トグル・Check Now・最終確認日時）

## GitHub Pages の構成（重要）

`hoge128/bridge-lite` の GitHub Pages は **`gh-pages` ブランチの root** から配信されている。
`master` ブランチの `/docs` フォルダではない点に注意。

- `appcast.xml` の公開 URL: `https://hoge128.github.io/bridge-lite/appcast.xml`
- `appcast.xml` の管理: `docs/appcast.xml`（master ブランチ、記録用）と `gh-pages` root（本番配信）の 2 か所
- `tools/release-appcast.sh` が `docs/appcast.xml` 生成後に自動で `gh-pages` へも push する

## ファイル構成（追加・変更分）

```
xcode/BridgeLite/
├── project.yml                         # packages: Sparkle, dependencies, Info.plist Sparkle キー追加
└── BridgeLite/
    ├── BridgeLiteApp.swift             # init() で UpdaterController.shared 起動、メニュー追加
    ├── Updater/
    │   └── UpdaterController.swift     # SPUStandardUpdaterController ラッパ（新規）
    ├── Views/
    │   └── SettingsView.swift          # Updates セクション追加（Cache セクション直前）
    └── Resources/
        └── Localizable.xcstrings       # 7 キー追加（menu.check_for_updates, settings.update.*）

tools/
├── release-notarized.sh                # Sparkle XPC ヘルパー署名検証ステップ追加
├── release-appcast.sh                  # appcast.xml 生成スクリプト（新規）
└── sparkle/
    ├── README.md                       # ツール取得手順（新規）
    ├── generate_appcast                # 要手動コピー（Sparkle 公式 zip から）
    └── sign_update                     # 要手動コピー（Sparkle 公式 zip から）

docs/
├── appcast.xml                         # GitHub Pages で公開する feed（新規・初期スケルトン）
└── releases/
    └── <version>.html                  # リリースノート（リリース毎に手動作成）
```

## Info.plist に追加した Sparkle キー

| キー | 値 | 役割 |
|---|---|---|
| `SUFeedURL` | `https://hoge128.github.io/bridge-lite/appcast.xml` | appcast の URL |
| `SUPublicEDKey` | base64 公開鍵 | EdDSA 署名検証用 |
| `SUEnableInstallerLauncherService` | `true` | XPC ヘルパー利用 |
| `SUEnableAutomaticChecks` | `true` | 自動チェックのデフォルト ON |
| `SUScheduledCheckInterval` | `86400` | 24h スロットル（秒） |
| `SUAllowsAutomaticUpdates` | `true` | バックグラウンド自動 DL/インストール許可 |

`SUPublicEDKey` の現在値は `PLACEHOLDER_REPLACE_WITH_GENERATED_KEY`。  
**鍵生成後に `project.yml` の `SUPublicEDKey` を実際の公開鍵に置き換えること。**

## 初期セットアップ手順（初回のみ）

### 1. xcodegen で Sparkle を追加

```bash
cd xcode/BridgeLite
xcodegen generate
# Xcode を開いて ⌘B → Sparkle の SwiftPM 解決が走る
```

### 2. EdDSA 鍵を生成

Xcode で ⌘B を実行し SwiftPM 解決が完了してから:

```bash
# generate_keys のパスを探す
find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" 2>/dev/null | head -1

# 鍵を生成（秘密鍵が Keychain に保存され、公開鍵が stdout に表示される）
<上のパス>/generate_keys
```

**公開鍵 (base64) を `xcode/BridgeLite/project.yml` の `SUPublicEDKey` に貼り、再度 `xcodegen generate` する。**

```bash
cd xcode/BridgeLite && xcodegen generate
```

秘密鍵のバックアップ:

```bash
# 秘密鍵エクスポート（保管して .gitignore に入れること）
<上のパス>/generate_keys -x privkey.txt
# → 1Password 等に保管後、privkey.txt を削除
```

### 3. Sparkle ツールを tools/sparkle/ に配置

```bash
# Sparkle 公式リリースページから tar.xz をダウンロード
# https://github.com/sparkle-project/Sparkle/releases
# 展開して:
cp <展開先>/bin/generate_appcast tools/sparkle/
cp <展開先>/bin/sign_update tools/sparkle/
chmod +x tools/sparkle/generate_appcast tools/sparkle/sign_update
```

## リリース運用フロー（毎リリース）

```bash
# 1. バージョン更新
# xcode/BridgeLite/project.yml の CFBundleShortVersionString / CFBundleVersion を更新
# cd xcode/BridgeLite && xcodegen generate

# 2. Xcode で Archive → Distribute App → Developer ID → Export
#    → archive/<日時>/BridgeLite.app に出力される

# 3. DMG ビルド + Notarize + Staple
./tools/release-notarized.sh 0.4.0
# → dmgs/BridgeLite-0.4.0.dmg が生成される

# 4. リリースノートを用意
mkdir -p docs/releases
# docs/releases/0.4.0.html を作成（HTML 形式）

# 5. appcast.xml を生成
./tools/release-appcast.sh 0.4.0
# → docs/appcast.xml が更新される

# 6. GitHub Pages に push
git add docs/appcast.xml docs/releases/0.4.0.html
git commit -m "release: appcast for v0.4.0"
git push

# 7. GitHub Releases に DMG をアップロード
gh release create v0.4.0 \
  ./dmgs/BridgeLite-0.4.0.dmg \
  ./dmgs/BridgeLite-0.4.0.dmg.sha256 \
  --notes "$(cat docs/releases/0.4.0.html)"
```

**順序が重要**: GitHub Releases への DMG アップロード（step 7）より前に GitHub Pages の appcast.xml を push（step 6）すること。  
Sparkle が appcast を取得したとき、enclosure URL の DMG が 404 だと「アップデートを見つけたがダウンロードできない」状態になる。

## テスト手順

### ローカルテスト（ダイアログ表示の確認）

```bash
# 1. ローカル HTTP サーバーを立てる
cd /Users/itotsum/work/bridge-lite/docs
python3 -m http.server 8000
# → http://localhost:8000/appcast.xml が公開される

# 2. DEBUG ビルドは UpdaterDelegate.feedURLString(for:) が
#    自動的に localhost:8000 を向く（UpdaterController.swift の #if DEBUG 参照）

# 3. バージョンを下げてビルド
# project.yml の CFBundleShortVersionString を "0.0.1" に変更
# xcodegen generate → Xcode で ⌘R

# 4. docs/appcast.xml に現行バージョン（0.3.0 等）の <item> を追加した状態で起動
# → Sparkle ダイアログが表示されれば OK
```

### appcast.xml のテスト用 item

```xml
<item>
  <title>BridgeLite 0.3.0</title>
  <sparkle:releaseNotesLink>http://localhost:8000/releases/0.3.0.html</sparkle:releaseNotesLink>
  <pubDate>Thu, 08 May 2025 00:00:00 +0000</pubDate>
  <enclosure
    url="http://localhost:8000/BridgeLite-0.3.0.dmg"
    sparkle:version="3"
    sparkle:shortVersionString="0.3.0"
    length="0"
    sparkle:edSignature="<generate_appcast で生成した署名>"
    type="application/octet-stream" />
</item>
```

### EdDSA 署名検証テスト

```bash
# project.yml の SUPublicEDKey を 1 文字書き換えて xcodegen generate → ビルド → 起動
# Console.app で "Sparkle" プロセスをフィルタ
# → "ED signature does not match" ログが出れば検証が機能している証拠
```

### 24h スロットル確認

```bash
# 強制リセット（次回起動で必ずチェック）
defaults delete io.github.bridge-lite SULastCheckTime

# スキップ確認（今チェック済みとマークして次回起動でスキップ）
defaults write io.github.bridge-lite SULastCheckTime -date "$(date)"
```

## Sparkle の XPC ヘルパー構造と署名の注意

Sparkle 2 は以下の XPC ヘルパーを含む:

```
BridgeLite.app/
└── Contents/
    └── Frameworks/
        └── Sparkle.framework/
            └── Versions/B/
                ├── XPCServices/
                │   ├── Downloader.xpc    # 並列ダウンロード担当
                │   └── Installer.xpc     # インストール（アプリ置換）担当
                ├── Updater.app           # アップデート UI プロセス
                └── Autoupdate            # バックグラウンド自動更新エージェント
```

**`--deep` フラグは使わない**: Sparkle 公式は `--deep` による内部ヘルパーへの一括署名を明確に NG としている。  
Entitlements が上書きされてヘルパーが動かなくなる。

Xcode の `Distribute App → Developer ID → Export` 経由で出した `.app` は Xcode が各ヘルパーを個別署名済みなので、`tools/release-notarized.sh` から再署名する必要はない。  
署名確認のステップのみ追加している（step 6 直後）。

## トラブルシューティング

### `No such module 'Sparkle'` (SourceKit エラー)

`xcodegen generate` 未実行または SwiftPM 解決前の正常な状態。  
`xcodegen generate` → Xcode を開いて ⌘B で解決する。

### Sparkle ダイアログが表示されない

1. `appcast.xml` の `<item>` の `sparkle:shortVersionString` が現在のアプリバージョン以上になっていないか確認
2. Console.app で "Sparkle" プロセスをフィルタしてエラーログを確認
3. 24h スロットルがかかっていないか確認（`defaults delete io.github.bridge-lite SULastCheckTime`）
4. `SUFeedURL` の URL が正しいか確認（GitHub Pages が公開済みか）

### 「アップデートを検出したがインストールできない」

enclosure URL の DMG が 404 になっている。  
GitHub Releases に DMG がアップロードされているか確認。  
**appcast push より前に GitHub Releases にアップロードするか、同タイミングで実施すること。**

### EdDSA 署名エラー

- `SUPublicEDKey` が間違っている（`generate_keys` で生成した公開鍵と異なる）
- `generate_appcast` 実行時に秘密鍵が Keychain にない（別 Mac でビルドした場合など）
- Keychain から秘密鍵を確認: Keychain Access.app で「Sparkle」で検索

## 将来の考慮事項

### Intel (x86_64) 版を追加する場合

`build-rust-xcframework.sh` を universal binary 対応（`lipo` で arm64 + x86_64 を合成）にし、  
`project.yml` の `EXCLUDED_ARCHS: x86_64` を削除する。  
Sparkle の arm64 / x86_64 universal 対応は済んでいるため、`generate_appcast` 側の変更は不要。  
ただし DMG が fat binary になるのでサイズが増加する点は考慮すること。

### delta update（差分アップデート）

Sparkle は `generate_appcast` 実行時に前バージョンの DMG が同一ディレクトリにあれば自動的に delta アーカイブを生成する。  
`docs/releases/` に過去 DMG を蓄積しておくと効果的だが、GitHub Pages の容量（1GB 制限）に注意。  
DMG は GitHub Releases に置いたまま appcast.xml のみ Pages に置く現状運用では delta 生成は難しい。

### 複数 appcast チャンネル（Beta / Stable）

`SUFeedURL` を `appcast-beta.xml` と `appcast.xml` に分け、Settings で切り替えることも可能。  
`SPUUpdater.feedURL` を動的に変更すれば実現できる。将来ベータテスターを募集する場合に検討。

### Apple Developer Program 未加入時の注意

将来 Program を解約した場合、Developer ID 証明書が失効し Notarization 済み DMG の Staple が機能しなくなる（Gatekeeper がオンライン確認を要求）。  
Sparkle は Notarization を必須としないが、Ad-hoc 署名に戻す場合は `SUPublicEDKey` の検証を外す必要はなく（EdDSA は Sparkle 独自の署名で Apple 証明書とは別）、appcast の enclosure 署名は引き続き有効。
