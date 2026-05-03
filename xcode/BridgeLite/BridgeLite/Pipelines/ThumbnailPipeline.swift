import CoreGraphics
import ImageIO
import Foundation
import SwiftUI

/// Thumbnail generation pipeline.
/// Writes JPEG blobs to LibraryStore.thumbnailBlobs on the MainActor
/// so the grid updates reactively as each thumbnail finishes.
enum ThumbnailPipeline {
    private static let limiter = ConcurrencyLimiter(maxConcurrent: 6)

    /// Fire-and-forget: load all thumbnails, updating store as each one completes.
    /// Also enqueues pHash computation for newly generated thumbnails so that
    /// shot-group reindexing has the hash data it needs.
    static func loadAll(
        entries: [PhotoEntry],
        store: LibraryStore,
        db: BridgeCoreDatabase,
        phashPipeline: PHashPipeline
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { await loadOne(entry: entry, store: store, db: db, phashPipeline: phashPipeline) }
            }
        }
    }

    // Thumbnail target size: 360pt (slider max) × 2x Retina = 720px
    private static let targetPixels = 720
    // Cached thumbnails below this size are too small for Retina and get regenerated
    private static let minCachePixels = 400

    private static func loadOne(
        entry: PhotoEntry,
        store: LibraryStore,
        db: BridgeCoreDatabase,
        phashPipeline: PHashPipeline
    ) async {
        try? await limiter.run {
            // 1. SQLite thumbnail cache — skip if too small for Retina (auto-migrate old 200px entries)
            if let jpeg = await BridgeCore.fetchCachedThumbnail(url: entry.url, db: db) {
                let isAdequate = CGImage.fromJPEGData(jpeg)
                    .map { max($0.width, $0.height) >= minCachePixels } ?? false
                if isAdequate {
                    await store.setThumbnail(id: entry.id, jpeg: jpeg)
                    if entry.isRaw {
                        let url = entry.url
                        let orient = await Task.detached(priority: .utility) {
                            readRawOrientation(url)
                        }.value
                        await store.setThumbnailOrientation(id: entry.id, orientation: orient)
                    }
                    return
                }
                // Cached thumbnail too small — fall through to regenerate at Retina resolution
            }

            // 2. ImageIO for non-RAW (JPEG/HEIF/DNG/TIFF)
            if let img = await generateWithImageIO(url: entry.url, maxPixels: targetPixels),
               let jpeg = img.jpegData(compressionQuality: 0.85) {
                await store.setThumbnail(id: entry.id, jpeg: jpeg)
                await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db)
                await phashPipeline.enqueue(entry: entry, source: img, db: db)
                return
            }

            // 3. RAW: extract preview JPEG from IFD, scale to targetPixels, re-encode for cache.
            //    Use .preview (mid-size IFD JPEG) instead of .thumbnail to ensure Retina sharpness.
            if entry.isRaw,
               let rawJpeg = await BridgeCore.extractRawJpeg(url: entry.url, quality: .preview),
               let rawImg = CGImage.fromJPEGData(rawJpeg) {
                let url = entry.url
                let orient = await Task.detached(priority: .utility) {
                    readRawOrientation(url)
                }.value
                let scaled = rawImg.scaledToFit(maxPixels: targetPixels) ?? rawImg
                guard let jpeg = scaled.jpegData(compressionQuality: 0.85) else { return }
                await store.setThumbnail(id: entry.id, jpeg: jpeg)
                await store.setThumbnailOrientation(id: entry.id, orientation: orient)
                await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db)
                await phashPipeline.enqueue(entry: entry, source: scaled, db: db)
            }
        }
        // Auto-render: fire-and-forget background replace for RAW thumbnails when enabled
        await store.autoRenderThumbnailIfNeeded(entry: entry, db: db)
        // 成功・失敗・スキップに関わらず試行完了を通知（進捗バーが 99% 止まりになるのを防ぐ）
        await store.noteThumbnailAttemptFinished()
    }

    static func generateWithImageIO(url: URL, maxPixels: Int) async -> CGImage? {
        return await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            // Skip proprietary RAW — ImageIO's RawCamera handler causes macOS 26 crashes.
            // DNG is TIFF-based and uses a separate stable handler, so it is kept enabled.
            let rawExts = Set(["arw","cr2","cr3","nef","nrw","rw2","orf","pef","raf"])
            if rawExts.contains(ext) { return nil }

            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        }.value
    }
}

// MARK: - Orientation helpers (shared with ViewerView / GroupCompareView)

/// RAW ファイル URL から向きを読む。プロパティのみ参照し、ピクセルデコードは行わない。
func readRawOrientation(_ url: URL) -> Image.Orientation {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .up }
    return Image.Orientation(readOrientation(src))
}

/// CGImageSource からフォーマット非依存で向きを取得する。
/// - JPEG/HEIF: トップレベルの kCGImagePropertyOrientation
/// - RAW/DNG/TIFF: kCGImagePropertyTIFFDictionary 内の kCGImagePropertyTIFFOrientation
func readOrientation(_ src: CGImageSource) -> CGImagePropertyOrientation {
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return .up }
    if let raw = props[kCGImagePropertyOrientation] as? UInt32,
       let o = CGImagePropertyOrientation(rawValue: raw) { return o }
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let raw = tiff[kCGImagePropertyTIFFOrientation] as? UInt32,
       let o = CGImagePropertyOrientation(rawValue: raw) { return o }
    return .up
}

extension Image.Orientation {
    init(_ cg: CGImagePropertyOrientation) {
        switch cg {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

extension CGImage {
    static func fromJPEGData(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func jpegData(compressionQuality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func scaledToFit(maxPixels: Int) -> CGImage? {
        let w = width, h = height
        guard w > maxPixels || h > maxPixels else { return self }
        let scale = CGFloat(maxPixels) / CGFloat(max(w, h))
        let newW = max(1, Int(CGFloat(w) * scale))
        let newH = max(1, Int(CGFloat(h) * scale))
        let cs = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}
