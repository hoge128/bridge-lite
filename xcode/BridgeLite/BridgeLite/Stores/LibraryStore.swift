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
    private(set) var pairingPipeline = PairingPipeline()

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

            // サムネイル開始 (fire-and-forget: 各サムネイル完了時に thumbnailImages を更新)
            statusMessage = String(localized: "Loading thumbnails…")
            let entriesToLoad = orderedIDs.compactMap { entries[$0] }
            Task { await ThumbnailPipeline.loadAll(entries: entriesToLoad, store: self, db: db) }

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
              let entry = entries[id] else { return }
        var current = xmpData[id] ?? XmpData()
        current.rating = stars == 0 ? nil : stars
        current.flag = nil
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x) }
    }

    func applyLabel(_ labelRaw: UInt8) {
        guard let id = selectedID,
              let entry = entries[id],
              let label = XmpLabel(rawValue: labelRaw) else { return }
        var current = xmpData[id] ?? XmpData()
        current.label = current.label == label ? nil : label
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x) }
    }

    func togglePick() {
        guard let id = selectedID,
              let entry = entries[id] else { return }
        var current = xmpData[id] ?? XmpData()
        current.flag = current.flag == .pick ? nil : .pick
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x) }
    }

    func toggleReject() {
        guard let id = selectedID,
              let entry = entries[id] else { return }
        var current = xmpData[id] ?? XmpData()
        current.flag = current.flag == .reject ? nil : .reject
        xmpData[id] = current
        let x = current
        Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x) }
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

            // Tier 1: developed (EXIF software tag matches known keywords)
            let devs = members.filter { id in
                guard let sw = exifData[id]?.software?.lowercased() else { return false }
                return BridgeCoreConstants.developedKeywords.contains { sw.contains($0) }
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
