#!/usr/bin/env bash
# appcast.xml 更新スクリプト
#
# Usage: ./tools/release-appcast.sh <version>
# Example: ./tools/release-appcast.sh 0.4.2
#
# 動作:
#   1. dmgs/BridgeLite-<version>.dmg の EdDSA 署名と length を sign_update で取得
#   2. docs/appcast.xml の先頭に新しい <item> を追記（既存エントリは保持）
#   3. gh-pages ブランチに appcast.xml と releases/<version>.html を反映

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="$REPO_ROOT/tools/sparkle/sign_update"

# ─── 前提確認 ─────────────────────────────────────────────────
if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "ERROR: $SIGN_UPDATE が見つかりません。"
    exit 1
fi

# ─── 引数確認 ─────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.4.2"
    exit 1
fi

VERSION="$1"
echo "→ Version: $VERSION"

# ─── DMG 確認 ─────────────────────────────────────────────────
DMG_PATH="$REPO_ROOT/dmgs/BridgeLite-${VERSION}.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: $DMG_PATH が見つかりません。"
    echo "先に tools/release-notarized.sh を実行してください。"
    exit 1
fi

# ─── sign_update で署名・length を取得 ────────────────────────
echo "→ EdDSA 署名を取得中..."
SIGN_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")
ED_SIG=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGN_OUTPUT"  | grep -o 'length="[^"]*"'             | cut -d'"' -f2)
echo "  edSignature: ${ED_SIG:0:20}..."
echo "  length: $LENGTH"

# ─── build number を Info.plist から取得 ──────────────────────
PLIST="$REPO_ROOT/xcode/BridgeLite/BridgeLite/Resources/Info.plist"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
echo "→ Build: $BUILD"

# ─── 公開日時（RFC 822）────────────────────────────────────────
PUB_DATE=$(date -R)

# ─── リリースノート確認 ───────────────────────────────────────
RELEASES_DIR="$REPO_ROOT/docs/releases"
RELEASE_NOTES="$RELEASES_DIR/${VERSION}.html"
if [[ ! -f "$RELEASE_NOTES" ]]; then
    echo "WARNING: $RELEASE_NOTES が見つかりません。空テンプレートを生成します。"
    mkdir -p "$RELEASES_DIR"
    cat > "$RELEASE_NOTES" << HTML
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>BridgeLite ${VERSION}</title></head>
<body>
<h2>BridgeLite ${VERSION}</h2>
<ul>
  <li>（ここにリリースノートを記入してください）</li>
</ul>
</body>
</html>
HTML
    echo "  → $RELEASE_NOTES を作成しました。後で編集してください。"
fi

# ─── appcast.xml に先頭エントリを追記 ────────────────────────
APPCAST="$REPO_ROOT/docs/appcast.xml"
echo "→ appcast.xml を更新中..."

NEW_ITEM="        <item>
            <title>${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <link>https://hoge128.github.io/bridge-lite/</link>
            <sparkle:releaseNotesLink>https://hoge128.github.io/bridge-lite/releases/${VERSION}.html</sparkle:releaseNotesLink>
            <sparkle:fullReleaseNotesLink>https://hoge128.github.io/bridge-lite/releases/${VERSION}.html</sparkle:fullReleaseNotesLink>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url=\"https://github.com/hoge128/bridge-lite/releases/download/mac%2Fv${VERSION}/BridgeLite-${VERSION}.dmg\" length=\"${LENGTH}\" type=\"application/octet-stream\" sparkle:edSignature=\"${ED_SIG}\"/>
        </item>"

python3 - "$APPCAST" "$NEW_ITEM" << 'PYEOF'
import sys, re

appcast_path = sys.argv[1]
new_item = sys.argv[2]

with open(appcast_path, 'r') as f:
    content = f.read()

# <channel> の直後、最初の <item> の前に挿入
content = re.sub(
    r'(<channel>\s*<title>[^<]*</title>\s*)',
    r'\1' + new_item + '\n',
    content,
    count=1
)

with open(appcast_path, 'w') as f:
    f.write(content)
PYEOF

echo "→ docs/appcast.xml を更新しました"

# ─── gh-pages ブランチに反映 ──────────────────────────────────
echo "→ gh-pages ブランチに反映中..."
GH_PAGES_WORKTREE="/tmp/bridge-lite-gh-pages-$$"
git -C "$REPO_ROOT" fetch public gh-pages 2>/dev/null || true
git -C "$REPO_ROOT" worktree add "$GH_PAGES_WORKTREE" public/gh-pages

cp "$REPO_ROOT/docs/appcast.xml" "$GH_PAGES_WORKTREE/appcast.xml"

mkdir -p "$GH_PAGES_WORKTREE/releases"
rsync -a --exclude="*.dmg" "$RELEASES_DIR/" "$GH_PAGES_WORKTREE/releases/"

git -C "$GH_PAGES_WORKTREE" add appcast.xml releases/ 2>/dev/null || true
git -C "$GH_PAGES_WORKTREE" commit -m "release: appcast for mac/v${VERSION}" || echo "  (変更なし)"
git -C "$GH_PAGES_WORKTREE" push public HEAD:gh-pages
git -C "$REPO_ROOT" worktree remove "$GH_PAGES_WORKTREE"
echo "→ gh-pages に push しました（GitHub Pages が数分で更新されます）"

echo ""
echo "=== 完了 ==="
echo "  appcast URL: https://hoge128.github.io/bridge-lite/appcast.xml"
