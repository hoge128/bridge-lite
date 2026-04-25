#!/bin/bash
# tools/build-rust-xcframework.sh
# bridge-ffi を XCFramework としてビルドするスクリプト
# Phase C で実装予定

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/target"
XCODE_DIR="$REPO_ROOT/xcode/BridgeLite"

echo "Building bridge-ffi for aarch64-apple-darwin..."
cargo build --release --package bridge-ffi --target aarch64-apple-darwin

echo "TODO: xcframework 化は Phase C で実装"
