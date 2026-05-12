import CoreGraphics
import ImageIO
import Foundation
import SwiftUI

/// Thumbnail generation pipeline.
/// Writes JPEG blobs to LibraryStore.thumbnailBlobs on the MainActor
/// so the grid updates reactively as each thumbnail finishes.
enum ThumbnailPipeline {
    // IOSurface 枯渇（kIOReturnNoMemory）対策として上限を設ける。
    // 通常: 2 並列 / Burst Mode: 4 並列。loadAll 開始時に BridgeQoS.thumbnailConcurrency で更新される。
    private static let limiter = ConcurrencyLimiter(maxConcurrent: 2)

    /// Fire-and-forget: load all thumbnails, updating store as each one completes.
    /// Also enqueues pHash computation for newly generated thumbnails so that
    /// shot-group reindexing has the hash data it needs.
    static func loadAll(
        entries: [PhotoEntry],
        store: LibraryStore,
        db: BridgeCoreDatabase,
        phashPipeline: PHashPipeline,
        generation: Int,
        imageList: BridgeCoreImageList? = nil
    ) async {
        // Burst Mode の並列数をスキャン開始時に反映する。
        await limiter.updateMax(BridgeQoS.thumbnailConcurrency)
        await PHashPipeline.applyBurstMode()

        // Pre-fetch all thumbnails in one SQLite connection to avoid per-entry connection overhead.
        let prefetched: [URL: Data]
        if let list = imageList {
            prefetched = await BridgeCore.fetchCachedThumbnailBatch(list: list, db: db)
        } else {
            prefetched = [:]
        }

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                let cached = prefetched[entry.url]
                group.addTask {
                    await loadOne(entry: entry, store: store, db: db,
                                  phashPipeline: phashPipeline, generation: generation,
                                  prefetchedJpeg: cached)
                }
            }
        }
    }

    // Thumbnail target size: 480px。
    // 既定スライダー位置 (~120pt) では Retina 2× = 240px で十分 sharp。
    // スライダー max (360pt) では多少眠くなるが、NSCache (150MB) に
    // 〜166 枚乗るためスクロールのキャッシュフィット率が 720px 比 2.2 倍になる。
    // スキャン中の ImageIO デコード時間も短縮され、大規模フォルダで MainActor の
    // 圧迫を抑える効果が大きい。720px に戻す場合はここを書き換えるだけでよい。
    private static let targetPixels = 480
    // Cached thumbnails below this size are too small and get regenerated.
    // 480 ターゲットに合わせて 280 まで許容（既存 480/720 キャッシュは保持、
    // 200/360 等の旧キャッシュは再生成）。
    private static let minCachePixels = 280

    private static func loadOne(
        entry: PhotoEntry,
        store: LibraryStore,
        db: BridgeCoreDatabase,
        phashPipeline: PHashPipeline,
        generation: Int,
        prefetchedJpeg: Data? = nil
    ) async {
        // stale 世代は limiter slot を奪わずに即 exit（新世代の loadAll を妨げない）
        let isStale = await MainActor.run { store.scanGeneration != generation }
        guard !isStale else { return }
        try? await limiter.run {
            // slot 取得後にも再チェック（待機中に reset() が走ることがある）
            let stale = await MainActor.run { store.scanGeneration != generation }
            guard !stale else { return }
            // 1. SQLite thumbnail cache — use pre-fetched data or fall back to individual fetch
            // Note: ?? cannot be used with await (autoclosure limitation), so use explicit if-else.
            let cachedJpeg: Data?
            if let pre = prefetchedJpeg {
                cachedJpeg = pre
            } else {
                cachedJpeg = await BridgeCore.fetchCachedThumbnail(url: entry.url, db: db)
            }
            if let jpeg = cachedJpeg {
                let cached = CGImage.fromJPEGData(jpeg)
                let isAdequate = cached.map { max($0.width, $0.height) >= minCachePixels } ?? false
                // カメラ固有の黒帯入り EXIF サムネがキャッシュされている場合は再生成する
                let hasBadAspect: Bool = {
                    guard isAdequate,
                          let img = cached,
                          let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                          let masterAspect = inspectMasterAspect(src), masterAspect > 0 else { return false }
                    let cacheAspect = CGFloat(img.width) / CGFloat(img.height)
                    return abs(cacheAspect - masterAspect) / masterAspect > 0.02
                }()
                if isAdequate && !hasBadAspect {
                    await store.setThumbnail(id: entry.id, jpeg: jpeg, generation: generation)
                    if entry.isRaw {
                        let url = entry.url
                        let orient = await Task.detached(priority: .utility) {
                            readRawOrientation(url)
                        }.value
                        await store.setThumbnailOrientation(id: entry.id, orientation: orient, generation: generation)
                    }
                    return
                }
                // Cached thumbnail too small or has letterboxed black bars — fall through to regenerate
            }

            // 2. ImageIO for non-RAW (JPEG/HEIF/DNG/TIFF)
            if let img = await generateWithImageIO(url: entry.url, maxPixels: targetPixels),
               let jpeg = img.jpegData(compressionQuality: 0.85) {
                await store.setThumbnail(id: entry.id, jpeg: jpeg, generation: generation)
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
                await store.setThumbnail(id: entry.id, jpeg: jpeg, generation: generation)
                await store.setThumbnailOrientation(id: entry.id, orientation: orient, generation: generation)
                await BridgeCore.storeCachedThumbnail(url: entry.url, data: jpeg, db: db)
                await phashPipeline.enqueue(entry: entry, source: scaled, db: db)
            }
        }
        // 成功・失敗・スキップに関わらず試行完了を通知（進捗バーが 99% 止まりになるのを防ぐ）
        await store.noteThumbnailAttemptFinished(generation: generation)
    }

    static func generateWithImageIO(url: URL, maxPixels: Int) async -> CGImage? {
        return await Task.detached(priority: BridgeQoS.thumbnail) {
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
            guard var thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            // 埋め込みサムネイルのアスペクト比がマスターと 2% 以上乖離している場合
            // （カメラが 4:3 黒帯サムネイルを埋め込む SOOC JPG 等）、マスターから再生成する。
            if let masterAspect = inspectMasterAspect(src), masterAspect > 0 {
                let thumbAspect = CGFloat(thumb.width) / CGFloat(thumb.height)
                if abs(thumbAspect - masterAspect) / masterAspect > 0.02 {
                    let alwaysOptions: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCache: false,
                    ]
                    if let fresh = CGImageSourceCreateThumbnailAtIndex(src, 0, alwaysOptions as CFDictionary) {
                        thumb = fresh
                    }
                }
            }
            return thumb
        }.value
    }

    /// マスター画像の orientation 補正済みアスペクト比（W/H）を返す。decode は行わない。
    private static func inspectMasterAspect(_ src: CGImageSource) -> CGFloat? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let ph = props[kCGImagePropertyPixelHeight] as? CGFloat,
              ph > 0 else { return nil }
        let orient = readOrientation(src)
        let isTransposed = orient == .left || orient == .leftMirrored
                        || orient == .right || orient == .rightMirrored
        return isTransposed ? ph / pw : pw / ph
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
        // shouldCache: false で CGImage が IOSurface バックのデコード済みピクセルを
        // 抱え込まないようにする。SwiftUI Image は CALayer 側でテクスチャ化されるので
        // 体感性能は変わらず、IOSurface プールの逼迫だけを抑えられる。
        let opts: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
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
