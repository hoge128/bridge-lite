import CoreImage
import ImageIO
import SwiftUI

enum RAWRenderTarget {
    case viewer   // full-screen viewer — max 3840 px
    case compare  // per-column compare view — max 1600 px
    case sidebar  // sidebar preview — max 800 px

    var maxWidth: Int {
        switch self {
        case .viewer:  return 3840
        case .compare: return 1600
        case .sidebar: return 800
        }
    }
}

/// On-demand RAW rendering via CIRAWFilter (hardware-accelerated, Photos.app-equivalent).
/// Results are persisted to the SQLite rendered_thumbnails table so subsequent
/// opens skip rendering entirely.
actor RAWRenderPipeline {
    static let shared = RAWRenderPipeline()
    private let limiter = ConcurrencyLimiter(maxConcurrent: 1)
    // Shared across renders: CIContext creation is expensive and holds GPU state.
    // cacheIntermediates: false prevents filter-chain IOSurfaces from accumulating.
    private let ctx = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    func render(
        url: URL,
        target: RAWRenderTarget,
        db: BridgeCoreDatabase
    ) async -> (CGImage, Image.Orientation)? {
        let width = target.maxWidth

        // SQLite cache hit: skip rendering
        if let jpeg = await BridgeCore.fetchCachedRendered(url: url, engine: "apple", width: width, db: db) {
            return decode(jpeg: jpeg)
        }

        guard let jpegData = await renderWithCIRAWFilter(url: url, maxWidth: width) else { return nil }

        // Persist for future sessions
        await BridgeCore.storeCachedRendered(url: url, engine: "apple", width: width, data: jpegData, db: db)

        return decode(jpeg: jpegData)
    }

    private func renderWithCIRAWFilter(url: URL, maxWidth: Int) async -> Data? {
        // ConcurrencyLimiter(maxConcurrent: 1) で CIRAWFilter の同時実行を 1 件に制限する。
        // Task.detached は actor 外で並列実行されるため limiter なしでは IOSurface を枯渇させる。
        // ctx は actor-isolated コンテキストで取り出し、detached クロージャへキャプチャする。
        let ctx = self.ctx
        do {
            return try await limiter.run { [url, maxWidth] in
                let result = await Task.detached(priority: BridgeQoS.rawRender) { () -> Data? in
                    // CIRAWFilter returns nil for formats not supported by the OS RAW pipeline.
                    // Canon CR2 is not supported on macOS 26; CIRAWFilter silently returns nil.
                    guard let filter = CIRAWFilter(imageURL: url) else { return nil }
                    // Scale based on longer side to handle portrait and landscape equally
                    let nativeSize = filter.nativeSize
                    let longerSide = max(nativeSize.width, nativeSize.height)
                    if longerSide > CGFloat(maxWidth) {
                        filter.scaleFactor = Float(CGFloat(maxWidth) / longerSide)
                    }
                    filter.isGamutMappingEnabled = true
                    guard let output = filter.outputImage,
                          let cg = ctx.createCGImage(output, from: output.extent) else { return nil }
                    return cg.jpegData(compressionQuality: 0.85)
                }.value
                // Release filter-chain IOSurfaces from the shared CIContext cache after each render.
                ctx.clearCaches()
                return result
            }
        } catch {
            return nil
        }
    }

    private func decode(jpeg: Data) -> (CGImage, Image.Orientation)? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, opts),
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
        // CIRAWFilter bakes rotation into pixel data; no post-rotation needed.
        return (img, .up)
    }
}
