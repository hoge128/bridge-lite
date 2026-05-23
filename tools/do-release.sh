#!/usr/bin/env bash
# BridgeLite リリース手順スクリプト
#
# Usage: ./tools/do-release.sh <version>
# Example: ./tools/do-release.sh 0.4.0
#
# 自動実行:
#   1. バージョン更新 (bump-version.sh)
#   2. DMG 作成・署名・Notarization (release-notarized.sh)
#   3. appcast.xml 更新・gh-pages push (release-appcast.sh)
#   4. GitHub Releases へのアップロード
#
# 手動操作が必要な箇所（スクリプトが一時停止して案内します）:
#   - Xcode で ⌘B（ビルド確認）
#   - Xcode で Archive → Distribute App → Developer ID → Export

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$REPO_ROOT/tools"

# ─── カラー出力 ───────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

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
    echo "Example: $0 0.4.0"
    exit 1
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}ERROR: バージョンは x.y.z 形式で指定してください${NC}"
    exit 1
fi

echo -e "\n${BOLD}BridgeLite v${VERSION} リリースを開始します${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── STEP 1: バージョン更新 ───────────────────────────────────
step "STEP 1/5: バージョン更新 (bump-version.sh)"
"$TOOLS/bump-version.sh" "$VERSION"
ok "project.yml + Info.plist を v${VERSION} に更新しました"

# ─── STEP 2: Xcode ビルド確認 ─────────────────────────────────
step "STEP 2/5: Xcode ビルド確認（手動）"
pause "  Xcode で ${BOLD}⌘B${NC}${YELLOW} を押してビルドが通ることを確認してください。
  エラーがあれば修正してから Enter を押してください。"

# ─── STEP 3: Xcode Archive ────────────────────────────────────
step "STEP 3/5: Xcode Archive（手動）"
pause "  Xcode で以下の手順を実行してください:

  ${BOLD}Product → Archive${NC}${YELLOW}
    → ウィンドウが開いたら ${BOLD}Distribute App${NC}${YELLOW}
    → ${BOLD}Developer ID${NC}${YELLOW} を選択
    → ${BOLD}Export${NC}${YELLOW} をクリック
    → 保存先: ${BOLD}${REPO_ROOT}/archive/${NC}${YELLOW}

  archive/ 配下に BridgeLite.app が出力されたことを確認してください。"

# archive/ に .app があるか確認
APP_PATH=$(find "$REPO_ROOT/archive" -maxdepth 2 -name "BridgeLite.app" -type d 2>/dev/null | sort | tail -1)
if [[ -z "$APP_PATH" ]]; then
    echo -e "${RED}ERROR: archive/ 配下に BridgeLite.app が見つかりません。${NC}"
    echo "Xcode の Export が完了してから再実行してください。"
    exit 1
fi
ok "BridgeLite.app を確認: $APP_PATH"

# ─── STEP 4: DMG 作成・署名・Notarization ────────────────────
step "STEP 4/5: DMG 作成・Notarization（自動・数分かかります）"
"$TOOLS/release-notarized.sh" "$VERSION"
ok "dmgs/BridgeLite-${VERSION}.dmg の作成・Notarization 完了"

# ─── STEP 5: appcast.xml 更新 ─────────────────────────────────
step "STEP 5/5: appcast.xml 生成・GitHub Pages 反映（自動）"

# リリースノートが未作成なら案内
RELEASE_NOTES="$REPO_ROOT/docs/releases/${VERSION}.html"
if [[ ! -f "$RELEASE_NOTES" ]]; then
    warn "リリースノートがありません: docs/releases/${VERSION}.html"
    warn "release-appcast.sh が空テンプレートを生成します。後で編集してください。"
fi

"$TOOLS/release-appcast.sh" "$VERSION"
ok "appcast.xml を更新・gh-pages に push しました"

# ─── GitHub Releases へアップロード ──────────────────────────
step "GitHub Releases へアップロード（自動）"

DMG_PATH="$REPO_ROOT/dmgs/BridgeLite-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

if ! command -v gh &>/dev/null; then
    warn "gh コマンドが見つかりません。手動でアップロードしてください:"
    warn "  https://github.com/hoge128/bridge-lite/releases/new"
else
    NOTES_BODY=""
    if [[ -f "$RELEASE_NOTES" ]]; then
        NOTES_BODY=$(cat "$RELEASE_NOTES")
    else
        NOTES_BODY="BridgeLite v${VERSION}"
    fi

    gh release create "mac/v${VERSION}" \
        "$DMG_PATH" \
        "$SHA_PATH" \
        --repo hoge128/bridge-lite \
        --title "BridgeLite ${VERSION}" \
        --notes "$NOTES_BODY"
    ok "GitHub Releases に mac/v${VERSION} を公開しました"
fi

# ─── master ブランチに commit & push ─────────────────────────
step "master ブランチに記録"
git -C "$REPO_ROOT" add \
    xcode/BridgeLite/project.yml \
    xcode/BridgeLite/BridgeLite/Resources/Info.plist \
    docs/appcast.xml \
    "docs/releases/${VERSION}.html" 2>/dev/null || true

git -C "$REPO_ROOT" commit -m "release: mac/v${VERSION}" || true
git -C "$REPO_ROOT" push origin master
git -C "$REPO_ROOT" push public master
git -C "$REPO_ROOT" push origin "mac/v${VERSION}"
git -C "$REPO_ROOT" push public "mac/v${VERSION}"
ok "master ブランチと mac/v${VERSION} タグを push しました"

# ─── 完了 ────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  🎉 BridgeLite ${VERSION} リリース完了！${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  GitHub Releases : https://github.com/hoge128/bridge-lite/releases/tag/mac%2Fv${VERSION}"
echo "  appcast URL     : https://hoge128.github.io/bridge-lite/appcast.xml"
echo ""
echo "  既存ユーザーは次回起動時または 24 時間以内にアップデート通知を受け取ります。"
