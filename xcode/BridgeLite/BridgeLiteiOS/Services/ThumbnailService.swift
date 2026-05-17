import CoreGraphics
import ImageIO
import UIKit
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

            // 2. RAW: 埋め込み JPEG を抽出 → スケール → RAW 本体の向きを適用
            // 埋め込み JPEG は orientation タグを持たないため RAW ファイルから直接読む
            if entry.isRaw,
               let rawJpeg = await BridgeCore.extractRawJpeg(url: entry.url, quality: .preview),
               let rawImg = cgImageThumbnail(from: rawJpeg, maxPixels: targetPixels) {
                let orient = readRawOrientation(url: entry.url)
                let oriented = orientedCGImage(rawImg, orientation: orient) ?? rawImg
                guard let jpeg = oriented.toJpeg() else { return nil }
                Task { await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db) }
                if let pipeline = phashPipeline {
                    await pipeline.enqueue(entry: entry, source: oriented, db: db)
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

    private static func cgImageThumbnail(from data: Data, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// RAW ファイルの TIFF IFD から orientation を読む（メタデータのみ・ピクセル非デコード）
    static func readRawOrientation(url: URL) -> CGImagePropertyOrientation {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return .up }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFOrientation] as? UInt32,
           let orient = CGImagePropertyOrientation(rawValue: raw) { return orient }
        if let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let orient = CGImagePropertyOrientation(rawValue: raw) { return orient }
        return .up
    }

    /// CGImagePropertyOrientation → UIImage.Orientation 変換
    static func uiImageOrientation(from o: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch o {
        case .up:           return .up
        case .upMirrored:   return .upMirrored
        case .down:         return .down
        case .downMirrored: return .downMirrored
        case .left:         return .left
        case .leftMirrored: return .leftMirrored
        case .right:        return .right
        case .rightMirrored: return .rightMirrored
        }
    }

    /// orientation をピクセルに bake した CGImage を返す（キャッシュ保存用）
    private static func orientedCGImage(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let uiOrient = uiImageOrientation(from: orientation)
        let src = UIImage(cgImage: image, scale: 1.0, orientation: uiOrient)
        let renderer = UIGraphicsImageRenderer(size: src.size)
        return renderer.image { _ in src.draw(at: .zero) }.cgImage
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
