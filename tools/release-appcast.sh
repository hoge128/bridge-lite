#!/usr/bin/env bash
# appcast.xml 生成スクリプト
#
# Usage: ./tools/release-appcast.sh [version]
#
# 前提:
#   - tools/sparkle/generate_appcast が存在すること
#     (Sparkle 公式 zip: https://github.com/sparkle-project/Sparkle/releases から
#      bin/generate_appcast を tools/sparkle/ にコピー)
#   - EdDSA 秘密鍵が macOS Keychain に登録済みであること
#     (generate_keys で生成したもの。generate_appcast が自動的に使用する)
#   - リリースノート HTML を docs/releases/<version>.html に用意すること
#     (例: docs/releases/0.4.0.html)
#
# 実行後:
#   git add docs/appcast.xml docs/releases/ && git commit && git push
#   → GitHub Pages が自動デプロイ

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATE_APPCAST="$REPO_ROOT/tools/sparkle/generate_appcast"

# ─── 前提確認 ─────────────────────────────────────────────────
if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "ERROR: $GENERATE_APPCAST が見つかりません。"
    echo "Sparkle 公式 zip (https://github.com/sparkle-project/Sparkle/releases) から"
    echo "bin/generate_appcast を tools/sparkle/ にコピーして chmod +x してください。"
    exit 1
fi

# ─── バージョン ───────────────────────────────────────────────
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    PLIST="$REPO_ROOT/xcode/BridgeLite/BridgeLite/Resources/Info.plist"
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
fi
echo "→ Version: $VERSION"

# ─── DMG を確認 ──────────────────────────────────────────────
DMG_PATH="$REPO_ROOT/dmgs/BridgeLite-${VERSION}.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: $DMG_PATH が見つかりません。"
    echo "先に tools/release-notarized.sh を実行してください。"
    exit 1
fi

# ─── docs/releases/ を準備 ───────────────────────────────────
RELEASES_DIR="$REPO_ROOT/docs/releases"
mkdir -p "$RELEASES_DIR"

# DMG を releases/ に一時コピー（generate_appcast のスキャン対象にするため）
TEMP_DMG="$RELEASES_DIR/BridgeLite-${VERSION}.dmg"
cp "$DMG_PATH" "$TEMP_DMG"
echo "→ DMG を releases/ にコピーしました（一時）"

# ─── リリースノート確認 ───────────────────────────────────────
RELEASE_NOTES="$RELEASES_DIR/${VERSION}.html"
if [[ ! -f "$RELEASE_NOTES" ]]; then
    echo "WARNING: $RELEASE_NOTES が見つかりません。"
    echo "  リリースノートを生成します（空のテンプレート）"
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
    echo "  → $RELEASE_NOTES を作成しました。内容を編集してから git push してください。"
fi

# ─── appcast.xml 生成 ─────────────────────────────────────────
echo "→ appcast.xml を生成中..."
"$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/hoge128/bridge-lite/releases/download/v${VERSION}/" \
    --link "https://hoge128.github.io/bridge-lite/" \
    --full-release-notes-url "https://hoge128.github.io/bridge-lite/releases/${VERSION}.html" \
    "$RELEASES_DIR"

# appcast.xml を docs/ 直下に移動（master ブランチの記録用）
mv "$RELEASES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"
echo "→ docs/appcast.xml を更新しました"

# 一時コピーした DMG を削除（DMG は GitHub Releases からダウンロードさせる）
rm "$TEMP_DMG"
echo "→ 一時 DMG を削除しました"

# ─── gh-pages ブランチに appcast.xml を反映 ───────────────────
# GitHub Pages は gh-pages ブランチ root から配信されているため
echo "→ gh-pages ブランチに appcast.xml を反映中..."
GH_PAGES_WORKTREE="/tmp/bridge-lite-gh-pages-$$"
git -C "$REPO_ROOT" fetch public gh-pages
git -C "$REPO_ROOT" worktree add "$GH_PAGES_WORKTREE" public/gh-pages

cp "$REPO_ROOT/docs/appcast.xml" "$GH_PAGES_WORKTREE/appcast.xml"

# releases/ フォルダも同期
if [[ -d "$REPO_ROOT/docs/releases" ]]; then
    mkdir -p "$GH_PAGES_WORKTREE/releases"
    rsync -a --exclude="*.dmg" "$REPO_ROOT/docs/releases/" "$GH_PAGES_WORKTREE/releases/"
fi

git -C "$GH_PAGES_WORKTREE" add appcast.xml releases/ 2>/dev/null || true
git -C "$GH_PAGES_WORKTREE" commit -m "release: appcast for v${VERSION}"
git -C "$GH_PAGES_WORKTREE" push public HEAD:gh-pages
git -C "$REPO_ROOT" worktree remove "$GH_PAGES_WORKTREE"
echo "→ gh-pages に push しました（GitHub Pages が数分で更新されます）"

echo ""
echo "=== 完了 ==="
echo "次のステップ:"
echo "  1. docs/releases/${VERSION}.html のリリースノートを確認・編集"
echo "  2. master ブランチに commit & push:"
echo "     git add docs/appcast.xml docs/releases/${VERSION}.html"
echo "     git commit -m 'release: appcast for v${VERSION}'"
echo "     git push origin master && git push public master"
echo "  3. GitHub Releases に DMG をアップロード:"
echo "     gh release create v${VERSION} \\"
echo "       ./dmgs/BridgeLite-${VERSION}.dmg \\"
echo "       ./dmgs/BridgeLite-${VERSION}.dmg.sha256"
