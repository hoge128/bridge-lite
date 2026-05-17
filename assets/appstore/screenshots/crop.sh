#!/bin/bash
# スクリーンショットから実画面部分をトリミングするスクリプト
# 使い方:
#   ./crop.sh           # assets/appstore/src/ の PNG を一括処理
#   ./crop.sh --measure # クロップ値を決めるためにサイズだけ表示

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── クロップ設定（要調整） ──────────────────────────────
# まず ./crop.sh --measure を実行して全体サイズを確認し、
# 実画面の左上座標(X,Y)と幅・高さを設定してください
CROP_W=1206   # 実画面の幅
CROP_H=2622   # 実画面の高さ
CROP_X=107    # 実画面の左端 X 座標
CROP_Y=178    # 実画面の上端 Y 座標（ステータスバー含む）
# ────────────────────────────────────────────────────────

SUFFIX="_cropped"
DIR="$SCRIPT_DIR/src"
OUT_DIR="$SCRIPT_DIR/output"
CROP="${CROP_W}x${CROP_H}+${CROP_X}+${CROP_Y}"

# --measure モード: サイズ確認のみ
if [[ "${1:-}" == "--measure" ]]; then
    f=$(find "$DIR" -type f \( -name "*.png" -o -name "*.PNG" \) | head -1)
    [[ -z "$f" ]] && { echo "PNG が見つかりません: $DIR"; exit 1; }
    size=$(magick identify -format '%wx%h' "$f")
    echo "ファイル: $(basename "$f")"
    echo "サイズ:   $size"
    echo ""
    echo "次のコマンドでクロップ範囲を視覚的に確認できます:"
    echo "  magick \"$f\" -fill none -stroke red -strokewidth 4 \\"
    echo "    -draw \"rectangle ${CROP_X},${CROP_Y} $((CROP_X+CROP_W)),$((CROP_Y+CROP_H))\" \\"
    echo "    /tmp/preview.png && open /tmp/preview.png"
    exit 0
fi

echo "📐 クロップ設定: $CROP"
echo ""

count=0
skip=0

while IFS= read -r -d '' f; do
    base="${f%.*}"
    # すでにトリミング済みはスキップ
    if [[ "$base" == *"$SUFFIX" ]]; then
        echo "⏭  スキップ: $(basename "$f")"
        ((skip++)) || true
        continue
    fi
    ext="${f##*.}"
    rel="${f#$DIR/}"
    out="$OUT_DIR/${rel%.*}${SUFFIX}.${ext}"
    mkdir -p "$(dirname "$out")"
    magick "$f" -crop "$CROP" +repage "$out"
    echo "✅ ${rel} → output/${rel%.*}${SUFFIX}.${ext}"
    ((count++)) || true
done < <(find "$DIR" -type f \( -name "*.png" -o -name "*.PNG" \) -print0)

if [[ $count -eq 0 && $skip -eq 0 ]]; then
    echo "PNG ファイルが見つかりません: $DIR"
    exit 1
fi

echo ""
echo "完了: ${count} ファイル処理, ${skip} ファイルスキップ"
