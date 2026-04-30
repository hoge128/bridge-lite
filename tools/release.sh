#!/usr/bin/env bash
# Usage: ./tools/release.sh [version]
# Example: ./tools/release.sh 0.1.0
#
# archive/ 配下の最新 BridgeLite.app に Ad-hoc 署名し、DMG を生成する。
# Xcode の "Distribute App → Custom → Copy App" で archive/<日時>/BridgeLite.app
# を配置した後に実行する。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ─── バージョン ───────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    # Info.plist から自動取得
    PLIST="$REPO_ROOT/xcode/BridgeLite/BridgeLite/Resources/Info.plist"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
fi
echo "→ Version: $VERSION"

# ─── .app を探す ─────────────────────────────────────────────
ARCHIVE_DIR="$REPO_ROOT/archive"
APP_PATH=$(find "$ARCHIVE_DIR" -maxdepth 2 -name "BridgeLite.app" -type d | sort | tail -1)

if [[ -z "$APP_PATH" ]]; then
    echo "ERROR: BridgeLite.app が $ARCHIVE_DIR 配下に見つかりません。"
    echo "Xcode → Distribute App → Custom → Copy App で配置してください。"
    exit 1
fi
echo "→ App: $APP_PATH"

# ─── Ad-hoc 署名 ──────────────────────────────────────────────
echo "→ Ad-hoc 署名中..."
codesign --sign - --deep --force "$APP_PATH"
codesign --verify --verbose "$APP_PATH"
echo "→ 署名 OK"

# ─── DMG 作成 ─────────────────────────────────────────────────
DMG_NAME="BridgeLite-${VERSION}.dmg"
DMG_DIR="$REPO_ROOT/dmgs"
DMG_PATH="$DMG_DIR/$DMG_NAME"
mkdir -p "$DMG_DIR"
BACKGROUND="$REPO_ROOT/assets/dmg-background.png"

# 既存 DMG を削除
[[ -f "$DMG_PATH" ]] && rm "$DMG_PATH"

if ! command -v create-dmg &>/dev/null; then
    echo "ERROR: create-dmg が見つかりません。"
    echo "  brew install create-dmg  でインストールしてください。"
    exit 1
fi

echo "→ DMG 作成中: $DMG_NAME"
# --window-size は論理ピクセル。背景画像は Retina @2x 用に 1920x1080 で用意する
# (論理サイズ 960x540 の 2倍 = 1920x1080)
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

# ─── チェックサム ────────────────────────────────────────────
echo ""
echo "=== 完了 ==="
echo "DMG: $DMG_PATH"
CHECKSUM=$(shasum -a 256 "$DMG_PATH")
echo "SHA-256: $CHECKSUM"

# チェックサムをファイルにも保存
echo "$CHECKSUM" > "${DMG_PATH}.sha256"
echo "→ ${DMG_NAME}.sha256 に保存しました"
