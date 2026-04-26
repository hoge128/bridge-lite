SCHEME   := BridgeLite
PROJECT  := xcode/BridgeLite/BridgeLite.xcodeproj
CONFIG   := Debug

.PHONY: all build rust xcode generate test clean open

## デフォルト: Rust ライブラリ → Xcode ビルド
all: build

## Rust lib + Xcode app を一括ビルド
build: rust xcode

## Rust 静的ライブラリをビルド (release)
rust:
	./tools/build-rust-xcframework.sh --release

## Xcode プロジェクトを再生成 (project.yml 変更時)
generate:
	cd xcode/BridgeLite && xcodegen generate

## Xcode アプリをビルド
xcode:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination "platform=macOS,arch=arm64" build 2>&1 \
		| grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" \
		| grep -v "appintentsmetadataprocessor\|IDERunDestination"

## Rust テスト
test:
	cargo test -p bridge-core

## ビルド成果物を削除
clean:
	cargo clean
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=macOS,arch=arm64" clean -quiet

## Xcode で開く
open:
	open $(PROJECT)
