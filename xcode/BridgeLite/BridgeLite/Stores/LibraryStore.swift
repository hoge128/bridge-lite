import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class LibraryStore {
    // エントリ一覧
    private(set) var entries: [UInt64: PhotoEntry] = [:]
    private(set) var orderedIDs: [UInt64] = []
    private(set) var shotGroups: [UInt64: [UInt64]] = [:]

    // @Observable state — UI が自動更新される
    private(set) var thumbnailImages: [UInt64: CGImage] = [:]
    private(set) var exifData: [UInt64: ExifData] = [:]
    private(set) var xmpData: [UInt64: XmpData] = [:]

    // サブストア
    let settings = SettingsStore()

    // パイプライン
    private let scanPipeline = ScanPipeline()
    private var pairingPipeline = PairingPipeline()
    private var phashPipeline = PHashPipeline()

    // UI 状態
    var selectedID: UInt64?
    var viewerMode: Bool = false
    var showFilters: Bool = true
    var showSidebar: Bool = true
    var filter: FilterCriteria = FilterCriteria()
    var statusMessage: String = ""
    var isLoading: Bool = false

    private(set) var currentDirectoryURL: URL?
    private var database: BridgeCoreDatabase?
    private var lastImageList: BridgeCoreImageList?

    // MARK: - 公開アクション

    func requestOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Open Folder")
        if panel.runModal() == .OK, let url = panel.url {
            Task { await openDirectory(url) }
        }
    }

    func openDirectory(_ url: URL) async {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = String(localized: "Scanning…")
        reset()
        currentDirectoryURL = url

        do {
            let db = try BridgeCoreDatabase.open(path: dbURL())
            database = db

            // Rust scan (with FileManager fallback)
            let scanned: [PhotoEntry]
            do {
                let (entries, list) = try await BridgeCore.scanDirectory(url: url, db: db)
                scanned = entries
                lastImageList = list
            } catch {
                scanned = try await scanPipeline.scan(url: url)
            }
            ingest(scanned)

            // 並行: EXIF バッチ + XMP バッチ (fire-and-forget)
            let allEntries = orderedIDs.compactMap { entries[$0] }
            let capturedList = lastImageList
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for entry in allEntries {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            async let exif = BridgeCore.fetchExif(url: entry.url, db: db)
                            async let xmp  = BridgeCore.readXmp(url: entry.url)
                            let (e, x) = await (exif, xmp)
                            await self.setExif(id: entry.id, exif: e)
                            await self.setXmp(id: entry.id, xmp: x)
                        }
                    }
                }
                await pairingPipeline.noteExifReady(list: capturedList, db: db, store: self)
            }

            // サムネイル → pHash → shot-group reindex (直列チェーン)
            statusMessage = String(localized: "Loading thumbnails…")
            let entriesToLoad = orderedIDs.compactMap { entries[$0] }
            let capturedPhash = phashPipeline
            let capturedPairing = pairingPipeline
            Task {
                await ThumbnailPipeline.loadAll(entries: entriesToLoad, store: self, db: db, phashPipeline: capturedPhash)
                await capturedPhash.waitForAllPending()
                await capturedPairing.notePhashReady(list: capturedList, db: db, store: self)
            }

            statusMessage = String(
                format: String(localized: "%d photos"),
                orderedIDs.count
            )
        } catch {
            statusMessage = error.localizedDescription
        }
        isLoading = false
    }

    func selectEntry(_ id: UInt64) {
        selectedID = id
    }

    func navigateNext() {
        guard let id = selectedID,
              let idx = visibleIDs.firstIndex(of: id),
              idx + 1 < visibleIDs.count else { return }
        selectedID = visibleIDs[idx + 1]
    }

    func navigatePrev() {
        guard let id = selectedID,
              let idx = visibleIDs.firstIndex(of: id),
              idx > 0 else { return }
        selectedID = visibleIDs[idx - 1]
    }

    func cyclePairVariant(reverse: Bool) {
        guard let id = selectedID,
              let entry = entries[id],
              let members = shotGroups[entry.shotId], members.count > 1 else { return }
        guard let idx = members.firstIndex(of: id) else { return }
        let next = reverse
            ? (idx == 0 ? members.count - 1 : idx - 1)
            : (idx + 1) % members.count
        selectedID = members[next]
    }

    func applyRating(_ stars: Int) {
        guard let id = selectedID,
              let entry = entries[id],
              let db = database else { return }
        var current = xmpData[id] ?? XmpData()
        current.rating = stars == 0 ? nil : stars
        current.flag = nil
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
    }

    func applyLabel(_ labelRaw: UInt8) {
        guard let id = selectedID,
              let entry = entries[id],
              let label = XmpLabel(rawValue: labelRaw),
              let db = database else { return }
        var current = xmpData[id] ?? XmpData()
        current.label = current.label == label ? nil : label
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
    }

    func togglePick() {
        guard let id = selectedID,
              let entry = entries[id],
              let db = database else { return }
        var current = xmpData[id] ?? XmpData()
        current.flag = current.flag == .pick ? nil : .pick
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
    }

    func toggleReject() {
        guard let id = selectedID,
              let entry = entries[id],
              let db = database else { return }
        var current = xmpData[id] ?? XmpData()
        current.flag = current.flag == .reject ? nil : .reject
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
    }

    // MARK: - Computed

    var visibleIDs: [UInt64] {
        // Recompute representatives live from current exifData (updates as EXIF loads)
        let liveReps = computeRepresentatives(groups: shotGroups, entries: entries)
        let reps = orderedIDs.filter { liveReps.contains($0) }
        guard filter.isActive else { return reps }
        return reps.filter { id in
            guard let entry = entries[id] else { return false }
            return filter.matches(entry: entry, exif: exifData[id], xmp: xmpData[id])
        }
    }

    var availableCameras: [String] {
        Array(Set(exifData.values.compactMap { $0.cameraName })).sorted()
    }

    var availableLenses: [String] {
        Array(Set(exifData.values.compactMap { $0.lensName })).sorted()
    }

    // MARK: - Private

    func setThumbnail(id: UInt64, image: CGImage) {
        thumbnailImages[id] = image
    }

    func setExif(id: UInt64, exif: ExifData?) {
        guard let exif else { return }
        exifData[id] = exif
    }

    func setXmp(id: UInt64, xmp: XmpData?) {
        guard let xmp else { return }
        xmpData[id] = xmp
    }

    func applyReindexedGroups(_ groups: [UInt64: [UInt64]]) {
        // Update each entry's shotId to match its reindexed group key
        for (shotId, memberIds) in groups {
            for memberId in memberIds {
                entries[memberId]?.shotId = shotId
            }
        }
        shotGroups = groups
    }

    private func reset() {
        entries = [:]
        orderedIDs = []
        shotGroups = [:]
        thumbnailImages = [:]
        exifData = [:]
        xmpData = [:]
        selectedID = nil
        viewerMode = false
        lastImageList = nil
        pairingPipeline = PairingPipeline()
        phashPipeline = PHashPipeline()
    }

    private func ingest(_ scanned: [PhotoEntry]) {
        var dict: [UInt64: PhotoEntry] = [:]
        var ordered: [UInt64] = []
        var groups: [UInt64: [UInt64]] = [:]

        for entry in scanned {
            dict[entry.id] = entry
            ordered.append(entry.id)
            groups[entry.shotId, default: []].append(entry.id)
        }

        entries = dict
        orderedIDs = ordered
        shotGroups = groups
    }

    private func computeRepresentatives(
        groups: [UInt64: [UInt64]],
        entries: [UInt64: PhotoEntry]
    ) -> Set<UInt64> {
        var reps = Set<UInt64>()
        for (_, members) in groups {
            guard !members.isEmpty else { continue }

            // Tier 1: developed non-RAW — checked in priority order:
            //   1. Filename suffix (synchronous, no async dependency)
            //   2. XMP developed flag (catches DxO namespace, crs:RawFileName, etc.)
            //   3. EXIF Software keyword match
            //   4. birth_time relative lag > 60s within the shot group
            //      Files copied together from a card are within seconds of each other;
            //      a developed file created later stands out clearly above this threshold.
            let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()
            let devs = members.filter { id in
                guard let entry = entries[id], !entry.isRaw else { return false }
                let suffixHit  = entry.hasDevelopedSuffix
                let xmpHit     = xmpData[id]?.developed == true
                let exifHit    = exifData[id]?.software.map { sw in
                    let lower = sw.lowercased()
                    return BridgeCoreConstants.developedKeywords.contains { lower.contains($0) }
                } ?? false
                let tsHit: Bool = {
                    guard let created = entry.createdDate, let minDate = groupMinDate else { return false }
                    return created.timeIntervalSince(minDate) > 60
                }()
                // DEBUG — remove after diagnosis
                if members.count > 1 {
                    print("[Tier1] \(entry.filename) suffix=\(suffixHit) xmp=\(xmpHit) exif=\(exifHit) ts=\(tsHit) sw=\(exifData[id]?.software ?? "nil") created=\(entry.createdDate?.description ?? "nil") groupMin=\(groupMinDate?.description ?? "nil")")
                }
                return suffixHit || xmpHit || exifHit || tsHit
            }
            if let rep = devs.first { reps.insert(rep); continue }

            // Tier 2: JPEG (non-RAW)
            let jpgs = members.filter { entries[$0]?.isRaw == false }
            if let rep = jpgs.first { reps.insert(rep); continue }

            // Tier 3: first member (RAW)
            reps.insert(members[0])
        }
        return reps
    }

    private func dbURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("BridgeLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.db")
    }
}
