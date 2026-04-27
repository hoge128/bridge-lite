# 配布・公開のための要件

> 対象: bridge-lite (macOS アプリ)

---

## ローカル開発（現在の状態）

`CODE_SIGN_STYLE = Automatic` + Apple ID の Personal Team で署名。有料アカウント不要。  
**配布は不可**。自分の Mac でのみ実行できる。

---

## 一般公開の選択肢

### A. Mac App Store 配布

| 項目 | 内容 |
|------|------|
| 必要なもの | 有料 Apple Developer Program（$99/年） |
| 署名 | Apple Distribution 証明書 |
| 審査 | Apple によるアプリレビューあり（数日〜1 週間） |
| インストール | ユーザーは App Store から普通にインストール可能 |
| Gatekeeper | 問題なし |

**bridge-lite 固有の注意点（サンドボックス）**:  
App Store は App Sandbox が必須。bridge-lite は任意フォルダを開いて XMP サイドカーを書き込む設計なので、以下のエンタイトルメントが必要になる。

```xml
<!-- BridgeLite.entitlements -->
<key>com.apple.security.app-sandbox</key>     <true/>
<key>com.apple.security.files.user-selected.read-write</key>  <true/>
```

`NSOpenPanel` で選択したフォルダは Security-Scoped Bookmark で保持する必要がある（アプリ再起動後もアクセス継続するため）。現状のコードは `openDirectory` 呼び出し後に URL を保存するだけなので、再起動時の再アクセス処理を追加実装する必要がある。

---

### B. 直接配布（Web / GitHub Release）— **推奨**

| 項目 | 内容 |
|------|------|
| 必要なもの | 有料 Apple Developer Program（$99/年） |
| 署名 | Developer ID Application 証明書 |
| 審査 | なし（Apple によるマルウェアスキャンのみ） |
| Notarization | 必須（Apple サーバへ送信してスタンプ発行） |
| インストール | `.dmg` / `.zip` を配布。初回起動時 Gatekeeper が警告を出す場合があるが通過可能 |

**bridge-lite に向いている理由**: サンドボックス不要なため、任意フォルダへのファイルシステムアクセスをそのまま維持できる。

**公開手順の概要**:

```bash
# 1. アーカイブ（Xcode GUI または xcodebuild）
xcodebuild archive \
  -scheme BridgeLite \
  -archivePath build/BridgeLite.xcarchive

# 2. Developer ID でエクスポート（ExportOptions.plist に method = "developer-id" を指定）
xcodebuild -exportArchive \
  -archivePath build/BridgeLite.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist

# 3. Notarization（xcrun notarytool）
xcrun notarytool submit build/export/BridgeLite.zip \
  --apple-id "your@email.com" \
  --team-id "XXXXXXXXXX" \
  --password "@keychain:AC_PASSWORD" \
  --wait

# 4. Staple（ノータリゼーション結果をバンドルに埋め込む）
xcrun stapler staple build/export/BridgeLite.app

# 5. DMG に固め GitHub Release などで公開
```

---

## 開発フローへの影響まとめ

| フェーズ | 署名スタイル | 費用 | 配布範囲 |
|----------|-------------|------|---------|
| ローカル開発 | Automatic / Personal Team | 無料 | 自分の Mac のみ |
| テスター配布 | Developer ID + Notarization | $99/年 | 知人・ベータテスター |
| 一般公開（直接配布） | Developer ID + Notarization | $99/年 | 誰でも |
| App Store 公開 | App Store Distribution | $99/年 | App Store ユーザー全員 |

App Store を目指す場合はサンドボックス対応（Security-Scoped Bookmark 実装）が追加で必要。直接配布のほうが実装コストは低い。
