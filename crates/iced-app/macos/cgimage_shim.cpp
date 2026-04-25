// macOS 26 で ImageIO 内部の C++ throw を catch するための shim（防御層）。
//
// 注意: 主要なクラッシュ経路（RawCamera が dispatch_once ブロック内で throw する
// ケース）は、libdispatch が -fno-exceptions でビルドされ unwind テーブルを持たない
// ため、ここの catch(...) には到達できない。その対策は上位の Rust 側で行っている
// (src/macos_thumb.rs の is_camera_raw_format() でカメラ RAW を呼び出し前に弾く)。
//
// この shim は dispatch を経由しない別経路の throw に対する defense-in-depth として
// 残している。同じ catch パターンの前例は vendor/xmp_toolkit/src/ffi.cpp（コミット
// 8625d44）。

#include <ImageIO/ImageIO.h>
#include <cstdio>
#include <exception>

extern "C" CGImageRef bl_create_thumbnail_at_index(
    CGImageSourceRef src, size_t index, CFDictionaryRef options) {
    try {
        return CGImageSourceCreateThumbnailAtIndex(src, index, options);
    } catch (const std::exception& e) {
        fprintf(stderr, "bl_create_thumbnail_at_index: %s\n", e.what());
        return nullptr;
    } catch (...) {
        fprintf(stderr, "bl_create_thumbnail_at_index: unknown C++ exception\n");
        return nullptr;
    }
}

extern "C" CGImageRef bl_create_image_at_index(
    CGImageSourceRef src, size_t index, CFDictionaryRef options) {
    try {
        return CGImageSourceCreateImageAtIndex(src, index, options);
    } catch (const std::exception& e) {
        fprintf(stderr, "bl_create_image_at_index: %s\n", e.what());
        return nullptr;
    } catch (...) {
        fprintf(stderr, "bl_create_image_at_index: unknown C++ exception\n");
        return nullptr;
    }
}
