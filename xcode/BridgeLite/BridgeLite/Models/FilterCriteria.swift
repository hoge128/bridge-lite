import Foundation

enum DateMode: String, Codable, Equatable, Sendable {
    case range, multi
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
    var dateMode: DateMode = .range
    var dateAllowList: Set<String> = []   // ISO yyyy-MM-dd (Multi モード時のみ)
    var luminanceMin: String = ""
    var luminanceMax: String = ""
    var filterRatings: Set<Int> = []
    var filterLabels: Set<XmpLabel> = []
    var filterFlags: Set<XmpFlag> = []
    var filterKinds: Set<PhotoKind> = []
    var cameraOnly: Bool = false
    var flatten: Bool = false
    var excludedExtensions: Set<String> = []   // lowercase, e.g. "jpg", "arw"
    var nameSearch: String = ""

    var isActive: Bool {
        !excludedCameras.isEmpty || !excludedLenses.isEmpty || !excludedArtists.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !shutterMin.isEmpty || !shutterMax.isEmpty ||
        !apertureMin.isEmpty || !apertureMax.isEmpty ||
        !dateMin.isEmpty || !dateMax.isEmpty || !dateAllowList.isEmpty ||
        !luminanceMin.isEmpty || !luminanceMax.isEmpty ||
        !filterRatings.isEmpty || !filterLabels.isEmpty || !filterFlags.isEmpty ||
        !filterKinds.isEmpty || cameraOnly || flatten || !excludedExtensions.isEmpty ||
        !nameSearch.isEmpty
    }

    var isFileTypeActive: Bool { !filterKinds.isEmpty || cameraOnly || !excludedExtensions.isEmpty }
    var isCameraActive: Bool   { !excludedCameras.isEmpty }
    var isArtistActive: Bool   { !excludedArtists.isEmpty }
    var isLensActive: Bool     { !excludedLenses.isEmpty }
    var isRatingActive: Bool   { !filterRatings.isEmpty }
    var isLabelActive: Bool    { !filterLabels.isEmpty }
    var isFlagActive: Bool     { !filterFlags.isEmpty }
    var isISOActive: Bool      { !isoMin.isEmpty || !isoMax.isEmpty }
    var isFocalActive: Bool    { !focalMin.isEmpty || !focalMax.isEmpty }
    var isShutterActive: Bool  { !shutterMin.isEmpty || !shutterMax.isEmpty }
    var isApertureActive: Bool { !apertureMin.isEmpty || !apertureMax.isEmpty }
    var isDateActive: Bool     { !dateMin.isEmpty || !dateMax.isEmpty || !dateAllowList.isEmpty }
    var isLuminanceActive: Bool { !luminanceMin.isEmpty || !luminanceMax.isEmpty }

    func matches(entry: PhotoEntry, exif: ExifData?, xmp: XmpData?, luminance: Int? = nil) -> Bool {
        // Filename / caption search filter (OR match)
        if !nameSearch.isEmpty {
            let hitName    = entry.filename.localizedCaseInsensitiveContains(nameSearch)
            let hitCaption = (xmp?.caption ?? "").localizedCaseInsensitiveContains(nameSearch)
            if !hitName && !hitCaption { return false }
        }
        // Extension filter (flatten mode only)
        if flatten, !excludedExtensions.isEmpty,
           excludedExtensions.contains(entry.url.pathExtension.lowercased()) {
            return false
        }
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
            if let min = Double(focalMin), focal <= min { return false }
            if let max = Double(focalMax), focal > max { return false }
        }
        // Shutter speed filter (秒単位: "1/200" or "0.005")
        if let shutter = exif?.shutterSeconds {
            if let min = parseSeconds(shutterMin), shutter <= min { return false }
            if let max = parseSeconds(shutterMax), shutter > max { return false }
        }
        // Aperture (F値) filter
        if let aperture = exif?.fnumberValue {
            if let min = Double(apertureMin), aperture <= min { return false }
            if let max = Double(apertureMax), aperture > max { return false }
        }
        // Date filter — EXIF datetime preferred, fallback to file creation date
        switch dateMode {
        case .range:
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
        case .multi:
            if !dateAllowList.isEmpty {
                let photoDate: Date? = exif?.datetime.flatMap(parseExifDate) ?? entry.createdDate
                guard let date = photoDate else { return false }
                if !dateAllowList.contains(Self.isoDateFormatter.string(from: date)) { return false }
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
        // Flag filter (Pick / Reject のみ検知。未フラグは常に除外)
        if !filterFlags.isEmpty {
            guard let flag = xmp?.flag, filterFlags.contains(flag) else { return false }
        }
        // Luminance filter
        if let lum = luminance {
            if let min = Int(luminanceMin), lum < min { return false }
            if let max = Int(luminanceMax), lum > max { return false }
        }
        return true
    }

    mutating func reset() { self = FilterCriteria() }

    mutating func clearFileType()  { filterKinds = []; cameraOnly = false; excludedExtensions = [] }
    mutating func clearCamera()    { excludedCameras = [] }
    mutating func clearArtist()    { excludedArtists = [] }
    mutating func clearLens()      { excludedLenses = [] }
    mutating func clearRating()    { filterRatings = [] }
    mutating func clearLabel()     { filterLabels = [] }
    mutating func clearFlag()      { filterFlags = [] }
    mutating func clearISO()       { isoMin = ""; isoMax = "" }
    mutating func clearFocal()     { focalMin = ""; focalMax = "" }
    mutating func clearShutter()   { shutterMin = ""; shutterMax = "" }
    mutating func clearAperture()  { apertureMin = ""; apertureMax = "" }
    mutating func clearDate()      { dateMin = ""; dateMax = ""; dateAllowList = []; dateMode = .range }
    mutating func clearLuminance() { luminanceMin = ""; luminanceMax = "" }

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
        Self.exifDateFormatter.date(from: s)
    }

    // ISO date: "2024-01-15"
    private func parseISODate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        return Self.isoDateFormatter.date(from: s)
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
