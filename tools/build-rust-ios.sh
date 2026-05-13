#!/bin/bash
# Build the Rust bridge-ffi static library for iOS (device + simulator).
#
# Output:
#   xcode/BridgeLite/Generated/lib-ios/libbridge_ffi.a      — iOS device (arm64)
#   xcode/BridgeLite/Generated/lib-ios-sim/libbridge_ffi.a  — iOS simulator (arm64)
#   xcode/BridgeLite/Generated/include/*.h                  — shared C headers (same as macOS)
#
# Run this after build-rust-xcframework.sh (macOS) to add iOS slices.
# Usage:
#   ./tools/build-rust-ios.sh [--release]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$REPO_ROOT/crates/bridge-ffi"
GENERATED_DIR="$REPO_ROOT/xcode/BridgeLite/Generated"
PROFILE="debug"

for arg in "$@"; do
    case "$arg" in
        --release) PROFILE="release" ;;
    esac
done

TARGET_DEVICE="aarch64-apple-ios"
TARGET_SIM="aarch64-apple-ios-sim"

echo "▶ build-rust-ios.sh  profile=$PROFILE"

cp_if_changed() {
    local src="$1" dst="$2"
    if cmp -s "$src" "$dst" 2>/dev/null; then
        echo "  (cached)  $(basename "$dst")"
    else
        cp "$src" "$dst"
        echo "  (updated) $(basename "$dst")"
    fi
}

# ── 1. Ensure Rust targets are installed ──────────────────────────────────────
for t in "$TARGET_DEVICE" "$TARGET_SIM"; do
    if ! rustup target list --installed | grep -q "$t"; then
        echo "  Adding rustup target $t …"
        rustup target add "$t"
    fi
done

# ── 2. Build for iOS device ───────────────────────────────────────────────────
echo "  Compiling bridge-ffi for $TARGET_DEVICE …"
cd "$REPO_ROOT"
export IPHONEOS_DEPLOYMENT_TARGET="18.0"
unset MACOSX_DEPLOYMENT_TARGET
if [ "$PROFILE" = "release" ]; then
    cargo build -p bridge-ffi --release --target "$TARGET_DEVICE"
    LIB_DEVICE="$REPO_ROOT/target/$TARGET_DEVICE/release/libbridge_ffi.a"
else
    cargo build -p bridge-ffi --target "$TARGET_DEVICE"
    LIB_DEVICE="$REPO_ROOT/target/$TARGET_DEVICE/debug/libbridge_ffi.a"
fi

# ── 3. Build for iOS simulator ────────────────────────────────────────────────
echo "  Compiling bridge-ffi for $TARGET_SIM …"
if [ "$PROFILE" = "release" ]; then
    cargo build -p bridge-ffi --release --target "$TARGET_SIM"
    LIB_SIM="$REPO_ROOT/target/$TARGET_SIM/release/libbridge_ffi.a"
else
    cargo build -p bridge-ffi --target "$TARGET_SIM"
    LIB_SIM="$REPO_ROOT/target/$TARGET_SIM/debug/libbridge_ffi.a"
fi

# ── 4. Prepare output directories ─────────────────────────────────────────────
mkdir -p "$GENERATED_DIR/lib-ios"
mkdir -p "$GENERATED_DIR/lib-ios-sim"
mkdir -p "$GENERATED_DIR/include"

# ── 5. Copy static libraries ──────────────────────────────────────────────────
cp_if_changed "$LIB_DEVICE" "$GENERATED_DIR/lib-ios/libbridge_ffi.a"
cp_if_changed "$LIB_SIM"    "$GENERATED_DIR/lib-ios-sim/libbridge_ffi.a"

# ── 6. Copy C headers (shared with macOS, same content) ───────────────────────
cp_if_changed "$CRATE_DIR/generated/SwiftBridgeCore.h"        "$GENERATED_DIR/include/SwiftBridgeCore.h"
cp_if_changed "$CRATE_DIR/generated/bridge-ffi/bridge-ffi.h"  "$GENERATED_DIR/include/bridge-ffi.h"

# ── 7. Write module.modulemap ─────────────────────────────────────────────────
MODULEMAP_CONTENT='module RustCore {
    header "SwiftBridgeCore.h"
    header "bridge-ffi.h"
    export *
}'
MODULEMAP_DST="$GENERATED_DIR/include/module.modulemap"
if ! echo "$MODULEMAP_CONTENT" | cmp -s - "$MODULEMAP_DST" 2>/dev/null; then
    echo "$MODULEMAP_CONTENT" > "$MODULEMAP_DST"
    echo "  (updated) module.modulemap"
else
    echo "  (cached)  module.modulemap"
fi

echo ""
echo "✅ Done. iOS libs written to: $GENERATED_DIR/lib-ios[[-sim]]"
echo ""
echo "Next steps:"
echo "  1. cd xcode/BridgeLite && xcodegen generate"
echo "  2. Open BridgeLite.xcodeproj in Xcode"
echo "  3. Select BridgeLiteiOS scheme + iPhone 16 Pro target"
