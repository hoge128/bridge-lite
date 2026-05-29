import Foundation
import Observation
import SQLite3

// MARK: - PropagationMatrix

struct PropagationMatrix: Sendable, Equatable {
    var soocToRaw:       Bool
    var soocToDeveloped: Bool
    var rawToSooc:       Bool
    var rawToDeveloped:  Bool
    var developedToSooc: Bool
    var developedToRaw:  Bool

    func targets(for source: PhotoKind) -> Set<PhotoKind> {
        var result: Set<PhotoKind> = [source]
        switch source {
        case .sooc:
            if soocToRaw       { result.insert(.raw) }
            if soocToDeveloped { result.insert(.developed) }
        case .raw:
            if rawToSooc       { result.insert(.sooc) }
            if rawToDeveloped  { result.insert(.developed) }
        case .developed:
            if developedToSooc { result.insert(.sooc) }
            if developedToRaw  { result.insert(.raw) }
        case .indeterminate:
            break
        }
        return result
    }
}

enum DateMode: String, Codable, Equatable, Sendable {
    case range, multi
}

enum AutoReleaseTimeout: String, CaseIterable, Identifiable {
    case oneMinute      = "1min"
    case fiveMinutes    = "5min"
    case fifteenMinutes = "15min"
    case thirtyMinutes  = "30min"
    case off            = "off"

    var id: String { rawValue }

    var nanoseconds: UInt64? {
        switch self {
        case .oneMinute:      return 60_000_000_000
        case .fiveMinutes:    return 300_000_000_000
        case .fifteenMinutes: return 900_000_000_000
        case .thirtyMinutes:  return 1_800_000_000_000
        case .off:            return nil
        }
    }

    var localizedName: String {
        switch self {
        case .oneMinute:      return String(localized: "auto_release.timeout.1min",   defaultValue: "1 Minute")
        case .fiveMinutes:    return String(localized: "auto_release.timeout.5min",   defaultValue: "5 Minutes")
        case .fifteenMinutes: return String(localized: "auto_release.timeout.15min",  defaultValue: "15 Minutes")
        case .thirtyMinutes:  return String(localized: "auto_release.timeout.30min",  defaultValue: "30 Minutes")
        case .off:            return String(localized: "auto_release.timeout.off",    defaultValue: "Off")
        }
    }
}

enum IOSSortKey: String, CaseIterable {
    case filename
    case modifiedDate
    case createdDate

    var localizedName: String {
        switch self {
        case .filename:     return String(localized: "Filename")
        case .modifiedDate: return String(localized: "Date Modified")
        case .createdDate:  return String(localized: "Date Created")
        }
    }
}


@Observable
@MainActor
final class ScanStore: ReindexedGroupSink {

    // MARK: - State

    var folderURL: URL?
    var entries: [UInt64: PhotoEntry] = [:]
    var groups: [ShotGroup] = []
    var thumbnails: [UInt64: Data] = [:]
    var exifs: [UInt64: ExifData] = [:]
    var isScanning = false
    var isExifReady = false
    var scanError: String?
    private(set) var scanTotalCount: Int = 0
    private(set) var scanLoadedCount: Int = 0
    /// EXIF 索引の進捗（0 = 未開始 / 全件キャッシュ済み）
    private(set) var exifIndexProgress: Int = 0
    private(set) var exifIndexTotal: Int = 0
    /// indexTask 完了フラグ（全件キャッシュ済みで TOTAL が 0 のまま終わる場合も true になる）
    private(set) var exifIndexTaskDone = false
    /// EXIF 索引事前確認フェーズの進捗（キャッシュ確認済み件数）
    private(set) var exifPrecheckProgress: Int = 0
    private(set) var exifPrecheckTotal: Int = 0
    /// EXIF 索引開始時刻（残り時間推定用）
    private var exifIndexStartTime: Date?

    /// 残り秒数の推定値（0.5 秒ポーリングで更新される）
    var exifIndexRemainingSeconds: Int? {
        guard exifIndexTotal > 0, exifIndexProgress > 0,
              exifIndexProgress < exifIndexTotal,
              let start = exifIndexStartTime else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        let rate = Double(exifIndexProgress) / elapsed
        let remaining = Double(exifIndexTotal - exifIndexProgress) / rate
        return remaining > 1 ? Int(remaining.rounded()) : nil
    }

    // MARK: - Filter category order

    private static let filterCategoryOrderKey = "ios.filterCategoryOrder"

    var filterCategoryOrder: [FilterCategory] = ScanStore.loadFilterCategoryOrder()

    private static func loadFilterCategoryOrder() -> [FilterCategory] {
        guard let stored = UserDefaults.standard.stringArray(forKey: filterCategoryOrderKey) else {
            return FilterCategory.allCases
        }
        let decoded = stored.compactMap { FilterCategory(rawValue: $0) }
        let missing = FilterCategory.allCases.filter { !decoded.contains($0) }
        return decoded + missing
    }

    func saveFilterCategoryOrder() {
        UserDefaults.standard.set(filterCategoryOrder.map(\.rawValue), forKey: Self.filterCategoryOrderKey)
    }

    func resetFilterCategoryOrder() {
        filterCategoryOrder = FilterCategory.allCases
        UserDefaults.standard.removeObject(forKey: Self.filterCategoryOrderKey)
    }

    // MARK: - Filter state

    var filterRatings: Set<Int> = []
    var filterLabels: Set<XmpLabel> = []
    var filterKinds: Set<PhotoKind> = []
    var filterCameraOnly: Bool = false
    var filterCameras: Set<String> = []
    var filterLenses: Set<String> = []
    var filterArtists: Set<String> = []
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
    var dateAllowList: Set<String> = []   // ISO yyyy-MM-dd (multi モード時のみ)

    var isFilterActive: Bool {
        !filterRatings.isEmpty || !filterLabels.isEmpty || !filterKinds.isEmpty || filterCameraOnly ||
        !filterCameras.isEmpty || !filterLenses.isEmpty || !filterArtists.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !shutterMin.isEmpty || !shutterMax.isEmpty ||
        !apertureMin.isEmpty || !apertureMax.isEmpty ||
        !dateMin.isEmpty || !dateMax.isEmpty || !dateAllowList.isEmpty
    }

    // MARK: - Available filter values (derived from loaded EXIF)

    var availableCameras: [String]  { Set(exifs.values.compactMap(\.cameraName)).sorted() }
    var availableLenses:  [String]  { Set(exifs.values.compactMap(\.lensName)).sorted() }
    var availableArtists: [String]  { Set(exifs.values.compactMap(\.artist)).sorted() }

    // MARK: - Histogram buckets

    var isoBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤100",  100,      "",     "100"),
            ("200",   200,      "101",  "200"),
            ("400",   400,      "201",  "400"),
            ("800",   800,      "401",  "800"),
            ("1.6k",  1600,     "801",  "1600"),
            ("3.2k",  3200,     "1601", "3200"),
            ("6.4k",  6400,     "3201", "6400"),
            (">6k",   .infinity,"6401", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in exifs.values {
            guard let iso = exif.iso else { continue }
            let d = Double(iso)
            for (i, spec) in specs.enumerated() where d <= spec.upTo { counts[i] += 1; break }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    var focalBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤24",   24,        "",    "24"),
            ("35",    35,        "24",  "35"),
            ("50",    50,        "35",  "50"),
            ("85",    85,        "50",  "85"),
            ("135",   135,       "85",  "135"),
            ("200",   200,       "135", "200"),
            (">200",  .infinity, "200", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in exifs.values {
            guard let mm = exif.effectiveFocalMm else { continue }
            for (i, spec) in specs.enumerated() where mm <= spec.upTo { counts[i] += 1; break }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    var shutterBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≥2k",  1.0 / 2000, "",       "1/2000"),
            ("1k",   1.0 / 1000, "1/2000", "1/1000"),
            ("500",  1.0 / 500,  "1/1000", "1/500"),
            ("250",  1.0 / 250,  "1/500",  "1/250"),
            ("125",  1.0 / 125,  "1/250",  "1/125"),
            ("60",   1.0 / 60,   "1/125",  "1/60"),
            ("<60",  .infinity,  "1/60",   ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in exifs.values {
            guard let s = exif.shutterSeconds else { continue }
            for (i, spec) in specs.enumerated() where s <= spec.upTo { counts[i] += 1; break }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    var apertureBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤1.8",  1.8,      "",    "1.8"),
            ("2.8",   2.8,      "1.8", "2.8"),
            ("4",     4.0,      "2.8", "4"),
            ("5.6",   5.6,      "4",   "5.6"),
            ("8",     8.0,      "5.6", "8"),
            ("11",    11.0,     "8",   "11"),
            (">11",   .infinity,"11",  ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in exifs.values {
            guard let f = exif.fnumberValue else { continue }
            for (i, spec) in specs.enumerated() where f <= spec.upTo { counts[i] += 1; break }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    // MARK: - Filter toggle helpers

    func toggleRating(_ v: Int)    { filterRatings.toggle(v) }
    func toggleLabel(_ v: XmpLabel){ filterLabels.toggle(v) }
    func toggleKind(_ v: PhotoKind){ filterKinds.toggle(v) }
    func toggleCamera(_ v: String) { filterCameras.toggle(v) }
    func toggleLens(_ v: String)   { filterLenses.toggle(v) }
    func toggleArtist(_ v: String) { filterArtists.toggle(v) }

    func clearFilter(_ category: FilterCategory) {
        switch category {
        case .rating:   filterRatings = []
        case .label:    filterLabels = []
        case .kind:     filterKinds = []; filterCameraOnly = false
        case .camera:   filterCameras = []
        case .lens:     filterLenses = []
        case .artist:   filterArtists = []
        case .iso:      isoMin = ""; isoMax = ""
        case .focal:    focalMin = ""; focalMax = ""
        case .shutter:  shutterMin = ""; shutterMax = ""
        case .aperture: apertureMin = ""; apertureMax = ""
        case .date:     dateMin = ""; dateMax = ""; dateAllowList = []
        }
    }

    func clearAllFilters() {
        filterRatings = []; filterLabels = []; filterKinds = []; filterCameraOnly = false
        filterCameras = []; filterLenses = []; filterArtists = []
        isoMin = ""; isoMax = ""
        focalMin = ""; focalMax = ""
        shutterMin = ""; shutterMax = ""
        apertureMin = ""; apertureMax = ""
        dateMin = ""; dateMax = ""; dateAllowList = []
    }

    func isFilterActive(for category: FilterCategory) -> Bool {
        switch category {
        case .rating:   return !filterRatings.isEmpty
        case .label:    return !filterLabels.isEmpty
        case .kind:     return !filterKinds.isEmpty || filterCameraOnly
        case .camera:   return !filterCameras.isEmpty
        case .lens:     return !filterLenses.isEmpty
        case .artist:   return !filterArtists.isEmpty
        case .iso:      return !isoMin.isEmpty || !isoMax.isEmpty
        case .focal:    return !focalMin.isEmpty || !focalMax.isEmpty
        case .shutter:  return !shutterMin.isEmpty || !shutterMax.isEmpty
        case .aperture: return !apertureMin.isEmpty || !apertureMax.isEmpty
        case .date:     return !dateMin.isEmpty || !dateMax.isEmpty || !dateAllowList.isEmpty
        }
    }

    // MARK: - Sort state

    var sortKey: IOSSortKey = .modifiedDate {
        didSet {
            UserDefaults.standard.set(sortKey.rawValue, forKey: "ios.sortKey")
            applySort()
        }
    }
    var sortAscending: Bool = false {
        didSet {
            UserDefaults.standard.set(sortAscending, forKey: "ios.sortAscending")
            applySort()
        }
    }
    var jpgWriteMode: JpgWriteMode = JpgMetadataDefaults.readJpgWriteMode() {
        didSet {
            UserDefaults.standard.set(jpgWriteMode.rawValue, forKey: JpgMetadataDefaults.jpgWriteModeKey)
            if jpgWriteMode == .sidecar {
                soocToRaw = true
                rawToSooc = true
            }
        }
    }
    var autoRenderRawDetail: Bool = ScanStore.boolPref("ios.autoRenderRawDetail", default: true) {
        didSet { UserDefaults.standard.set(autoRenderRawDetail, forKey: "ios.autoRenderRawDetail") }
    }
    static let thumbnailQualityModeKey = "ios.thumbnailQualityMode"
    var thumbnailQualityMode: ThumbnailQualityMode = {
        if let raw = UserDefaults.standard.string(forKey: "ios.thumbnailQualityMode"),
           let m = ThumbnailQualityMode(rawValue: raw) { return m }
        return .speed
    }() {
        didSet { UserDefaults.standard.set(thumbnailQualityMode.rawValue, forKey: Self.thumbnailQualityModeKey) }
    }
    var enablePhashGrouping: Bool = UserDefaults.standard.bool(forKey: "ios.enablePhashGrouping") {
        didSet { UserDefaults.standard.set(enablePhashGrouping, forKey: "ios.enablePhashGrouping") }
    }

    // MARK: - Propagation settings (same UserDefaults keys as macOS)

    private static func boolPref(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.bool(forKey: key)
    }

    var soocToRaw: Bool = ScanStore.boolPref("propagate.soocToRaw", default: true) {
        didSet { UserDefaults.standard.set(soocToRaw, forKey: "propagate.soocToRaw") }
    }
    var soocToDeveloped: Bool = ScanStore.boolPref("propagate.soocToDeveloped", default: false) {
        didSet { UserDefaults.standard.set(soocToDeveloped, forKey: "propagate.soocToDeveloped") }
    }
    var rawToSooc: Bool = ScanStore.boolPref("propagate.rawToSooc", default: true) {
        didSet { UserDefaults.standard.set(rawToSooc, forKey: "propagate.rawToSooc") }
    }
    var rawToDeveloped: Bool = ScanStore.boolPref("propagate.rawToDeveloped", default: false) {
        didSet { UserDefaults.standard.set(rawToDeveloped, forKey: "propagate.rawToDeveloped") }
    }
    var developedToSooc: Bool = ScanStore.boolPref("propagate.developedToSooc", default: false) {
        didSet { UserDefaults.standard.set(developedToSooc, forKey: "propagate.developedToSooc") }
    }
    var developedToRaw: Bool = ScanStore.boolPref("propagate.developedToRaw", default: false) {
        didSet { UserDefaults.standard.set(developedToRaw, forKey: "propagate.developedToRaw") }
    }

    var propagationMatrix: PropagationMatrix {
        PropagationMatrix(
            soocToRaw:       soocToRaw,
            soocToDeveloped: soocToDeveloped,
            rawToSooc:       rawToSooc,
            rawToDeveloped:  rawToDeveloped,
            developedToSooc: developedToSooc,
            developedToRaw:  developedToRaw
        )
    }

    // MARK: - Internal

    private(set) var db: BridgeCoreDatabase?
    private var scanTask: Task<Void, Never>?
    private var phashPipeline = PHashPipeline()
    private(set) var scanGeneration: Int = 0
    private var pairingPipeline = PairingPipeline()
    private var lastImageList: BridgeCoreImageList?
    private var folderMonitor: (any DispatchSourceFileSystemObject)?

    // MARK: - On-demand thumbnail generation

    private let onDemandLimiter = ConcurrencyLimiter(maxConcurrent: 4)
    private var onDemandWriteBuffer: ThumbnailWriteBuffer?
    /// スキャン世代ごとにリセット。生成中のリクエストを重複排除する。
    private var pendingThumbnailIDs: Set<UInt64> = []

    // MARK: - 自動一時解放

    /// 自動一時解放によってウェルカム画面へ戻ったことを示すフラグ。
    /// welcomeView でヒントメッセージを表示するために使用する。
    private(set) var returnedFromAutoRelease: Bool = false
    private var autoReleaseTask: Task<Void, Never>?

    var autoReleaseTimeout: AutoReleaseTimeout = {
        if let raw = UserDefaults.standard.string(forKey: "ios.autoReleaseTimeout"),
           let t = AutoReleaseTimeout(rawValue: raw) { return t }
        return .oneMinute
    }() {
        didSet {
            UserDefaults.standard.set(autoReleaseTimeout.rawValue, forKey: "ios.autoReleaseTimeout")
            if autoReleaseTimeout == .off {
                autoReleaseTask?.cancel()
                autoReleaseTask = nil
            } else {
                resetAutoReleaseTimer()
            }
        }
    }

    /// スキャン完了後・ユーザー操作時に呼ぶ。設定時間無操作でウェルカム画面へ戻る。
    func resetAutoReleaseTimer() {
        autoReleaseTask?.cancel()
        autoReleaseTask = nil
        guard let nanos = autoReleaseTimeout.nanoseconds,
              !isScanning, folderURL != nil else { return }
        autoReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanos)
                self?.enterAutoRelease()
            } catch {}
        }
    }

    private func enterAutoRelease() {
        stopFolderMonitor()
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        isScanning = false
        isExifReady = false
        scanError = nil
        entries = [:]
        groups = []
        thumbnails = [:]
        exifs = [:]
        scanTotalCount = 0
        scanLoadedCount = 0
        exifIndexProgress = 0
        exifIndexTotal = 0
        exifIndexTaskDone = false
        exifIndexStartTime = nil
        exifPrecheckProgress = 0
        exifPrecheckTotal = 0
        onDemandWriteBuffer = nil
        pendingThumbnailIDs = []
        lastImageList = nil
        db = nil
        folderURL = nil
        returnedFromAutoRelease = true
        // BookmarkStore は残す（再開できるように）
        // フィルタ状態（filterRatings / filterLabels 等）は維持する
    }

    // MARK: - Init

    init() {
        JpgMetadataDefaults.migrateLegacyKeysIfNeeded()
        if let raw = UserDefaults.standard.string(forKey: "ios.sortKey"),
           let key = IOSSortKey(rawValue: raw) {
            sortKey = key
        }
        if UserDefaults.standard.object(forKey: "ios.sortAscending") != nil {
            sortAscending = UserDefaults.standard.bool(forKey: "ios.sortAscending")
        }
    }

    // MARK: - DB path

    static func cacheSizeBytes() -> Int64 {
        let base = cacheDBURL().path
        let fm = FileManager.default
        return [base, base + "-wal", base + "-shm"].reduce(Int64(0)) { total, path in
            let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            return total + size
        }
    }

    static func cachedThumbnailCount() -> Int {
        let path = cacheDBURL().path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM thumbnails", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    static func cacheDBURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("BridgeLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.db")
    }

    // MARK: - Scan

    func scan(url: URL) {
        returnedFromAutoRelease = false
        folderURL = url
        BookmarkStore.save(url: url)
        scanTask?.cancel()
        scanGeneration &+= 1
        let gen = scanGeneration
        scanTask = Task(priority: .userInitiated) { await performScan(url: url, gen: gen) }
        startFolderMonitor(url: url)
    }

    // NOTE_REVOKE fires when the volume containing the folder is unmounted (SD card removed).
    private func startFolderMonitor(url: URL) {
        stopFolderMonitor()
        _ = url.startAccessingSecurityScopedResource()
        let fd = open(url.path, O_EVTONLY)
        url.stopAccessingSecurityScopedResource()
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.resetForDetachedVolume() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderMonitor = source
    }

    private func stopFolderMonitor() {
        folderMonitor?.cancel()
        folderMonitor = nil
    }

    func verifyFolderReachability() async {
        guard let url = folderURL else { return }
        let ok = await Task.detached(priority: .utility) {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }.value
        if !ok { resetForDetachedVolume() }
    }

    func resetForDetachedVolume() {
        stopFolderMonitor()
        scanTask?.cancel()
        scanTask = nil
        autoReleaseTask?.cancel()
        autoReleaseTask = nil
        scanGeneration &+= 1
        isScanning = false
        isExifReady = false
        scanError = nil
        entries = [:]
        groups = []
        thumbnails = [:]
        exifs = [:]
        scanTotalCount = 0
        scanLoadedCount = 0
        db = nil
        folderURL = nil
        BookmarkStore.clear()
    }

    private func performScan(url: URL, gen: Int) async {
        phashPipeline = PHashPipeline()
        pairingPipeline = PairingPipeline()
        isScanning = true
        isExifReady = false
        scanError = nil
        entries = [:]
        groups = []
        thumbnails = [:]
        exifs = [:]
        scanTotalCount = 0
        scanLoadedCount = 0
        exifIndexProgress = 0
        exifIndexTotal = 0
        exifIndexTaskDone = false
        exifIndexStartTime = nil
        exifPrecheckProgress = 0
        exifPrecheckTotal = 0
        onDemandWriteBuffer = nil
        pendingThumbnailIDs = []

        do {
            let db = try BridgeCoreDatabase.open(path: Self.cacheDBURL())
            self.db = db
            await BridgeCore.pruneCache(dbPath: Self.cacheDBURL(), maxAgeDays: 90)

            // ディレクトリ走査のみ（EXIF 索引を含まないため高速）
            let (scannedEntries, imageList, _, _) = try await BridgeCore.scanDirectory(url: url, db: db)
            guard gen == scanGeneration else { return }

            let entryDict = Dictionary(uniqueKeysWithValues: scannedEntries.map { ($0.id, $0) })
            self.entries = entryDict
            scanTotalCount = scannedEntries.count

            // 初期グルーピング（EXIF 未索引のためステム名ベース。カメラ直出し RAW+JPEG には十分）
            let shotMap = await BridgeCore.reindexShotGroups(list: imageList, db: db)
            guard gen == scanGeneration else { return }
            self.groups = buildGroups(from: shotMap, entries: entryDict)
            lastImageList = imageList

            let capturedList = imageList
            let capturedPairing = pairingPipeline

            // indexTask 起動前に precheck の母数を Swift 側へ先行設定する。
            // Rust が EXIF_PRECHECK_TOTAL を書くより前に最初のポールが走ると 0 を読んでしまい、
            // その間に Phase 1 が完了すると X/Y が表示されないままになるため。
            exifPrecheckProgress = 0
            exifPrecheckTotal = scannedEntries.count

            // EXIF 索引をバックグラウンドで開始（サムネイル読み込みと並行実行）
            let indexTask = Task.detached(priority: .userInitiated) {
                await BridgeCore.indexNewEntries(list: capturedList, db: db)
            }

            // EXIF 索引進捗ポーラー（300ms 間隔でアトミックカウンタを読んで UI 更新）
            let progressPoller = Task { [weak self] in
                while let self, gen == self.scanGeneration {
                    let progress = BridgeCore.exifIndexProgress()
                    let total = BridgeCore.exifIndexTotal()
                    if exifIndexStartTime == nil && progress > 0 && total > 0 {
                        exifIndexStartTime = Date()
                    }
                    exifIndexProgress = progress
                    exifIndexTotal = total
                    exifPrecheckProgress = BridgeCore.exifPrecheckProgress()
                    exifPrecheckTotal = BridgeCore.exifPrecheckTotal()
                    if total > 0 && progress >= total { break }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { progressPoller.cancel() }

            // EXIF 取得・グルーピング再計算: 索引完了後に実行
            let exifTask = Task { [weak self] in
                await indexTask.value
                guard let self, gen == self.scanGeneration else { return }
                // indexTask 完了を通知（全件キャッシュ済みで EXIF_INDEX_TOTAL が 0 のまま
                // 終わった場合でも「準備中」バナーを消すために使う）
                exifIndexTaskDone = true

                let map = await BridgeCore.fetchExifBatch(list: capturedList, db: db)
                guard gen == self.scanGeneration else { return }
                self.exifs = map
                self.isExifReady = true

                await capturedPairing.noteExifReady(list: capturedList, db: db, store: self, splitThresholdSecs: 2, phashHammingThreshold: 15, generation: gen)
                guard gen == self.scanGeneration else { return }
                await self.onDemandWriteBuffer?.drain()
            }

            // キャッシュ済みサムネイルのみ即時表示（未キャッシュは各セルがオンデマンドで取得）
            await loadCachedThumbnails(entries: scannedEntries, imageList: imageList, db: db)
            guard gen == scanGeneration else { return }

            // DB に保存済みの pHash を使ってショットグループを再計算する。
            // 未キャッシュファイルの pHash はオンデマンド生成時に都度記録され、次回スキャン時に反映される。
            await capturedPairing.notePhashReady(list: capturedList, db: db, store: self, splitThresholdSecs: 2, phashHammingThreshold: 15, generation: gen)
            guard gen == scanGeneration else { return }

            // 未キャッシュのサムネイル生成を exifTask と並行して開始し、両方完了後に isScanning = false にする。
            let capturedEntries = scannedEntries
            let thumbnailTask = Task { [weak self] in
                guard let self,
                      let db = self.db,
                      let writeBuffer = self.onDemandWriteBuffer else { return }
                let mode = self.thumbnailQualityMode
                let pipeline: PHashPipeline? = self.enablePhashGrouping ? self.phashPipeline : nil
                let uncached = capturedEntries.filter { self.thumbnails[$0.id] == nil }
                guard !uncached.isEmpty else { return }

                let concurrency = max(ProcessInfo.processInfo.activeProcessorCount, 6)
                var cursor = 0

                await withTaskGroup(of: (UInt64, Data?).self) { group in
                    while cursor < uncached.count, cursor < concurrency {
                        let entry = uncached[cursor]; cursor += 1
                        group.addTask {
                            let jpeg = await ThumbnailService.generate(
                                for: entry, db: db, phashPipeline: pipeline,
                                mode: mode, writeBuffer: writeBuffer)
                            return (entry.id, jpeg)
                        }
                    }
                    while let (id, jpeg) = await group.next() {
                        guard gen == self.scanGeneration else { break }
                        if let jpeg, self.thumbnails[id] == nil {
                            self.thumbnails[id] = jpeg
                        }
                        if cursor < uncached.count {
                            let entry = uncached[cursor]; cursor += 1
                            group.addTask {
                                let jpeg = await ThumbnailService.generate(
                                    for: entry, db: db, phashPipeline: pipeline,
                                    mode: mode, writeBuffer: writeBuffer)
                                return (entry.id, jpeg)
                            }
                        }
                    }
                }
                await writeBuffer.drain()
            }

            await exifTask.value
            await thumbnailTask.value
            guard gen == scanGeneration else { return }
            isScanning = false
        } catch {
            guard gen == scanGeneration else { return }
            scanError = error.localizedDescription
            isScanning = false
        }
    }

    func applyReindexedGroups(_ map: [UInt64: [UInt64]], generation: Int) {
        guard generation == scanGeneration else { return }
        for (shotId, memberIDs) in map {
            for mid in memberIDs {
                if var e = entries[mid] { e.shotId = shotId; entries[mid] = e }
            }
        }
        self.groups = buildGroups(from: map, entries: entries)
    }

    private func buildGroups(from map: [UInt64: [UInt64]], entries: [UInt64: PhotoEntry]) -> [ShotGroup] {
        let unsorted = map.map { shotId, memberIDs in
            ShotGroup(id: shotId, memberIDs: sortedMemberIDs(memberIDs, entries: entries))
        }
        return sortedGroups(unsorted, entries: entries)
    }

    private func sortedGroups(_ input: [ShotGroup], entries: [UInt64: PhotoEntry]) -> [ShotGroup] {
        input.sorted { a, b in
            let entA = entries[a.representativeID ?? 0]
            let entB = entries[b.representativeID ?? 0]
            switch sortKey {
            case .filename:
                let fnA = entA?.filename ?? ""
                let fnB = entB?.filename ?? ""
                return sortAscending ? fnA < fnB : fnA > fnB
            case .modifiedDate:
                let dA = entA?.modifiedDate ?? .distantPast
                let dB = entB?.modifiedDate ?? .distantPast
                return sortAscending ? dA < dB : dA > dB
            case .createdDate:
                let dA = entA?.createdDate ?? .distantPast
                let dB = entB?.createdDate ?? .distantPast
                return sortAscending ? dA < dB : dA > dB
            }
        }
    }

    func applySort() {
        guard !groups.isEmpty else { return }
        groups = sortedGroups(groups, entries: entries)
    }

    func clearCache() {
        stopFolderMonitor()
        scanTask?.cancel()
        try? FileManager.default.removeItem(at: Self.cacheDBURL())
        db = nil
        entries = [:]
        groups = []
        thumbnails = [:]
        exifs = [:]
        folderURL = nil
    }

    /// 指定エントリの EXIF をオンデマンドで取得しキャッシュに書き込む。
    /// すでに exifs[id] が存在する場合は何もしない（冪等）。
    /// バッチスキャン（indexNewEntries + fetchExifBatch）と同一の SQLite upsert を使うため
    /// キャッシュの不整合は生じない。
    func fetchExifOnDemand(id: UInt64, url: URL) async {
        guard exifs[id] == nil, let db else { return }
        if let exif = await BridgeCore.fetchExif(url: url, db: db) {
            exifs[id] = exif
        } else {
            // EXIF を持たないファイル（PNG 等）も空レコードで記録し、
            // batchと同様に indeterminate 判定が正しく動くようにする
            exifs[id] = ExifData()
        }
    }

    private func sortedMemberIDs(_ memberIDs: [UInt64], entries: [UInt64: PhotoEntry]) -> [UInt64] {
        // suffix + exif ベースで developed を先頭に（xmps なしの簡易版）
        let devs = memberIDs.filter { id in
            guard let entry = entries[id], !entry.isRaw else { return false }
            return entry.hasDevelopedSuffix || (exifs[id]?.isDeveloped == true)
        }
        if let rep = devs.first {
            return [rep] + memberIDs.filter { $0 != rep }
        }
        // JPEG を先頭に
        if let rep = memberIDs.first(where: { entries[$0]?.isRaw == false }) {
            return [rep] + memberIDs.filter { $0 != rep }
        }
        return memberIDs
    }

    /// スキャン時: SQLite キャッシュヒット分のみ即時表示する。
    /// 未キャッシュ分は requestThumbnail() でオンデマンド生成する。
    private func loadCachedThumbnails(
        entries: [PhotoEntry],
        imageList: BridgeCoreImageList,
        db: BridgeCoreDatabase
    ) async {
        // await より前に初期化することで、fetchCachedThumbnailBatch の await 中に
        // LazyVGrid が初回レンダリングして各セルの .task(id:) が発火しても
        // requestThumbnail の guard が通るようにする。
        onDemandWriteBuffer = ThumbnailWriteBuffer(db: db)
        await PHashPipeline.applyBurstMode()
        // fetchCachedThumbnailBatch の await 中（実際に重い処理）は scanLoadedCount = 0 のまま
        // "Loading 0/N" が表示される。返却後は for ループを yield なしで一気に処理し、
        // SQLite に存在したサムネイルをすべて同一フレームで表示する。
        let prefetched = await BridgeCore.fetchCachedThumbnailBatch(list: imageList, db: db, priority: .userInitiated)
        for entry in entries {
            if let jpeg = prefetched[entry.url]?.jpeg {
                thumbnails[entry.id] = jpeg
            }
        }
        scanLoadedCount = entries.count
    }

    /// ThumbnailCellView が画面に現れたときに呼び出す。
    /// すでにキャッシュ済み / 生成中のリクエストには何もしない（冪等）。
    func requestThumbnail(for entry: PhotoEntry) async {
        guard thumbnails[entry.id] == nil,
              !pendingThumbnailIDs.contains(entry.id),
              let db,
              let writeBuffer = onDemandWriteBuffer else { return }
        pendingThumbnailIDs.insert(entry.id)
        defer { pendingThumbnailIDs.remove(entry.id) }

        // SQLite キャッシュを先に確認（アイドル省電力復帰時に <100ms で再表示できる）
        if let cached = await BridgeCore.fetchCachedThumbnail(url: entry.url, db: db) {
            thumbnails[entry.id] = cached.jpeg
            return
        }

        let mode = thumbnailQualityMode
        let pipeline: PHashPipeline? = enablePhashGrouping ? phashPipeline : nil
        if let jpeg = try? await onDemandLimiter.run({
            await ThumbnailService.generate(for: entry, db: db, phashPipeline: pipeline, mode: mode, writeBuffer: writeBuffer)
        }) {
            thumbnails[entry.id] = jpeg
        }
    }

    // MARK: - Kind 判定 (Mac LibraryStore と同等)

    func groupTargets(for id: UInt64, xmps: [UInt64: XmpData]) -> [UInt64] {
        guard let entry = entries[id],
              let group = groups.first(where: { $0.memberIDs.contains(id) }) else { return [id] }
        let members = group.memberIDs
        let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()
        let sourceKind = entryKind(id: id, entry: entry, groupMinDate: groupMinDate, xmps: xmps)
        let targetKinds = propagationMatrix.targets(for: sourceKind)
        return members.filter { mid in
            guard let me = entries[mid] else { return false }
            return targetKinds.contains(entryKind(id: mid, entry: me, groupMinDate: groupMinDate, xmps: xmps))
        }
    }

    private func entryKind(id: UInt64, entry: PhotoEntry, groupMinDate: Date?, xmps: [UInt64: XmpData]) -> PhotoKind {
        if entry.isRaw { return .raw }
        if isDevelopedMember(id, xmps: xmps, groupMinDate: groupMinDate) { return .developed }
        if isIndeterminateMember(id) { return .indeterminate }
        return .sooc
    }

    func isDevelopedMember(_ id: UInt64, xmps: [UInt64: XmpData], groupMinDate: Date?) -> Bool {
        guard let entry = entries[id], !entry.isRaw else { return false }
        if entry.hasDevelopedSuffix { return true }
        if xmps[id]?.developed == true { return true }
        if exifs[id]?.isDeveloped == true { return true }
        // 60s lag heuristic: IND ファイル (make/model 空) のみ適用
        guard let exif = exifs[id], (exif.make ?? "").isEmpty else { return false }
        if let created = entry.createdDate, let minDate = groupMinDate,
           created.timeIntervalSince(minDate) > 60 { return true }
        return false
    }

    func isIndeterminateMember(_ id: UInt64) -> Bool {
        guard let exif = exifs[id] else { return false }
        return (exif.make ?? "").isEmpty && (exif.model ?? "").isEmpty
    }

    /// 代表メンバー1件の種別を返す（Mac の photoKind 相当）
    func representativeKind(for group: ShotGroup, xmps: [UInt64: XmpData]) -> PhotoKind {
        guard let repID = group.representativeID, let entry = entries[repID] else { return .indeterminate }
        if entry.isRaw { return .raw }
        let groupMinDate = group.memberIDs.compactMap { entries[$0]?.createdDate }.min()
        if isDevelopedMember(repID, xmps: xmps, groupMinDate: groupMinDate) { return .developed }
        if isIndeterminateMember(repID) { return .indeterminate }
        return .sooc
    }

    func displayKind(for group: ShotGroup, xmps: [UInt64: XmpData]) -> PhotoKind {
        let groupMinDate = group.memberIDs.compactMap { entries[$0]?.createdDate }.min()
        var best: PhotoKind = .indeterminate
        for id in group.memberIDs {
            guard let entry = entries[id] else { continue }
            let kind: PhotoKind = {
                if entry.isRaw { return .raw }
                if isDevelopedMember(id, xmps: xmps, groupMinDate: groupMinDate) { return .developed }
                if isIndeterminateMember(id) { return .indeterminate }
                return .sooc
            }()
            switch kind {
            case .developed:     return .developed
            case .sooc:          best = .sooc
            case .raw:           if best == .indeterminate { best = .raw }
            case .indeterminate: break
            }
        }
        return best
    }

    // MARK: - Representative 選定 (Mac computeRepresentatives 互換)

    func representativeID(for group: ShotGroup, xmps: [UInt64: XmpData]) -> UInt64? {
        let members = group.memberIDs
        guard !members.isEmpty else { return nil }
        let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()

        // Tier 1: developed non-RAW
        let devs = members.filter { id in
            guard let entry = entries[id], !entry.isRaw else { return false }
            let suffixHit = entry.hasDevelopedSuffix
            let xmpHit    = xmps[id]?.developed == true
            let exifHit   = exifs[id]?.isDeveloped == true
            let tsHit: Bool = {
                guard !suffixHit && !xmpHit && !exifHit else { return false }
                if let exif = exifs[id], !(exif.make ?? "").isEmpty { return false }
                guard let created = entry.createdDate, let minDate = groupMinDate else { return false }
                return created.timeIntervalSince(minDate) > 60
            }()
            return suffixHit || xmpHit || exifHit || tsHit
        }
        if let rep = devs.first { return rep }

        // Tier 2: JPEG (non-RAW)
        if let rep = members.first(where: { entries[$0]?.isRaw == false }) { return rep }

        // Tier 3: first member (RAW フォールバック)
        return members.first
    }

    func representativeURL(for group: ShotGroup, xmps: [UInt64: XmpData]) -> URL? {
        guard let id = representativeID(for: group, xmps: xmps) else { return nil }
        return entries[id]?.url
    }

    private func filteredRepresentativeID(for group: ShotGroup, kinds: Set<PhotoKind>, xmps: [UInt64: XmpData]) -> UInt64? {
        let members = group.memberIDs
        guard !members.isEmpty else { return nil }

        let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()
        var devMembers: [UInt64] = []
        var soocMembers: [UInt64] = []
        var rawMembers: [UInt64] = []
        var indMembers: [UInt64] = []

        for id in members {
            guard let entry = entries[id] else { continue }
            if entry.isRaw {
                rawMembers.append(id)
            } else if isDevelopedMember(id, xmps: xmps, groupMinDate: groupMinDate) {
                devMembers.append(id)
            } else if isIndeterminateMember(id) {
                indMembers.append(id)
            } else {
                soocMembers.append(id)
            }
        }

        if kinds.contains(.developed), !devMembers.isEmpty, !soocMembers.isEmpty {
            return devMembers[0]
        } else if kinds.contains(.sooc), !soocMembers.isEmpty {
            return soocMembers[0]
        } else if kinds.contains(.indeterminate), !indMembers.isEmpty {
            return indMembers[0]
        } else if kinds.contains(.raw), !rawMembers.isEmpty {
            return rawMembers.max {
                (entries[$0]?.createdDate ?? .distantPast) < (entries[$1]?.createdDate ?? .distantPast)
            }
        }
        return nil
    }

    private func replacingRepresentative(_ representativeID: UInt64, in group: ShotGroup) -> ShotGroup {
        var filteredGroup = group
        filteredGroup.memberIDs = [representativeID] + group.memberIDs.filter { $0 != representativeID }
        return filteredGroup
    }

    // MARK: - Filtered view

    func filteredGroups(ratings: [UInt64: XmpData]) -> [ShotGroup] {
        filteredGroupsInternal(ratings: ratings, skipRating: false)
    }

    /// 星フィルタ以外の条件で絞った母集団から★0〜★5の件数を返す（ファセットカウント用）。
    func ratingCounts(from ratings: [UInt64: XmpData]) -> [Int: Int] {
        var counts: [Int: Int] = [0:0, 1:0, 2:0, 3:0, 4:0, 5:0]
        for group in filteredGroupsInternal(ratings: ratings, skipRating: true) {
            guard let repID = group.representativeID else { continue }
            let r = max(0, min(5, ratings[repID]?.rating ?? 0))
            counts[r, default: 0] += 1
        }
        return counts
    }

    /// 日付フィルタ以外の条件で絞った母集団から日別写真数を返す（カレンダーファセット用）。
    func photosPerDay(from ratings: [UInt64: XmpData]) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for group in filteredGroupsInternal(ratings: ratings, skipDate: true) {
            guard let repID = group.representativeID,
                  let entry = entries[repID] else { continue }
            guard let date = Self.photoDate(exif: exifs[repID], entry: entry) else { continue }
            let day = Calendar.current.startOfDay(for: date)
            result[day, default: 0] += 1
        }
        return result
    }

    /// 全エントリの最古〜最新撮影日（カレンダー表示範囲の決定用）。
    var datasetDateInterval: DateInterval? {
        var minDate: Date? = nil
        var maxDate: Date? = nil
        for (id, entry) in entries {
            guard let date = Self.photoDate(exif: exifs[id], entry: entry) else { continue }
            if minDate == nil || date < minDate! { minDate = date }
            if maxDate == nil || date > maxDate! { maxDate = date }
        }
        guard let min = minDate, let max = maxDate else { return nil }
        return DateInterval(start: min, end: max)
    }

    // MARK: - Date helpers

    static let exifDateFormatter: DateFormatter = {
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

    private static func photoDate(exif: ExifData?, entry: PhotoEntry) -> Date? {
        exif?.datetime.flatMap { exifDateFormatter.date(from: $0) } ?? entry.createdDate
    }

    private func filteredGroupsInternal(ratings: [UInt64: XmpData], skipRating: Bool = false, skipDate: Bool = false) -> [ShotGroup] {
        let otherFiltersActive = !filterLabels.isEmpty || !filterKinds.isEmpty || filterCameraOnly ||
            !filterCameras.isEmpty || !filterLenses.isEmpty || !filterArtists.isEmpty ||
            !isoMin.isEmpty || !isoMax.isEmpty || !focalMin.isEmpty || !focalMax.isEmpty ||
            !shutterMin.isEmpty || !shutterMax.isEmpty || !apertureMin.isEmpty || !apertureMax.isEmpty
        let dateFiltersActive = !dateMin.isEmpty || !dateMax.isEmpty || !dateAllowList.isEmpty
        let anyActive = otherFiltersActive ||
            (!skipRating && !filterRatings.isEmpty) ||
            (!skipDate && dateFiltersActive)
        guard anyActive else { return groups }
        return groups.compactMap { group in
            guard let repID = group.representativeID else { return nil }
            let xmp  = ratings[repID]
            let exif = exifs[repID]

            if !skipRating, !filterRatings.isEmpty, !filterRatings.contains(xmp?.rating ?? 0) { return nil }
            if !filterLabels.isEmpty {
                guard let lbl = xmp?.label, filterLabels.contains(lbl) else { return nil }
            }
            var filteredGroup = group
            if !filterKinds.isEmpty {
                guard let representativeID = filteredRepresentativeID(for: group, kinds: filterKinds, xmps: ratings) else {
                    return nil
                }
                filteredGroup = replacingRepresentative(representativeID, in: group)
            }
            if filterCameraOnly {
                guard exif?.make != nil || exif?.model != nil else { return nil }
            }
            if !filterCameras.isEmpty {
                guard let cam = exif?.cameraName, filterCameras.contains(cam) else { return nil }
            }
            if !filterLenses.isEmpty {
                guard let lens = exif?.lensName, filterLenses.contains(lens) else { return nil }
            }
            if !filterArtists.isEmpty {
                guard let artist = exif?.artist, filterArtists.contains(artist) else { return nil }
            }
            if !isoMin.isEmpty || !isoMax.isEmpty {
                guard let iso = exif?.iso else { return nil }
                if let min = Int(isoMin), iso < min { return nil }
                if let max = Int(isoMax), iso > max { return nil }
            }
            if !focalMin.isEmpty || !focalMax.isEmpty {
                guard let mm = exif?.effectiveFocalMm else { return nil }
                if let min = Double(focalMin), mm <= min { return nil }
                if let max = Double(focalMax), mm > max  { return nil }
            }
            if !shutterMin.isEmpty || !shutterMax.isEmpty {
                guard let s = exif?.shutterSeconds else { return nil }
                if let min = Self.parseSeconds(shutterMin), s <= min { return nil }
                if let max = Self.parseSeconds(shutterMax), s > max  { return nil }
            }
            if !apertureMin.isEmpty || !apertureMax.isEmpty {
                guard let f = exif?.fnumberValue else { return nil }
                if let min = Double(apertureMin), f <= min { return nil }
                if let max = Double(apertureMax), f > max  { return nil }
            }
            if !skipDate {
                let isoFmt = Self.isoDateFormatter
                switch dateMode {
                case .range:
                    if !dateMin.isEmpty || !dateMax.isEmpty {
                        guard let entry = entries[repID] else { return nil }
                        let photoDate = Self.photoDate(exif: exif, entry: entry)
                        if let date = photoDate {
                            if let from = isoFmt.date(from: dateMin), date < from { return nil }
                            if let to = isoFmt.date(from: dateMax) {
                                let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to
                                if date > endOfDay { return nil }
                            }
                        }
                    }
                case .multi:
                    if !dateAllowList.isEmpty {
                        guard let entry = entries[repID] else { return nil }
                        let photoDate = Self.photoDate(exif: exif, entry: entry)
                        guard let date = photoDate else { return nil }
                        if !dateAllowList.contains(isoFmt.string(from: date)) { return nil }
                    }
                }
            }
            return filteredGroup
        }
    }

    private static func parseSeconds(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let n = Double(parts[0]),
              let d = Double(parts[1]),
              d != 0 else { return nil }
        return n / d
    }

    // MARK: - 削除

    func deleteGroup(_ group: ShotGroup) {
        guard let folderURL = folderURL else { return }
        let started = folderURL.startAccessingSecurityScopedResource()
        defer { if started { folderURL.stopAccessingSecurityScopedResource() } }

        for id in group.memberIDs {
            guard let entry = entries[id] else { continue }
            let url = entry.url
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
            let xmpURL = url.deletingPathExtension().appendingPathExtension("xmp")
            if FileManager.default.fileExists(atPath: xmpURL.path) {
                if (try? FileManager.default.trashItem(at: xmpURL, resultingItemURL: nil)) == nil {
                    try? FileManager.default.removeItem(at: xmpURL)
                }
            }
        }

        let ids = Set(group.memberIDs)
        for id in ids {
            entries.removeValue(forKey: id)
            thumbnails.removeValue(forKey: id)
            exifs.removeValue(forKey: id)
        }
        groups.removeAll { $0.id == group.id }
    }
}
