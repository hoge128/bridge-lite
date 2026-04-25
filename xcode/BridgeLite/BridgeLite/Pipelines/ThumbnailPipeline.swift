import CoreGraphics
import ImageIO
import Foundation

/// Thumbnail generation pipeline.
/// Writes results directly to LibraryStore.thumbnailImages on the MainActor
/// so the grid updates reactively as each thumbnail finishes.
enum ThumbnailPipeline {
    private static let limiter = ConcurrencyLimiter(maxConcurrent: 6)

    /// Fire-and-forget: load all thumbnails, updating store as each one completes.
    static func loadAll(entries: [PhotoEntry], store: LibraryStore, db: BridgeCoreDatabase) async {
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { await loadOne(entry: entry, store: store, db: db) }
            }
        }
    }

    private static func loadOne(entry: PhotoEntry, store: LibraryStore, db: BridgeCoreDatabase) async {
        try? await limiter.run {
            // 1. SQLite thumbnail cache (Rust-managed)
            if let jpeg = await BridgeCore.fetchCachedThumbnail(url: entry.url, db: db),
               let img = CGImage.fromJPEGData(jpeg) {
                await store.setThumbnail(id: entry.id, image: img)
                return
            }

            // 2. ImageIO (skips RAW — handled by fallback below)
            if let img = await generateWithImageIO(url: entry.url, maxPixels: 200) {
                await store.setThumbnail(id: entry.id, image: img)
                if let jpeg = img.jpegData(compressionQuality: 0.85) {
                    await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db)
                }
                return
            }

            // 3. RAW: Rust IFD embedded JPEG extraction
            if entry.isRaw,
               let jpeg = await BridgeCore.extractRawJpeg(url: entry.url, quality: .thumbnail),
               let img = CGImage.fromJPEGData(jpeg) {
                await store.setThumbnail(id: entry.id, image: img)
                if let jpeg2 = img.jpegData(compressionQuality: 0.85) {
                    await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg2, db: db)
                }
            }
        }
    }

    static func generateWithImageIO(url: URL, maxPixels: Int) async -> CGImage? {
        return await Task.detached(priority: .userInitiated) {
            let ext = url.pathExtension.lowercased()
            // Skip RAW — ImageIO's RawCamera handler causes macOS 26 crashes
            let rawExts = Set(["arw","cr2","cr3","nef","nrw","rw2","orf","pef","raf","dng"])
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
}
