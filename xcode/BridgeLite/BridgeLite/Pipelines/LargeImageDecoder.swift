import CoreGraphics
import ImageIO
import SwiftUI

/// Shared concurrency gate for full-resolution image decoding in Compare and Viewer.
/// Limits simultaneous CGImageSource decodes to 2 so that IOSurface allocations
/// never pile up across columns or rapid navigation.
enum LargeImageDecoder {
    // maxConcurrent: 1 — フルサイズ JPEG の HW デコードは一時 IOSurface を複数使うため、
    // 同時実行が 2 件でも IOSurface プール枯渇が起きる。1 件直列化で上限を守る。
    static let limiter = ConcurrencyLimiter(maxConcurrent: 1)

    /// Decode a full-resolution image from a file URL.
    static func decodeFromURL(_ url: URL) async -> (CGImage, Image.Orientation)? {
        try? await limiter.run {
            await Task.detached(priority: .userInitiated) {
                // shouldCache: false on both source and image creation prevents IOSurface from
                // being retained in the CGImageSource's internal cache after SwiftUI uploads to GPU.
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
                return (img, Image.Orientation(readOrientation(src)))
            }.value
        }
    }

    /// Decode a full-resolution image from pre-fetched embedded JPEG data.
    /// Orientation must be supplied by the caller (from LibraryStore.thumbnailOrientations)
    /// to avoid opening the RAW file a second time, which would allocate an extra IOSurface.
    static func decodeFromData(
        _ data: Data,
        orientation: Image.Orientation
    ) async -> (CGImage, Image.Orientation)? {
        try? await limiter.run {
            await Task.detached(priority: .userInitiated) {
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let jpegSrc = CGImageSourceCreateWithData(data as CFData, opts),
                      let img = CGImageSourceCreateImageAtIndex(jpegSrc, 0, opts) else { return nil }
                return (img, orientation)
            }.value
        }
    }
}
