import Foundation

enum PhotoKind: Sendable, Hashable, CaseIterable {
    case raw, sooc, developed
}

extension PhotoKind {
    var localizedName: String {
        switch self {
        case .raw:       return String(localized: "kind.raw", defaultValue: "RAW")
        case .sooc:      return String(localized: "kind.sooc", defaultValue: "SOOC")
        case .developed: return String(localized: "kind.developed", defaultValue: "Developed")
        }
    }

    var localizedBadgeName: String {
        switch self {
        case .raw:       return String(localized: "kind.raw.badge", defaultValue: "RAW")
        case .sooc:      return String(localized: "kind.sooc.badge", defaultValue: "SOOC")
        case .developed: return String(localized: "kind.developed.badge", defaultValue: "Retouched")
        }
    }
}

struct FilterCriteria: Sendable, Equatable {
    var excludedCameras: Set<String> = []
    var excludedLenses: Set<String> = []
    var excludedArtists: Set<String> = []
    var isoMin: String = ""
    var isoMax: String = ""
    var focalMin: String = ""
    var focalMax: String = ""
    var shutterMin: String = ""
    var shutterMax: String = ""
    var apertureMin: String = ""
    var apertureMax: String = ""
    var dateMin: String = ""
    var dateMax: String = ""
    var filterRatings: Set<Int> = []
    var filterLabels: Set<XmpLabel> = []
    var filterKinds: Set<PhotoKind> = []
    var cameraOnly: Bool = false

    var isActive: Bool {
        !excludedCameras.isEmpty || !excludedLenses.isEmpty || !excludedArtists.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !shutterMin.isEmpty || !shutterMax.isEmpty ||
        !apertureMin.isEmpty || !apertureMax.isEmpty ||
        !dateMin.isEmpty || !dateMax.isEmpty ||
        !filterRatings.isEmpty || !filterLabels.isEmpty ||
        !filterKinds.isEmpty || cameraOnly
    }

    func matches(entry: PhotoEntry, exif: ExifData?, xmp: XmpData?) -> Bool {
        // Camera-only filter: exclude images without camera Make/Model (e.g. screenshots, web images)
        if cameraOnly, let exif = exif {
            let hasCameraTag = !(exif.make ?? "").isEmpty || !(exif.model ?? "").isEmpty
            if !hasCameraTag { return false }
        }
        // Camera filter
        if let cameraName = exif?.cameraName, !excludedCameras.isEmpty, excludedCameras.contains(cameraName) {
            return false
        }
        // Lens filter
        if let lensName = exif?.lensName, !excludedLenses.isEmpty, excludedLenses.contains(lensName) {
            return false
        }
        // Artist filter
        if let artist = exif?.artist, !excludedArtists.isEmpty, excludedArtists.contains(artist) {
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
        // Date filter — EXIF datetime preferred, fallback to file creation date
        if !dateMin.isEmpty || !dateMax.isEmpty {
            let photoDate: Date? = exif?.datetime.flatMap(parseExifDate) ?? entry.createdDate
            if let date = photoDate {
                if let from = parseISODate(dateMin), date < from { return false }
                if let to = parseISODate(dateMax) {
                    let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to
                    if date > endOfDay { return false }
                }
            }
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
        return true
    }

    mutating func reset() {
        self = FilterCriteria()
    }

    // MARK: - Private helpers

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

    // EXIF datetime: "2024:01:15 10:30:00"
    private func parseExifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    // ISO date: "2024-01-15"
    private func parseISODate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
