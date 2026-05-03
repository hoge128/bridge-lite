import CoreGraphics
import Foundation

/// LRU cache for decoded CGImages backed by NSCache so the OS can evict entries
/// under memory pressure. Only off-screen (destroyed) cells benefit from the
/// cache; visible cells hold their own strong reference via @State.
final class ThumbnailDecodeCache: @unchecked Sendable {
    static let shared = ThumbnailDecodeCache()
    private let cache = NSCache<NSNumber, CGImage>()

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "thumbnailCacheMB")
        let mb = stored >= 100 ? stored : 300
        cache.totalCostLimit = mb * 1024 * 1024
    }

    func updateLimit(mb: Int) {
        cache.totalCostLimit = mb * 1024 * 1024
    }

    func decode(id: UInt64, blob: Data?) -> CGImage? {
        guard let blob else { return nil }
        let key = NSNumber(value: id)
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = CGImage.fromJPEGData(blob) else { return nil }
        cache.setObject(img, forKey: key, cost: img.bytesPerRow * img.height)
        return img
    }

    func evict(id: UInt64) {
        cache.removeObject(forKey: NSNumber(value: id))
    }

    func evictAll() {
        cache.removeAllObjects()
    }
}
