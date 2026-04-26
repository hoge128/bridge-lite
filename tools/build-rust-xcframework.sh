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

# ── 8. Patch generated Swift files for Swift 6 / Xcode 26 compatibility ──────
# swift-bridge 0.1.59 does not fully support Swift 6's stricter type system.
# These sed patches fix two known issues:
#   (a) ToRustStr.toRustStr must be rethrows so throwing closures can be passed
#   (b) BridgeFfiError hierarchy needs Swift.Error + @unchecked Sendable
# Remove this section once swift-bridge adds Swift 6 support.
echo "  Applying Swift 6 compatibility patches …"
SWIFTCORE="$GENERATED_DIR/SwiftBridgeCore.swift"
BRIDGEFFI="$GENERATED_DIR/bridge-ffi.swift"

# SwiftBridgeCore.swift: make ToRustStr rethrows throughout
sed -i '' 's/(RustStr) -> T) -> T/(RustStr) throws -> T) rethrows -> T/g'            "$SWIFTCORE"
sed -i '' 's/return self\.utf8CString\.withUnsafeBufferPointer/return try self.utf8CString.withUnsafeBufferPointer/' "$SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(rustStr)/return try withUnsafeRustStr(rustStr)/' "$SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(self)/return try withUnsafeRustStr(self)/'       "$SWIFTCORE"
sed -i '' 's/return val\.toRustStr(withUnsafeRustStr)/return try val.toRustStr(withUnsafeRustStr)/' "$SWIFTCORE"
sed -i '' 's/return withUnsafeRustStr(RustStr(start: nil, len: 0))/return try withUnsafeRustStr(RustStr(start: nil, len: 0))/' "$SWIFTCORE"

# bridge-ffi.swift: add try to bridge_open_database + fix BridgeFfiError conformances
sed -i '' 's/return db_path\.toRustStr/return try db_path.toRustStr/'                 "$BRIDGEFFI"
sed -i '' 's/public class BridgeFfiError: BridgeFfiErrorRefMut {/public class BridgeFfiError: BridgeFfiErrorRefMut, Swift.Error, @unchecked Sendable {/' "$BRIDGEFFI"
sed -i '' 's/public class BridgeFfiErrorRefMut: BridgeFfiErrorRef {/public class BridgeFfiErrorRefMut: BridgeFfiErrorRef, @unchecked Sendable {/' "$BRIDGEFFI"
sed -i '' 's/public class BridgeFfiErrorRef {/public class BridgeFfiErrorRef: @unchecked Sendable {/' "$BRIDGEFFI"

echo ""
echo "✅ Done. Files written to: $GENERATED_DIR"
echo ""
echo "Next steps:"
echo "  1. cd xcode/BridgeLite && xcodegen generate"
echo "  2. Open BridgeLite.xcodeproj in Xcode"
echo "  3. Build and run (Cmd+R)"
