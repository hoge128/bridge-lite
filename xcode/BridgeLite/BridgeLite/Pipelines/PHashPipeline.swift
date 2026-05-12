import CoreGraphics
import Foundation

actor PHashPipeline {
    // static: マルチタブ時にウィンドウ数分の並列度が合算されないようアプリ全体で共有。
    // 通常: 2 並列 / Burst Mode: 4 並列。ThumbnailPipeline.loadAll の先頭で applyBurstMode() が呼ばれる。
    private static let limiter = ConcurrencyLimiter(maxConcurrent: 2)

    static func applyBurstMode() async {
        await limiter.updateMax(BridgeQoS.phashConcurrency)
    }
    private var pending: Int = 0
    private var doneWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(entry: PhotoEntry, source: CGImage, db: BridgeCoreDatabase) {
        pending += 1
        Task {
            try? await PHashPipeline.limiter.run {
                guard let luma = source.toLuma32x32() else { return }
                let hash = await BridgeCore.computePHash(luma: luma)
                await BridgeCore.storeCachedPhash(url: entry.url, phash: hash, db: db)
            }
            finishOne()
        }
    }

    private func finishOne() {
        pending -= 1
        if pending == 0 {
            let waiters = doneWaiters
            doneWaiters = []
            for w in waiters { w.resume() }
        }
    }

    func waitForAllPending() async {
        guard pending > 0 else { return }
        await withCheckedContinuation { doneWaiters.append($0) }
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
