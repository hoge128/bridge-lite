import Foundation
import Observation

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

    // MARK: - Filter state

    var filterMinRating: Int? = nil
    var filterLabel: XmpLabel? = nil

    // MARK: - Internal

    private(set) var db: BridgeCoreDatabase?
    private var scanTask: Task<Void, Never>?
    private var phashPipeline = PHashPipeline()
    private(set) var scanGeneration: Int = 0
    private var pairingPipeline = PairingPipeline()
    private var lastImageList: BridgeCoreImageList?

    // MARK: - DB path

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
        map.map { shotId, memberIDs in
            ShotGroup(id: shotId, memberIDs: sortedMemberIDs(memberIDs, entries: entries))
        }
        .sorted { a, b in
            let dateA = entries[a.representativeID ?? 0]?.modifiedDate ?? .distantPast
            let dateB = entries[b.representativeID ?? 0]?.modifiedDate ?? .distantPast
            return dateA > dateB
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

    // MARK: - Filtered view

    func filteredGroups(ratings: [UInt64: XmpData]) -> [ShotGroup] {
        guard filterMinRating != nil || filterLabel != nil else { return groups }
        return groups.filter { group in
            guard let repID = group.representativeID else { return false }
            let xmp = ratings[repID]
            if let min = filterMinRating, (xmp?.rating ?? 0) < min { return false }
            if let lbl = filterLabel, xmp?.label != lbl { return false }
            return true
        }
    }
}
