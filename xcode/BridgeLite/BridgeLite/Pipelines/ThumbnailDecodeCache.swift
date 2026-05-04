import CoreGraphics
import Foundation

/// LRU cache for decoded CGImages backed by NSCache so the OS can evict entries
/// under memory pressure. Only off-screen (destroyed) cells benefit from the
/// cache; visible cells hold their own strong reference via @State.
final class ThumbnailDecodeCache: @unchecked Sendable {
    static let shared = ThumbnailDecodeCache()
    private let cache = NSCache<NSNumber, CGImage>()
    private let memoryPressureSource: DispatchSourceMemoryPressure
    private let baseLimitBytes: Int

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "thumbnailCacheMB")
        // 150MB デフォルト。300MB だと IOSurface プールが逼迫する。
        let mb = stored >= 100 ? stored : 150
        let limit = mb * 1024 * 1024
        baseLimitBytes = limit
        cache.totalCostLimit = limit

        // メモリ圧迫時に自動回収する。warning で半減、critical で全消去。
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        memoryPressureSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.critical) {
                self.cache.removeAllObjects()
            } else if event.contains(.warning) {
                let halved = max(50 * 1024 * 1024, self.cache.totalCostLimit / 2)
                self.cache.totalCostLimit = halved
            }
        }
        src.resume()
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
