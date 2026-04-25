import CoreGraphics
import Foundation

actor PHashPipeline {
    private let limiter = ConcurrencyLimiter(maxConcurrent: 4)

    func enqueue(entry: PhotoEntry, source: CGImage, db: BridgeCoreDatabase) {
        Task {
            try? await limiter.run {
                guard let luma = source.toLuma32x32() else { return }
                let hash = await BridgeCore.computePHash(luma: luma)
                await BridgeCore.storeCachedPhash(url: entry.url, phash: hash, db: db)
            }
        }
    }
}

extension CGImage {
    func toLuma32x32() -> Data? {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Data(pixels)
    }
}
