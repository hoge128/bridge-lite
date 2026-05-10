#!/usr/bin/env bash
# Developer ID 署名 + Notarization 版リリーススクリプト
#
# Usage: ./tools/release-notarized.sh [version]
#
# 事前準備（初回のみ）:
#   xcrun notarytool store-credentials "BridgeLite" \
#     --apple-id "toma135kamijo@gmail.com" \
#     --team-id "KTQ8JQW28L" \
#     --password "xxxx-xxxx-xxxx-xxxx"   # App-specific password
#
# Xcode での .app エクスポート手順:
#   Product → Archive → Distribute App → Developer ID → Export
#   → archive/<日時>/BridgeLite.app に配置されることを確認してから実行

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM_ID="KTQ8JQW28L"
SIGN_IDENTITY="Developer ID Application: Tsuyoshi Ito (${TEAM_ID})"
NOTARY_PROFILE="BridgeLite"   # store-credentials で付けたプロファイル名

# ─── バージョン ───────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    PLIST="$REPO_ROOT/xcode/BridgeLite/BridgeLite/Resources/Info.plist"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
fi
echo "→ Version: $VERSION"

# ─── .app を探す ─────────────────────────────────────────────
ARCHIVE_DIR="$REPO_ROOT/archive"
APP_PATH=$(find "$ARCHIVE_DIR" -maxdepth 2 -name "BridgeLite.app" -type d | sort | tail -1)

if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: BridgeLite.app が $ARCHIVE_DIR 配下に見つかりません。"
    echo "Xcode → Distribute App → Developer ID → Export で配置してください。"
    exit 1
fi
echo "→ App: $APP_PATH"

# ─── Developer ID 署名を確認 ─────────────────────────────────
echo "→ 署名を確認中..."
if ! codesign --verify --verbose=2 "$APP_PATH" 2>&1 | grep -q "satisfies its Designated Requirement"; then
    echo "WARNING: 署名の検証に問題がある可能性があります。続行します..."
fi
ACTUAL_IDENTITY=$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | grep "Authority=" | head -1 || true)
echo "  署名: $ACTUAL_IDENTITY"
if ! echo "$ACTUAL_IDENTITY" | grep -q "Developer ID Application"; then
    echo "ERROR: Developer ID Application で署名されていません。"
    echo "Xcode → Distribute App → Developer ID → Export でエクスポートしてください。"
    exit 1
fi
echo "→ 署名 OK"

# ─── Sparkle XPC ヘルパー署名確認 ────────────────────────────
echo "→ Sparkle XPC ヘルパー署名を確認中..."
SPARKLE_HELPERS=(
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
)
SPARKLE_FOUND=false
for helper in "${SPARKLE_HELPERS[@]}"; do
    target="$APP_PATH/$helper"
    if [[ -e "$target" ]]; then
        SPARKLE_FOUND=true
        if ! codesign --verify --verbose=2 "$target" 2>&1 | grep -qE "valid on disk|satisfies"; then
            echo "ERROR: $helper の署名が無効です。"
            echo "Xcode の Distribute App → Developer ID → Export から取得した .app を使用してください。"
            exit 1
        fi
    fi
done
if [[ "$SPARKLE_FOUND" == "true" ]]; then
    echo "→ Sparkle ヘルパー署名 OK"
else
    echo "  (Sparkle.framework が見つかりません。Sparkle 未統合版のリリースです)"
fi

# ─── DMG 作成 ─────────────────────────────────────────────────
DMG_NAME="BridgeLite-${VERSION}.dmg"
DMG_DIR="$REPO_ROOT/dmgs"
DMG_PATH="$DMG_DIR/$DMG_NAME"
mkdir -p "$DMG_DIR"
BACKGROUND="$REPO_ROOT/assets/dmg-background.png"

[[ -f "$DMG_PATH" ]] && rm "$DMG_PATH"

if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg が見つかりません。brew install create-dmg でインストールしてください。"
    exit 1
fi

echo "→ DMG 作成中: $DMG_NAME"
if [[ -f "$BACKGROUND" ]]; then
    create-dmg \
        --volname "BridgeLite" \
        --background "$BACKGROUND" \
        --window-size 960 540 \
        --icon-size 128 \
        --icon "BridgeLite.app" 240 270 \
        --app-drop-link 720 270 \
        "$DMG_PATH" \
        "$APP_PATH"
else
    echo "  (背景画像なしで作成)"
    create-dmg \
        --volname "BridgeLite" \
        --window-size 960 540 \
        --icon-size 128 \
        --icon "BridgeLite.app" 240 270 \
        --app-drop-link 720 270 \
        "$DMG_PATH" \
        "$APP_PATH"
fi
echo "→ DMG 作成完了"

# ─── Notarization ────────────────────────────────────────────
echo "→ Notarization 送信中（数分かかります）..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
echo "→ Notarization 完了"

# ─── Staple ──────────────────────────────────────────────────
echo "→ Staple 中..."
xcrun stapler staple "$DMG_PATH"
echo "→ Staple 完了"

# ─── 最終検証 ────────────────────────────────────────────────
echo "→ Gatekeeper 検証..."
spctl --assess --type open -vvv "$DMG_PATH" 2>&1 || true
echo "→ staple 済みのため配布可能"

# ─── チェックサム ────────────────────────────────────────────
echo ""
echo "=== 完了 ==="
echo "DMG: $DMG_PATH"
CHECKSUM=$(shasum -a 256 "$DMG_PATH")
echo "SHA-256: $CHECKSUM"
echo "$CHECKSUM" > "${DMG_PATH}.sha256"
echo "→ ${DMG_NAME}.sha256 に保存しました"
