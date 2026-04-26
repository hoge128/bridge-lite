import Foundation

struct ExifData: Sendable, Equatable {
    var make: String?
    var model: String?
    var datetime: String?
    var subsec: String?
    var exposureTime: String?
    var fnumber: String?
    var iso: Int?
    var focalLength: String?
    var width: Int?
    var height: Int?
    var software: String?

    var cameraName: String? {
        guard let model = model else { return make }
        if let make = make, !model.hasPrefix(make) {
            return "\(make) \(model)"
        }
        return model
    }

    var resolutionString: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) × \(h)"
    }

    var isDeveloped: Bool {
        guard let sw = software?.lowercased() else { return false }
        return BridgeCoreConstants.developedKeywords.contains { sw.contains($0) }
    }
}

enum BridgeCoreConstants {
    // Must stay in sync with crates/bridge-core/src/developed.rs
    static let developedKeywords: [String] = [
        "lightroom", "dxo", "pureraw",
        "capture one", "captureone",
        "photoshop", "camera raw",
        "topaz", "on1", "luminar", "affinity",
        "darktable", "rawtherapee",
        "silkypix", "rawpower", "picktorial", "iridient", "exposure x",
    ]
}
