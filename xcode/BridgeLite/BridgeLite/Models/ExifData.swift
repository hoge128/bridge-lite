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
    var focalLength35mm: Int?
    var lensName: String?
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

    // 35mm換算が取れればそれを、なければ実焦点距離をパース
    var effectiveFocalMm: Double? {
        if let mm = focalLength35mm { return Double(mm) }
        return Self.parseRational(focalLength?.components(separatedBy: " ").first)
    }

    var fnumberValue: Double? {
        guard let s = fnumber else { return nil }
        let stripped = s.hasPrefix("f/") ? String(s.dropFirst(2)) : s
        return Double(stripped.components(separatedBy: " ").first ?? stripped)
    }

    // 秒単位（例: "1/200 s" → 0.005）
    var shutterSeconds: Double? {
        Self.parseRational(exposureTime?.components(separatedBy: " ").first)
    }

    private static func parseRational(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let n = Double(parts[0]),
              let d = Double(parts[1]),
              d != 0 else { return nil }
        return n / d
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

    // Must stay in sync with SOFTWARE_MARKERS in crates/bridge-core/src/scanner.rs
    static let softwareFilenameMarkers: [String] = [
        "-dxo", "_dxo",
        "-pureraw", "_pureraw",
        "-lightroom", "_lightroom",
        "-captureone", "-capture_one", "_captureone",
        "-photolab", "_photolab",
        "-topaz", "_topaz",
        "-on1", "_on1",
        "-luminar", "_luminar",
        "-affinity", "_affinity",
        "-silkypix", "_silkypix",
        "-denoise", "_denoise",
        "-gigapixel", "_gigapixel",
        "-sharpen", "_sharpen",
        "-processed", "_processed",
    ]
}
