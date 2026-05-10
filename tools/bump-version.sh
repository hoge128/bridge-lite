#!/usr/bin/env bash
# バージョン一括更新スクリプト
#
# Usage: ./tools/bump-version.sh <version>
# Example: ./tools/bump-version.sh 0.4.0
#
# 更新対象:
#   - xcode/BridgeLite/project.yml の CFBundleShortVersionString
#   - xcode/BridgeLite/project.yml の CFBundleVersion（自動インクリメント）
#   - xcodegen generate → Info.plist に反映
#
# 規則:
#   - CFBundleShortVersionString = マーケティングバージョン (例: 0.4.0)
#   - CFBundleVersion = リリースのたびに +1 するビルド番号（Sparkle が更新判定に使う）
#   - Info.plist は xcodegen の生成物なので直接編集しない

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/xcode/BridgeLite/project.yml"

# ─── 引数確認 ─────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.4.0"
    exit 1
fi

NEW_VERSION="$1"

# セマンティックバージョン形式チェック
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: バージョンは x.y.z 形式で指定してください (例: 0.4.0)"
    exit 1
fi

# ─── 現在のバージョンを取得 ───────────────────────────────────
CURRENT_VERSION=$(grep 'CFBundleShortVersionString' "$PROJECT_YML" | grep -o '"[^"]*"' | tr -d '"')
CURRENT_BUILD=$(grep 'CFBundleVersion' "$PROJECT_YML" | grep -o '"[^"]*"' | tr -d '"')
NEW_BUILD=$((CURRENT_BUILD + 1))

echo "現在: $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "更新後: $NEW_VERSION (build $NEW_BUILD)"
echo ""

# ─── project.yml を更新 ──────────────────────────────────────
sed -i '' \
    "s/CFBundleShortVersionString: \"$CURRENT_VERSION\"/CFBundleShortVersionString: \"$NEW_VERSION\"/" \
    "$PROJECT_YML"

sed -i '' \
    "s/CFBundleVersion: \"$CURRENT_BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/" \
    "$PROJECT_YML"

echo "✓ project.yml を更新しました"

# ─── xcodegen で Info.plist を再生成 ─────────────────────────
if ! command -v xcodegen &>/dev/null; then
    echo "WARNING: xcodegen が見つかりません。"
    echo "  brew install xcodegen でインストールし、手動で xcodegen generate を実行してください。"
    exit 0
fi

cd "$REPO_ROOT/xcode/BridgeLite" && xcodegen generate
echo "✓ xcodegen generate 完了（Info.plist に反映されました）"

echo ""
echo "=== バージョン更新完了 ==="
echo "  $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "  → $NEW_VERSION (build $NEW_BUILD)"
echo ""
echo "次のステップ:"
echo "  1. Xcode で ⌘B してビルドを確認"
echo "  2. Xcode で Archive → Distribute App → Developer ID → Export"
echo "  3. ./tools/release-notarized.sh $NEW_VERSION"
echo "  4. ./tools/release-appcast.sh $NEW_VERSION"
echo "  5. gh release create v$NEW_VERSION ./dmgs/BridgeLite-$NEW_VERSION.dmg ..."
