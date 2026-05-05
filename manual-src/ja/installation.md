# インストール

## ダウンロード

[GitHub Releases](https://github.com/hoge128/bridge-lite/releases/latest) から最新の DMG ファイルをダウンロードしてください。

## インストール手順

1. ダウンロードした `.dmg` ファイルを開く
2. `BridgeLite.app` を `アプリケーション` フォルダにドラッグ
3. アプリケーションフォルダから `BridgeLite` を起動

## Gatekeeper の警告について

bridge-lite は Apple 公証（Notarization）未対応のため、初回起動時に Gatekeeper の警告が表示されます。

**方法 1（GUI）**
1. Finder でビュワーを右クリック
2. 「開く」を選択
3. 警告ダイアログで「開く」をクリック

**方法 2（ターミナル）**

```sh
xattr -dr com.apple.quarantine ~/Applications/BridgeLite.app
```

その後、通常通り起動できます。
