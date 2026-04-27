import Foundation

struct FilterCriteria: Sendable, Equatable {
    var excludedCameras: Set<String> = []
    var excludedLenses: Set<String> = []
    var isoMin: String = ""
    var isoMax: String = ""
    var focalMin: String = ""
    var focalMax: String = ""
    var shutterMin: String = ""
    var shutterMax: String = ""
    var apertureMin: String = ""
    var apertureMax: String = ""
    var dateFrom: String = ""
    var dateTo: String = ""
    var filterRatings: Set<Int> = []
    var filterLabels: Set<XmpLabel> = []
    var filterFlags: Set<XmpFlag> = []

    var isActive: Bool {
        !excludedCameras.isEmpty || !excludedLenses.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !shutterMin.isEmpty || !shutterMax.isEmpty ||
        !apertureMin.isEmpty || !apertureMax.isEmpty ||
        !dateFrom.isEmpty || !dateTo.isEmpty ||
        !filterRatings.isEmpty || !filterLabels.isEmpty || !filterFlags.isEmpty
    }

    func matches(entry: PhotoEntry, exif: ExifData?, xmp: XmpData?) -> Bool {
        // Camera filter
        if let cameraName = exif?.cameraName, !excludedCameras.isEmpty, excludedCameras.contains(cameraName) {
            return false
        }
        // Lens filter
        if let lensName = exif?.lensName, !excludedLenses.isEmpty, excludedLenses.contains(lensName) {
            return false
        }
        // ISO filter
        if let iso = exif?.iso {
            if let min = Int(isoMin), iso < min { return false }
            if let max = Int(isoMax), iso > max { return false }
        }
        // Focal length filter (35mm換算優先)
        if let focal = exif?.effectiveFocalMm {
            if let min = Double(focalMin), focal < min { return false }
            if let max = Double(focalMax), focal > max { return false }
        }
        // Shutter speed filter (秒単位: "1/200" or "0.005")
        if let shutter = exif?.shutterSeconds {
            if let min = parseSeconds(shutterMin), shutter < min { return false }
            if let max = parseSeconds(shutterMax), shutter > max { return false }
        }
        // Aperture (F値) filter
        if let aperture = exif?.fnumberValue {
            if let min = Double(apertureMin), aperture < min { return false }
            if let max = Double(apertureMax), aperture > max { return false }
        }
        // Rating filter
        if !filterRatings.isEmpty {
            let rating = xmp?.rating ?? 0
            if !filterRatings.contains(rating) { return false }
        }
        // Label filter
        if !filterLabels.isEmpty {
            guard let label = xmp?.label, filterLabels.contains(label) else { return false }
        }
        // Flag filter
        if !filterFlags.isEmpty {
            guard let flag = xmp?.flag, filterFlags.contains(flag) else { return false }
        }
        return true
    }

    mutating func reset() {
        self = FilterCriteria()
    }

    // "1/200" や "0.005" を秒に変換
    private func parseSeconds(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let n = Double(parts[0]),
              let d = Double(parts[1]),
              d != 0 else { return nil }
        return n / d
    }
}
