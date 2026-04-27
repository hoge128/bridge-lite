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

# Copy src → dst only when content differs, preserving mtime on cache hits.
# This prevents Xcode from re-linking/re-compiling unchanged artifacts.
cp_if_changed() {
    local src="$1" dst="$2"
    if cmp -s "$src" "$dst" 2>/dev/null; then
        echo "  (cached)  $(basename "$dst")"
    else
        cp "$src" "$dst"
        echo "  (updated) $(basename "$dst")"
    fi
}

# ── 1. Ensure Rust target is installed ────────────────────────────────────────
if ! rustup target list --installed | grep -q "$TARGET"; then
    echo "  Adding rustup target $TARGET …"
    rustup target add "$TARGET"
fi

# ── 2. Build bridge-ffi ───────────────────────────────────────────────────────
echo "  Compiling bridge-ffi …"
cd "$REPO_ROOT"
# Match Xcode project deployment target so libbridge_ffi.a and the Swift app
# are linked at the same macOS version (avoids 127 "built for newer macOS" warnings).
export MACOSX_DEPLOYMENT_TARGET="26.0"
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

# ── 4. Copy static library (skip if unchanged) ────────────────────────────────
cp_if_changed "$LIB_SRC" "$GENERATED_DIR/lib/libbridge_ffi.a"

# ── 5. Copy C headers (skip if unchanged) ─────────────────────────────────────
cp_if_changed "$CRATE_DIR/generated/SwiftBridgeCore.h"        "$GENERATED_DIR/include/SwiftBridgeCore.h"
cp_if_changed "$CRATE_DIR/generated/bridge-ffi/bridge-ffi.h"  "$GENERATED_DIR/include/bridge-ffi.h"

# ── 6. Write module.modulemap (skip if unchanged) ─────────────────────────────
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

# ── 7 & 8. Patch Swift files and copy only if result differs ──────────────────
# swift-bridge 0.1.59 does not fully support Swift 6's stricter type system.
# These sed patches fix two known issues:
#   (a) ToRustStr.toRustStr must be rethrows so throwing closures can be passed
#   (b) BridgeFfiError hierarchy needs Swift.Error + @unchecked Sendable
# Remove this section once swift-bridge adds Swift 6 support.
echo "  Checking Swift 6 compatibility patches …"

patch_swift_if_changed() {
    local src="$1" dst="$2"
    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"

    # Apply all patches to the temp copy
    shift 2
    while [ $# -ge 2 ]; do
        sed -i '' "s/$1/$2/g" "$tmp"
        shift 2
    done

    if cmp -s "$tmp" "$dst" 2>/dev/null; then
        echo "  (cached)  $(basename "$dst")"
        rm "$tmp"
    else
        mv "$tmp" "$dst"
        echo "  (updated) $(basename "$dst")"
    fi
}

# SwiftBridgeCore.swift patches
TMP_SWIFTCORE=$(mktemp)
cp "$CRATE_DIR/generated/SwiftBridgeCore.swift" "$TMP_SWIFTCORE"
sed -i '' 's/(RustStr) -> T) -> T/(RustStr) throws -> T) rethrows -> T/g'            "$TMP_SWIFTCORE"
sed -i '' 's/return self\.utf8CString\.withUnsafeBufferPointer/return try self.utf8CString.withUnsafeBufferPointer/' "$TMP_SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(rustStr)/return try withUnsafeRustStr(rustStr)/' "$TMP_SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(self)/return try withUnsafeRustStr(self)/'       "$TMP_SWIFTCORE"
sed -i '' 's/return val\.toRustStr(withUnsafeRustStr)/return try val.toRustStr(withUnsafeRustStr)/' "$TMP_SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(RustStr(start: nil, len: 0))/return try withUnsafeRustStr(RustStr(start: nil, len: 0))/' "$TMP_SWIFTCORE"
if cmp -s "$TMP_SWIFTCORE" "$GENERATED_DIR/SwiftBridgeCore.swift" 2>/dev/null; then
    echo "  (cached)  SwiftBridgeCore.swift"
    rm "$TMP_SWIFTCORE"
else
    mv "$TMP_SWIFTCORE" "$GENERATED_DIR/SwiftBridgeCore.swift"
    echo "  (updated) SwiftBridgeCore.swift"
fi

# bridge-ffi.swift patches
TMP_BRIDGEFFI=$(mktemp)
cp "$CRATE_DIR/generated/bridge-ffi/bridge-ffi.swift" "$TMP_BRIDGEFFI"
sed -i '' 's/return db_path\.toRustStr/return try db_path.toRustStr/'                 "$TMP_BRIDGEFFI"
sed -i '' 's/public class BridgeFfiError: BridgeFfiErrorRefMut {/public class BridgeFfiError: BridgeFfiErrorRefMut, Swift.Error, @unchecked Sendable {/' "$TMP_BRIDGEFFI"
sed -i '' 's/public class BridgeFfiErrorRefMut: BridgeFfiErrorRef {/public class BridgeFfiErrorRefMut: BridgeFfiErrorRef, @unchecked Sendable {/' "$TMP_BRIDGEFFI"
sed -i '' 's/public class BridgeFfiErrorRef {/public class BridgeFfiErrorRef: @unchecked Sendable {/' "$TMP_BRIDGEFFI"
if cmp -s "$TMP_BRIDGEFFI" "$GENERATED_DIR/bridge-ffi.swift" 2>/dev/null; then
    echo "  (cached)  bridge-ffi.swift"
    rm "$TMP_BRIDGEFFI"
else
    mv "$TMP_BRIDGEFFI" "$GENERATED_DIR/bridge-ffi.swift"
    echo "  (updated) bridge-ffi.swift"
fi

echo ""
echo "✅ Done. Files written to: $GENERATED_DIR"
echo ""
echo "Next steps:"
echo "  1. cd xcode/BridgeLite && xcodegen generate"
echo "  2. Open BridgeLite.xcodeproj in Xcode"
echo "  3. Build and run (Cmd+R)"
