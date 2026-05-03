import CoreImage
import ImageIO
import SwiftUI

enum RAWRenderEngine: String {
    case apple  // CIRAWFilter (hardware-accelerated, Photos.app-equivalent)
    case rust   // rawloader + imagepipe (deterministic, pure Rust)
}

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

/// On-demand RAW rendering via CIRAWFilter (Apple) or rawloader+imagepipe (Rust).
/// Results are persisted to the SQLite rendered_thumbnails table so subsequent
/// opens skip rendering entirely.
actor RAWRenderPipeline {
    static let shared = RAWRenderPipeline()

    func render(
        url: URL,
        engine: RAWRenderEngine,
        target: RAWRenderTarget,
        db: BridgeCoreDatabase
    ) async -> (CGImage, Image.Orientation)? {
        let width = target.maxWidth

        // SQLite cache hit: skip rendering
        if let jpeg = await BridgeCore.fetchCachedRendered(url: url, engine: engine.rawValue, width: width, db: db) {
            return decode(jpeg: jpeg, sourceURL: url, applySourceOrientation: engine == .rust)
        }

        // Render
        let jpeg: Data?
        switch engine {
        case .apple:
            jpeg = await renderWithCIRAWFilter(url: url, maxWidth: width)
        case .rust:
            jpeg = await BridgeCore.renderRawRust(url: url, maxWidth: UInt32(width))
        }

        guard let jpegData = jpeg else { return nil }

        // Persist for future sessions
        await BridgeCore.storeCachedRendered(url: url, engine: engine.rawValue, width: width, data: jpegData, db: db)

        return decode(jpeg: jpegData, sourceURL: url, applySourceOrientation: engine == .rust)
    }

    private func renderWithCIRAWFilter(url: URL, maxWidth: Int) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let ctx = CIContext(options: [.useSoftwareRenderer: false])
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

    /// - Parameter applySourceOrientation: Rust engine outputs in sensor orientation and needs
    ///   the EXIF orientation applied by the caller. CIRAWFilter already bakes rotation into
    ///   pixel data, so passing `false` avoids double-rotation.
    private func decode(jpeg: Data, sourceURL: URL, applySourceOrientation: Bool) -> (CGImage, Image.Orientation)? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        guard applySourceOrientation else {
            return (img, .up)
        }
        // Rust: pixel data is in sensor orientation; read EXIF to rotate correctly.
        let orient: CGImagePropertyOrientation
        if let rawSrc = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) {
            orient = readOrientation(rawSrc)
        } else {
            orient = .up
        }
        return (img, Image.Orientation(orient))
    }
}
