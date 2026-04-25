import Foundation

struct FilterCriteria: Sendable, Equatable {
    var excludedCameras: Set<String> = []
    var isoMin: String = ""
    var isoMax: String = ""
    var focalMin: String = ""
    var focalMax: String = ""
    var dateFrom: String = ""
    var dateTo: String = ""
    var filterRatings: Set<Int> = []
    var filterLabels: Set<XmpLabel> = []
    var filterFlags: Set<XmpFlag> = []

    var isActive: Bool {
        !excludedCameras.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !dateFrom.isEmpty || !dateTo.isEmpty ||
        !filterRatings.isEmpty || !filterLabels.isEmpty || !filterFlags.isEmpty
    }

    func matches(entry: PhotoEntry, exif: ExifData?, xmp: XmpData?) -> Bool {
        // Camera filter
        if let model = exif?.model, !excludedCameras.isEmpty, excludedCameras.contains(model) {
            return false
        }
        // ISO filter
        if let iso = exif?.iso {
            if let min = Int(isoMin), iso < min { return false }
            if let max = Int(isoMax), iso > max { return false }
        }
        // Focal filter (mm)
        // TODO: Phase E で focalLength 文字列をパースして比較
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
}
