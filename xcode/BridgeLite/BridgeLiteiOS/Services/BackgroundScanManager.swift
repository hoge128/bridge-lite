import UIKit
import BackgroundTasks
import CoreGraphics
import ImageIO

// BGProcessingTask は Objective-C クラスで Sendable 非準拠のため @unchecked で宣言する。
// MainActor 上でのみ使用するため実際の data race はない。
extension BGProcessingTask: @unchecked @retroactive Sendable {}

/// iOS バックグラウンド読み込み継続の 2 層制御:
///
/// Layer 1 – beginBackgroundTask: バックグラウンド移行時に ~30 秒の実行時間を延長。
///            既存の Swift Task / Rust Tokio スレッドがそのまま継続する。
/// Layer 2 – BGProcessingTask: 30 秒で終わらない大規模フォルダ用。
///            システムが条件良好時（アイドル・充電中）に起動して EXIF 索引とサムネイル生成を完了させる。
@MainActor
final class BackgroundScanManager {
    static let shared = BackgroundScanManager()
    static let taskIdentifier = "io.github.bridge-lite.ios.exifindex"

    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    // MARK: - Layer 1: beginBackgroundTask

    func beginExtendedTime() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "BridgeLiteExifIndex") { [weak self] in
            // 時間切れ: BGProcessingTask をスケジュールしてからタスクを終了する
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleTask()
                let id = self.bgTaskID
                UIApplication.shared.endBackgroundTask(id)
                self.bgTaskID = .invalid
            }
        }
    }

    func endExtendedTime() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - Layer 2: BGProcessingTask

    /// AppDelegate.didFinishLaunchingWithOptions から1回だけ呼ぶ。
    func registerHandler() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundScanManager.shared.performBackgroundIndex(processingTask)
            }
        }
    }

    func scheduleTask() {
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelScheduledTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    // MARK: - BGProcessingTask 実行本体

    private func performBackgroundIndex(_ bgTask: BGProcessingTask) {
        let dbURL = ScanStore.cacheDBURL()
        guard let url = BookmarkStore.restore() else {
            bgTask.setTaskCompleted(success: false)
            return
        }

        let workTask = Task.detached(priority: .utility) { () -> Bool in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                guard let db = try? BridgeCoreDatabase.open(path: dbURL) else { return false }
                guard !Task.isCancelled else { return false }
                let (entries, imageList, _, _) = try await BridgeCore.scanDirectory(url: url, db: db)
                guard !Task.isCancelled else { return false }
                await BridgeCore.indexNewEntries(list: imageList, db: db)
                guard !Task.isCancelled else { return false }
                await BackgroundThumbnailPipeline.generate(entries: entries, imageList: imageList, db: db)
                return !Task.isCancelled
            } catch {
                return false
            }
        }

        // expirationHandler: 時間切れ時に作業をキャンセルする（setTaskCompleted は workTask 側で呼ぶ）
        bgTask.expirationHandler = {
            workTask.cancel()
        }

        Task {
            let success = await workTask.value
            bgTask.setTaskCompleted(success: success)
        }
    }
}

// MARK: - Background Thumbnail Pipeline

/// @MainActor 非依存のサムネイル生成ヘルパー。
/// UIへの通知なしに SQLite へ直接キャッシュする。
/// LibraryStore を使わないため BGProcessingTask 内で安全に呼べる。
private enum BackgroundThumbnailPipeline {
    // IOSurface 枯渇対策として並列数を 2 に制限（ThumbnailPipeline.swift の通常モードと同値）
    private static let limiter = ConcurrencyLimiter(maxConcurrent: 2)
    private static let targetPixels = 480
    private static let minCachePixels = 280

    static func generate(
        entries: [PhotoEntry],
        imageList: BridgeCoreImageList,
        db: BridgeCoreDatabase
    ) async {
        let cached = await BridgeCore.fetchCachedThumbnailBatch(list: imageList, db: db)
        let writeBuffer = ThumbnailWriteBuffer(db: db)

        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                guard !Task.isCancelled else { break }

                // キャッシュが十分なサイズなら再生成しない
                // バックグラウンドでは aspect チェックを省略して高速化
                if let ce = cached[entry.url] {
                    let isAdequate = CGImage.bgFromJPEGData(ce.jpeg)
                        .map { max($0.width, $0.height) >= minCachePixels } ?? false
                    if isAdequate { continue }
                }

                group.addTask {
                    guard !Task.isCancelled else { return }
                    try? await limiter.run {
                        guard !Task.isCancelled else { return }
                        await writeOne(entry: entry, writeBuffer: writeBuffer)
                    }
                }
            }
        }
        await writeBuffer.drain()
    }

    private static func writeOne(entry: PhotoEntry, writeBuffer: ThumbnailWriteBuffer) async {
        if entry.isRaw {
            guard !Task.isCancelled,
                  let rawJpeg = await BridgeCore.extractRawJpeg(url: entry.url, quality: .preview),
                  !Task.isCancelled else { return }
            // autoreleasepool で CGImage を即時解放してメモリ圧を抑える
            let jpeg: Data? = autoreleasepool {
                guard let rawImg = CGImage.bgFromJPEGData(rawJpeg) else { return nil }
                let scaled = rawImg.bgScaledToFit(maxPixels: targetPixels) ?? rawImg
                return scaled.bgJpegData(compressionQuality: 0.85)
            }
            guard let jpeg else { return }
            await writeBuffer.enqueue(url: entry.url, data: jpeg)
        } else {
            guard !Task.isCancelled,
                  let img = await bgGenerateWithImageIO(url: entry.url),
                  !Task.isCancelled else { return }
            let jpeg: Data? = autoreleasepool { img.bgJpegData(compressionQuality: 0.85) }
            guard let jpeg else { return }
            await writeBuffer.enqueue(url: entry.url, data: jpeg)
        }
    }

    private static func bgGenerateWithImageIO(url: URL) async -> CGImage? {
        return await Task.detached(priority: .utility) {
            // 独自 RAW デコーダは macOS 26 でクラッシュするため ImageIO を使わない（extractRawJpeg で処理）
            guard !BridgeCoreConstants.proprietaryRawExtensions.contains(url.pathExtension.lowercased()),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
            ]
            guard var thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

            // 埋め込みサムネイルが小さすぎる場合はマスターから再生成する
            if max(thumb.width, thumb.height) < 280 {
                let alwaysOpts: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false,
                ]
                if let fresh = CGImageSourceCreateThumbnailAtIndex(src, 0, alwaysOpts as CFDictionary) {
                    thumb = fresh
                }
            }
            return thumb
        }.value
    }
}

// MARK: - CGImage helpers (iOS ターゲット専用)
// ThumbnailPipeline.swift（macOS のみ）に同名の extension があるため
// bg- プレフィックスで命名し fileprivate スコープで隔離している。

fileprivate extension CGImage {
    static func bgFromJPEGData(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }

    func bgJpegData(compressionQuality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, self, [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func bgScaledToFit(maxPixels: Int) -> CGImage? {
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
