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
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
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
    }

    private func decode(jpeg: Data) -> (CGImage, Image.Orientation)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        // CIRAWFilter bakes rotation into pixel data; no post-rotation needed.
        return (img, .up)
    }
}
