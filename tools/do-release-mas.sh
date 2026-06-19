#!/usr/bin/env bash
# BridgeLite Mac App Store リリース手順スクリプト
#
# Usage: ./tools/do-release-mas.sh <version>
# Example: ./tools/do-release-mas.sh 0.5.0
#
# 自動実行:
#   1. MAS バージョン更新 (project.yml の BridgeLiteMAS セクション + xcodegen)
#   2. Rust ライブラリ release ビルド (build-rust-xcframework.sh --release)
#   3. git commit + push + タグ作成 (mas/v<version>)
#
# 手動操作が必要な箇所（スクリプトが一時停止して案内します）:
#   - App Store リリースノート作成 (docs/appstore/releases/mac/<version>.md)
#   - fastlane/metadata/{ja,en-US}/release_notes.txt の更新
#   - Xcode で BridgeLiteMAS スキームを選択して ⌘B（ビルド確認）
#   - Xcode で Archive → Distribute App → App Store Connect → Upload（.pkg）
#   - ASC へのメタデータ/スクショ投入（fastlane deliver 等。このスクリプトでは行わない）
#
# Direct(DMG/Sparkle) 版のリリースは tools/do-release.sh（こちらとは別系統）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$REPO_ROOT/tools"
PROJECT_YML="$REPO_ROOT/xcode/BridgeLite/project.yml"

# ─── カラー出力 ───────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
step()  { echo -e "\n${CYAN}${BOLD}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}✓ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
pause() {
    echo -e "\n${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}${BOLD}  手動操作が必要です${NC}"
    echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "$1"
    echo -e "${YELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    read -rp "完了したら Enter を押してください..."
}

# ─── 引数確認 ─────────────────────────────────────────────────
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.5.0"
    exit 1
fi
VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}ERROR: バージョンは x.y.z 形式で指定してください${NC}"
    exit 1
fi

echo -e "\n${BOLD}BridgeLite (Mac App Store) v${VERSION} リリースを開始します${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── STEP 1: MAS バージョン更新 ───────────────────────────────
step "STEP 1/4: MAS バージョン更新 (project.yml の BridgeLiteMAS セクション)"

MAS_CURRENT_VERSION=$(python3 -c "
import re
content = open('$PROJECT_YML').read()
pos = content.index('  BridgeLiteMAS:', content.index('\ntargets:'))
m = re.search(r'CFBundleShortVersionString: \"([^\"]+)\"', content[pos:])
print(m.group(1) if m else '')
")
MAS_CURRENT_BUILD=$(python3 -c "
import re
content = open('$PROJECT_YML').read()
pos = content.index('  BridgeLiteMAS:', content.index('\ntargets:'))
m = re.search(r'CFBundleVersion: \"([^\"]+)\"', content[pos:])
print(m.group(1) if m else '')
")

if [[ -z "$MAS_CURRENT_VERSION" || -z "$MAS_CURRENT_BUILD" ]]; then
    echo -e "${RED}ERROR: project.yml から MAS バージョンを読み取れませんでした${NC}"
    exit 1
fi

MAS_NEW_BUILD=$((MAS_CURRENT_BUILD + 1))
echo "現在: MAS $MAS_CURRENT_VERSION (build $MAS_CURRENT_BUILD)"
echo "更新後: MAS $VERSION (build $MAS_NEW_BUILD)"
echo ""

python3 -c "
content = open('$PROJECT_YML').read()
pos = content.index('  BridgeLiteMAS:', content.index('\ntargets:'))
pre, post = content[:pos], content[pos:]
post = post.replace('CFBundleShortVersionString: \"$MAS_CURRENT_VERSION\"',
                    'CFBundleShortVersionString: \"$VERSION\"', 1)
post = post.replace('CFBundleVersion: \"$MAS_CURRENT_BUILD\"',
                    'CFBundleVersion: \"$MAS_NEW_BUILD\"', 1)
open('$PROJECT_YML', 'w').write(pre + post)
"
ok "project.yml を更新しました"

# xcodegen 再生成（Xcode 起動中は Package.resolved 消失リスクがあるため警告）
if pgrep -x Xcode >/dev/null; then
    warn "Xcode が起動中です。xcodegen generate は Package.resolved を消す恐れがあります。"
    pause "  Xcode を完全終了してから Enter を押してください。"
fi
if command -v xcodegen &>/dev/null; then
    (cd "$REPO_ROOT/xcode/BridgeLite" && xcodegen generate)
    ok "xcodegen generate 完了（BridgeLiteMAS/Resources/Info.plist に反映）"
else
    warn "xcodegen が見つかりません。手動で xcodegen generate を実行してください。"
fi

# ─── リリースノート確認 ───────────────────────────────────────
RELEASE_NOTES="$REPO_ROOT/docs/appstore/releases/mac/${VERSION}.md"
if [[ ! -f "$RELEASE_NOTES" ]]; then
    mkdir -p "$(dirname "$RELEASE_NOTES")"
    pause "  App Store リリースノートが見つかりません。以下を作成してください:

    ${BOLD}docs/appstore/releases/mac/${VERSION}.md${NC}${YELLOW}

  Promotional Text（日英）と What's New（日英）を記載。
  参考: docs/appstore/releases/ios/ の前バージョン"
    if [[ ! -f "$RELEASE_NOTES" ]]; then
        echo -e "${RED}ERROR: ${RELEASE_NOTES} が作成されていません。${NC}"
        exit 1
    fi
fi
ok "リリースノートを確認: docs/appstore/releases/mac/${VERSION}.md"

pause "  fastlane の What's New を更新してください（ASC に反映される実体はこちら）:

    ${BOLD}fastlane/metadata/en-US/release_notes.txt${NC}${YELLOW}
    ${BOLD}fastlane/metadata/ja/release_notes.txt${NC}${YELLOW}

  ついでに description / keywords / promotional_text に変更があれば更新。"

# ─── STEP 2: Rust ライブラリ release ビルド ──────────────────
step "STEP 2/4: Rust ライブラリ release ビルド (build-rust-xcframework.sh --release)"
"$TOOLS/build-rust-xcframework.sh" --release
ok "libbridge_ffi.a (macOS) を release ビルドしました"

# ─── STEP 3: Xcode ビルド確認 ─────────────────────────────────
step "STEP 3/4: Xcode ビルド確認（手動）"
pause "  Xcode でスキームを ${BOLD}BridgeLiteMAS${NC}${YELLOW} に切り替え、
  ${BOLD}My Mac${NC}${YELLOW} を選択して ${BOLD}⌘B${NC}${YELLOW} を押し、ビルドが通ることを確認してください。"

# ─── STEP 4: Archive → App Store Connect Upload ──────────────
step "STEP 4/4: Xcode Archive → App Store Connect Upload（手動・.pkg）"
pause "  Xcode で以下を実行（スキーム: BridgeLiteMAS）:

  ${BOLD}Product → Archive${NC}${YELLOW}
    → ${BOLD}Distribute App${NC}${YELLOW}
    → ${BOLD}App Store Connect${NC}${YELLOW} を選択（Developer ID ではない）
    → ${BOLD}Upload${NC}${YELLOW}
    → Organizer でアップロード完了を確認

  ※ App Sandbox + Apple Distribution 署名で書き出されます。
  ※ 完了後 App Store Connect の TestFlight/ビルド一覧に処理中で表示されます。"

# ─── ASC メタデータ/スクショ投入は手動運用 ───────────────────
# fastlane deliver はこのスクリプトでは行わない。バイナリは STEP 4 で Xcode から
# アップロード済み。メタデータ/スクショは ASC Web もしくは別途 `fastlane deliver`
# （fastlane/metadata 日英・fastlane/screenshots）で各自投入する。

# ─── git commit + push + tag ─────────────────────────────────
step "master ブランチに記録 + タグ作成"
git -C "$REPO_ROOT" add \
    xcode/BridgeLite/project.yml \
    xcode/BridgeLite/BridgeLiteMAS/Resources/Info.plist \
    "docs/appstore/releases/mac/${VERSION}.md" \
    fastlane/ 2>/dev/null || true
git -C "$REPO_ROOT" commit -m "release: mas/v${VERSION}" || true

TAG="mas/v${VERSION}"
if git -C "$REPO_ROOT" tag "$TAG" 2>/dev/null; then
    ok "タグ ${TAG} を作成しました"
else
    warn "タグ ${TAG} は既に存在します（スキップ）"
fi
git -C "$REPO_ROOT" push origin master
git -C "$REPO_ROOT" push public master 2>/dev/null || warn "public リモートへの push をスキップしました"
git -C "$REPO_ROOT" push origin "$TAG" 2>/dev/null || warn "タグ ${TAG} は origin に既に存在します（スキップ）"
git -C "$REPO_ROOT" push public "$TAG" 2>/dev/null || warn "タグ ${TAG} は public に既に存在します（スキップ）"
ok "master ブランチを push しました"

# ─── 完了 ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  BridgeLite (Mac App Store) ${VERSION} リリース準備完了！${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  タグ              : mas/v${VERSION} (build ${MAS_NEW_BUILD})"
echo "  App Store Connect : https://appstoreconnect.apple.com/"
echo ""
echo "  ASC でビルド処理完了後、バージョンにビルドを紐付けて「審査に提出」してください。"
