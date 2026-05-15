import Foundation
import Observation

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
    var scanError: String?
    private(set) var scanTotalCount: Int = 0
    private(set) var scanLoadedCount: Int = 0

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

    var isFilterActive: Bool {
        !filterRatings.isEmpty || !filterLabels.isEmpty || !filterKinds.isEmpty || filterCameraOnly ||
        !filterCameras.isEmpty || !filterLenses.isEmpty || !filterArtists.isEmpty ||
        !isoMin.isEmpty || !isoMax.isEmpty ||
        !focalMin.isEmpty || !focalMax.isEmpty ||
        !shutterMin.isEmpty || !shutterMax.isEmpty ||
        !apertureMin.isEmpty || !apertureMax.isEmpty
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
        }
    }

    func clearAllFilters() {
        filterRatings = []; filterLabels = []; filterKinds = []; filterCameraOnly = false
        filterCameras = []; filterLenses = []; filterArtists = []
        isoMin = ""; isoMax = ""
        focalMin = ""; focalMax = ""
        shutterMin = ""; shutterMax = ""
        apertureMin = ""; apertureMax = ""
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
        didSet { UserDefaults.standard.set(jpgWriteMode.rawValue, forKey: JpgMetadataDefaults.jpgWriteModeKey) }
    }

    // MARK: - Internal

    private(set) var db: BridgeCoreDatabase?
    private var scanTask: Task<Void, Never>?
    private var phashPipeline = PHashPipeline()
    private(set) var scanGeneration: Int = 0
    private var pairingPipeline = PairingPipeline()
    private var lastImageList: BridgeCoreImageList?
    private var folderMonitor: (any DispatchSourceFileSystemObject)?

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
        let attrs = try? FileManager.default.attributesOfItem(atPath: cacheDBURL().path)
        return attrs?[.size] as? Int64 ?? 0
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
        folderURL = url
        BookmarkStore.save(url: url)
        scanTask?.cancel()
        scanGeneration &+= 1
        let gen = scanGeneration
        scanTask = Task { await performScan(url: url, gen: gen) }
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
        scanGeneration &+= 1
        isScanning = false
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
        scanError = nil
        entries = [:]
        groups = []
        thumbnails = [:]
        exifs = [:]
        scanTotalCount = 0
        scanLoadedCount = 0

        do {
            let db = try BridgeCoreDatabase.open(path: Self.cacheDBURL())
            self.db = db

            let (scannedEntries, imageList, _, _) = try await BridgeCore.scanDirectory(url: url, db: db)
            guard gen == scanGeneration else { return }

            let entryDict = Dictionary(uniqueKeysWithValues: scannedEntries.map { ($0.id, $0) })
            self.entries = entryDict
            scanTotalCount = scannedEntries.count

            let shotMap = await BridgeCore.reindexShotGroups(list: imageList, db: db)
            guard gen == scanGeneration else { return }
            self.groups = buildGroups(from: shotMap, entries: entryDict)
            lastImageList = imageList

            let capturedList = imageList
            let capturedPairing = pairingPipeline
            let exifTask = Task { [weak self] in
                guard let self, gen == self.scanGeneration else { return }

                let map = await BridgeCore.fetchExifBatch(list: capturedList, db: db)
                guard gen == self.scanGeneration else { return }
                self.exifs = map

                await capturedPairing.noteExifReady(list: capturedList, db: db, store: self, splitThresholdSecs: 2, phashHammingThreshold: 15, generation: gen)
                guard gen == self.scanGeneration else { return }
            }

            await loadThumbnails(entries: scannedEntries, imageList: imageList, db: db)
            guard gen == scanGeneration else { return }

            await capturedPairing.notePhashReady(list: capturedList, db: db, store: self, splitThresholdSecs: 2, phashHammingThreshold: 15, generation: gen)
            guard gen == scanGeneration else { return }

            await exifTask.value
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

    private func loadThumbnails(
        entries: [PhotoEntry],
        imageList: BridgeCoreImageList,
        db: BridgeCoreDatabase
    ) async {
        await PHashPipeline.applyBurstMode()
        let prefetched = await BridgeCore.fetchCachedThumbnailBatch(list: imageList, db: db)
        let limiter = ConcurrencyLimiter(maxConcurrent: 2)
        let pipeline = phashPipeline

        await withTaskGroup(of: (UInt64, Data?).self) { group in
            for entry in entries {
                let cached = prefetched[entry.url]
                group.addTask {
                    let jpeg = try? await limiter.run {
                        if let c = cached { return c }
                        return await ThumbnailService.generate(for: entry, db: db, phashPipeline: pipeline)
                    }
                    return (entry.id, jpeg)
                }
            }
            for await (id, jpeg) in group {
                scanLoadedCount += 1
                guard let jpeg else { continue }
                thumbnails[id] = jpeg
            }
        }
        await phashPipeline.waitForAllPending()
    }

    // MARK: - Kind 判定 (Mac LibraryStore と同等)

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
        guard isFilterActive else { return groups }
        return groups.compactMap { group in
            guard let repID = group.representativeID else { return nil }
            let xmp  = ratings[repID]
            let exif = exifs[repID]

            if !filterRatings.isEmpty, !filterRatings.contains(xmp?.rating ?? 0) { return nil }
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
}
