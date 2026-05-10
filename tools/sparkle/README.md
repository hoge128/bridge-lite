# tools/sparkle/

Sparkle 公式ツールの置き場。バイナリは Git で管理する（LFS 不要、数 MB 程度）。

## セットアップ手順

1. [Sparkle Releases](https://github.com/sparkle-project/Sparkle/releases) から最新の tar.xz をダウンロード
2. 展開して `bin/generate_appcast` と `bin/sign_update` をこのディレクトリにコピー
3. `chmod +x generate_appcast sign_update`

## EdDSA 鍵生成（初回のみ）

```bash
# SwiftPM 解決後:
~/Library/Developer/Xcode/DerivedData/<hash>/SourcePackages/checkouts/Sparkle/bin/generate_keys
# → 秘密鍵が Keychain に保存される
# → 標準出力の公開鍵 (base64) を xcode/BridgeLite/project.yml の SUPublicEDKey に貼る
```

**秘密鍵は必ず 1Password 等にもバックアップすること。**  
紛失すると以後のリリースでアップデートを配信できなくなる。

## バージョン記録

| ツール | Sparkle バージョン |
|---|---|
| generate_appcast | （コピー時に記録） |
| sign_update | （コピー時に記録） |
