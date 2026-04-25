#!/bin/bash
# Build the Rust bridge-ffi static library and prepare it for Xcode.
#
# Output:
#   xcode/BridgeLite/Generated/lib/libbridge_ffi.a   — static library
#   xcode/BridgeLite/Generated/include/*.h           — C headers
#   xcode/BridgeLite/Generated/include/module.modulemap
#   xcode/BridgeLite/Generated/SwiftBridgeCore.swift  — swift-bridge runtime
#   xcode/BridgeLite/Generated/bridge-ffi.swift       — generated API bindings
#
# Usage:
#   ./tools/build-rust-xcframework.sh [--release]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/crates/bridge-ffi"
GENERATED_DIR="$REPO_ROOT/xcode/BridgeLite/Generated"
TARGET="aarch64-apple-darwin"
PROFILE="debug"

for arg in "$@"; do
    case "$arg" in
        --release) PROFILE="release" ;;
    esac
done

echo "▶ build-rust-xcframework.sh  profile=$PROFILE  target=$TARGET"

# ── 1. Ensure Rust target is installed ────────────────────────────────────────
if ! rustup target list --installed | grep -q "$TARGET"; then
    echo "  Adding rustup target $TARGET …"
    rustup target add "$TARGET"
fi

# ── 2. Build bridge-ffi ───────────────────────────────────────────────────────
echo "  Compiling bridge-ffi …"
cd "$REPO_ROOT"
if [ "$PROFILE" = "release" ]; then
    cargo build -p bridge-ffi --release --target "$TARGET"
    LIB_SRC="$REPO_ROOT/target/$TARGET/release/libbridge_ffi.a"
else
    cargo build -p bridge-ffi --target "$TARGET"
    LIB_SRC="$REPO_ROOT/target/$TARGET/debug/libbridge_ffi.a"
fi

# ── 3. Prepare output directories ─────────────────────────────────────────────
mkdir -p "$GENERATED_DIR/lib"
mkdir -p "$GENERATED_DIR/include"

# ── 4. Copy static library ────────────────────────────────────────────────────
echo "  Copying libbridge_ffi.a …"
cp "$LIB_SRC" "$GENERATED_DIR/lib/libbridge_ffi.a"

# ── 5. Copy C headers ─────────────────────────────────────────────────────────
echo "  Copying C headers …"
cp "$CRATE_DIR/generated/SwiftBridgeCore.h"        "$GENERATED_DIR/include/"
cp "$CRATE_DIR/generated/bridge-ffi/bridge-ffi.h"  "$GENERATED_DIR/include/"

# ── 6. Write module.modulemap ─────────────────────────────────────────────────
cat > "$GENERATED_DIR/include/module.modulemap" << 'MODULEMAP'
module RustCore {
    header "SwiftBridgeCore.h"
    header "bridge-ffi.h"
    export *
}
MODULEMAP

# ── 7. Copy generated Swift files ─────────────────────────────────────────────
echo "  Copying generated Swift bindings …"
cp "$CRATE_DIR/generated/SwiftBridgeCore.swift"        "$GENERATED_DIR/SwiftBridgeCore.swift"
cp "$CRATE_DIR/generated/bridge-ffi/bridge-ffi.swift"  "$GENERATED_DIR/bridge-ffi.swift"

echo ""
echo "✅ Done. Files written to: $GENERATED_DIR"
echo ""
echo "Next steps:"
echo "  1. cd xcode/BridgeLite && xcodegen generate"
echo "  2. Open BridgeLite.xcodeproj in Xcode"
echo "  3. Build and run (Cmd+R)"
