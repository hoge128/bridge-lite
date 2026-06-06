import CoreGraphics
import Foundation

/// LRU cache for decoded CGImages backed by NSCache so the OS can evict entries
/// under memory pressure. Only off-screen (destroyed) cells benefit from the
/// cache; visible cells hold their own strong reference via @State.
///
/// Keys are file URLs so the cache is safe across multiple windows / folders
/// (PhotoEntry.id is a per-scan sequential index and collides between stores).
final class ThumbnailDecodeCache: @unchecked Sendable {
    static let shared = ThumbnailDecodeCache()
    private let cache = NSCache<NSString, CGImage>()
    private let memoryPressureSource: DispatchSourceMemoryPressure
    private var baseLimitBytes: Int

    private init() {
        let stored = UserDefaults.standard.integer(forKey: "thumbnailCacheMB")
        // 512MB デフォルト。キャッシュに入るのはビットマップ実体（IOSurface backed ではない）
        // ので、上限を上げても効くのは常駐 RAM だけ。かつて 50 枚止まりを起こした IOSurface
        // 枯渇はデコード/RAW 現像の並列度側で制御済みで、キャッシュサイズとは無関係。
        // 経緯: knowledge/thumbnail-cache-iosurface.md
        let maxMB = Int(ProcessInfo.processInfo.physicalMemory / 10 / (1024 * 1024))
        let mb = stored >= 100 ? min(stored, maxMB) : min(512, maxMB)
        let limit = mb * 1024 * 1024
        baseLimitBytes = limit
        cache.totalCostLimit = limit

        // メモリ圧迫時に自動回収する。warning で半減、critical で全消去、normal で上限復元。
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.all],
            queue: .main
        )
        memoryPressureSource = src
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.critical) {
                self.cache.removeAllObjects()
                self.cache.totalCostLimit = 50 * 1024 * 1024
            } else if event.contains(.warning) {
                let halved = max(50 * 1024 * 1024, self.baseLimitBytes / 2)
                self.cache.totalCostLimit = halved
            } else if event.contains(.normal) {
                self.cache.totalCostLimit = self.baseLimitBytes
            }
        }
        src.resume()
    }

    @MainActor func updateLimit(mb: Int) {
        baseLimitBytes = mb * 1024 * 1024
        cache.totalCostLimit = baseLimitBytes
    }

    func peek(url: URL) -> CGImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func decode(url: URL, blob: Data?) -> CGImage? {
        guard let blob else { return nil }
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let img = CGImage.fromJPEGData(blob) else { return nil }
        cache.setObject(img, forKey: key, cost: img.bytesPerRow * img.height)
        return img
    }

    func store(url: URL, image: CGImage) {
        let key = url.absoluteString as NSString
        guard cache.object(forKey: key) == nil else { return }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
    }

    func evict(url: URL) {
        cache.removeObject(forKey: url.absoluteString as NSString)
    }

    /// 自 store が保有していた URL 群だけを evict する（他ウィンドウへの波及を避ける）。
    func evict(urls: [URL]) {
        for url in urls {
            cache.removeObject(forKey: url.absoluteString as NSString)
        }
    }
}
