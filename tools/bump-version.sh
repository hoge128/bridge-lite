#!/usr/bin/env bash
# バージョン一括更新スクリプト
#
# Usage: ./tools/bump-version.sh <version>
# Example: ./tools/bump-version.sh 0.4.0
#
# 更新対象（DMG/Direct = BridgeLite ターゲット限定）:
#   - xcode/BridgeLite/project.yml の BridgeLite セクションの CFBundleShortVersionString
#   - xcode/BridgeLite/project.yml の BridgeLite セクションの CFBundleVersion（自動インクリメント）
#   - xcodegen generate → Info.plist に反映
#   - crates/bridge-core/Cargo.toml の version
#   - crates/bridge-ffi/Cargo.toml の version
#
# 注意: BridgeLiteMAS / BridgeLiteiOS の版数は touch しない（それぞれ
#       do-release-mas.sh / do-release-ios.sh が自セクション限定で更新する）。
#       全行 sed 置換だと Direct と MAS が同版数のとき MAS まで巻き込むため、
#       Python でセクション限定にしている。
#
# 規則:
#   - CFBundleShortVersionString = マーケティングバージョン (例: 0.4.0)
#   - CFBundleVersion = リリースのたびに +1 するビルド番号（Sparkle が更新判定に使う）
#   - Info.plist は xcodegen の生成物なので直接編集しない

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$REPO_ROOT/xcode/BridgeLite/project.yml"
CARGO_CORE="$REPO_ROOT/crates/bridge-core/Cargo.toml"
CARGO_FFI="$REPO_ROOT/crates/bridge-ffi/Cargo.toml"

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

# ─── 現在のバージョンを取得（Direct = BridgeLite セクション限定）──
# '  BridgeLite:' は targets: 以降から検索する（schemes: にも同名があるため）。
# '  BridgeLiteMAS:' / '  BridgeLiteiOS:' はコロン位置が違うので一致しない。
CURRENT_VERSION=$(python3 -c "
import re
c = open('$PROJECT_YML').read()
p = c.index('  BridgeLite:', c.index('\ntargets:'))
print(re.search(r'CFBundleShortVersionString: \"([^\"]+)\"', c[p:]).group(1))
")
CURRENT_BUILD=$(python3 -c "
import re
c = open('$PROJECT_YML').read()
p = c.index('  BridgeLite:', c.index('\ntargets:'))
print(re.search(r'CFBundleVersion: \"([^\"]+)\"', c[p:]).group(1))
")

if [[ -z "$CURRENT_VERSION" || -z "$CURRENT_BUILD" ]]; then
    echo "ERROR: project.yml の BridgeLite セクションから版数を読み取れませんでした"
    exit 1
fi

NEW_BUILD=$((CURRENT_BUILD + 1))

echo "現在: $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "更新後: $NEW_VERSION (build $NEW_BUILD)"
echo ""

# ─── project.yml を更新（BridgeLite セクションのみ）───────────────
# content[p:] は BridgeLite が先頭なので、最初の1件置換で確実に Direct を捉える。
python3 -c "
c = open('$PROJECT_YML').read()
p = c.index('  BridgeLite:', c.index('\ntargets:'))
pre, post = c[:p], c[p:]
post = post.replace('CFBundleShortVersionString: \"$CURRENT_VERSION\"',
                    'CFBundleShortVersionString: \"$NEW_VERSION\"', 1)
post = post.replace('CFBundleVersion: \"$CURRENT_BUILD\"',
                    'CFBundleVersion: \"$NEW_BUILD\"', 1)
open('$PROJECT_YML', 'w').write(pre + post)
"
echo "✓ project.yml を更新しました（BridgeLite セクションのみ）"

# ─── Cargo.toml を更新 ───────────────────────────────────────
sed -i '' \
    "s/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/version = \"$NEW_VERSION\"/" \
    "$CARGO_CORE"
sed -i '' \
    "s/^version = \"[0-9]*\.[0-9]*\.[0-9]*\"/version = \"$NEW_VERSION\"/" \
    "$CARGO_FFI"
echo "✓ Cargo.toml を更新しました (bridge-core, bridge-ffi)"

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
echo "  5. gh release create mac/v$NEW_VERSION ./dmgs/BridgeLite-$NEW_VERSION.dmg ..."
