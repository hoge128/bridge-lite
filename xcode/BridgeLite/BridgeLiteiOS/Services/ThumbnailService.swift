import CoreGraphics
import ImageIO
import Foundation

enum ThumbnailService {
    private static let targetPixels = 480
    private static let minCachePixels = 280

    static func generate(for entry: PhotoEntry, db: BridgeCoreDatabase, phashPipeline: PHashPipeline? = nil) async -> Data? {
        return await Task.detached(priority: .utility) {
            // 1. ImageIO (JPEG/HEIF/DNG/TIFF) — proprietary RAW はスキップ
            if let img = generateWithImageIO(url: entry.url, maxPixels: targetPixels),
               let jpeg = img.toJpeg() {
                Task { await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db) }
                if let pipeline = phashPipeline {
                    await pipeline.enqueue(entry: entry, source: img, db: db)
                }
                return jpeg
            }

            // 2. RAW: 埋め込み JPEG を抽出してスケール
            if entry.isRaw,
               let rawJpeg = await BridgeCore.extractRawJpeg(url: entry.url, quality: .preview),
               let rawImg = cgImage(from: rawJpeg) {
                let scaled = rawImg.scaledToFit(maxPixels: targetPixels) ?? rawImg
                guard let jpeg = scaled.toJpeg() else { return nil }
                Task { await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db) }
                if let pipeline = phashPipeline {
                    await pipeline.enqueue(entry: entry, source: scaled, db: db)
                }
                return jpeg
            }
            return nil
        }.value
    }

    private static func generateWithImageIO(url: URL, maxPixels: Int) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        let proprietaryRaw = Set(["arw","cr2","cr3","nef","nrw","rw2","orf","pef","raf"])
        if proprietaryRaw.contains(ext) { return nil }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard var thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        if max(thumb.width, thumb.height) < minCachePixels {
            let always: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            if let fresh = CGImageSourceCreateThumbnailAtIndex(src, 0, always as CFDictionary) {
                thumb = fresh
            }
        }
        return thumb
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

private extension CGImage {
    func toJpeg(quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func scaledToFit(maxPixels: Int) -> CGImage? {
        let w = width, h = height
        guard w > maxPixels || h > maxPixels else { return self }
        let scale = CGFloat(maxPixels) / CGFloat(max(w, h))
        let nw = max(1, Int(CGFloat(w) * scale))
        let nh = max(1, Int(CGFloat(h) * scale))
        let cs = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
