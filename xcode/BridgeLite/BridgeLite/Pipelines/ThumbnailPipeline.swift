import CoreGraphics
import ImageIO
import Foundation

/// Thumbnail generation pipeline.
/// Writes results directly to LibraryStore.thumbnailImages on the MainActor
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

    private static func loadOne(
        entry: PhotoEntry,
        store: LibraryStore,
        db: BridgeCoreDatabase,
        phashPipeline: PHashPipeline
    ) async {
        try? await limiter.run {
            // 1. SQLite thumbnail cache — pHash already in DB from prior scan
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
                await phashPipeline.enqueue(entry: entry, source: img, db: db)
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
                await phashPipeline.enqueue(entry: entry, source: img, db: db)
            }
        }
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
