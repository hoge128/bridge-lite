import Foundation
import Observation

@Observable
@MainActor
final class ScanStore {

    // MARK: - State

    var folderURL: URL?
    var entries: [UInt64: PhotoEntry] = [:]
    var groups: [ShotGroup] = []
    var thumbnails: [UInt64: Data] = [:]
    var isScanning = false
    var scanError: String?

    // MARK: - Filter state

    var filterMinRating: Int? = nil
    var filterLabel: XmpLabel? = nil

    // MARK: - Internal

    private(set) var db: BridgeCoreDatabase?
    private var scanTask: Task<Void, Never>?

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
        scanTask = Task { await performScan(url: url) }
    }

    private func performScan(url: URL) async {
        isScanning = true
        scanError = nil
        entries = [:]
        groups = []
        thumbnails = [:]

        do {
            let db = try BridgeCoreDatabase.open(path: Self.cacheDBURL())
            self.db = db

            let (scannedEntries, imageList, _, _) = try await BridgeCore.scanDirectory(url: url, db: db)

            let entryDict = Dictionary(uniqueKeysWithValues: scannedEntries.map { ($0.id, $0) })
            self.entries = entryDict

            let shotMap = await BridgeCore.reindexShotGroups(list: imageList, db: db)
            self.groups = buildGroups(from: shotMap, entries: entryDict)

            isScanning = false

            await loadThumbnails(entries: scannedEntries, imageList: imageList, db: db)
        } catch {
            scanError = error.localizedDescription
            isScanning = false
        }
    }

    private func buildGroups(from map: [UInt64: [UInt64]], entries: [UInt64: PhotoEntry]) -> [ShotGroup] {
        map.map { shotId, memberIDs in
            ShotGroup(id: shotId, memberIDs: memberIDs)
        }
        .sorted { a, b in
            let dateA = entries[a.representativeID ?? 0]?.modifiedDate ?? .distantPast
            let dateB = entries[b.representativeID ?? 0]?.modifiedDate ?? .distantPast
            return dateA > dateB
        }
    }

    private func loadThumbnails(
        entries: [PhotoEntry],
        imageList: BridgeCoreImageList,
        db: BridgeCoreDatabase
    ) async {
        let prefetched = await BridgeCore.fetchCachedThumbnailBatch(list: imageList, db: db)
        let limiter = ConcurrencyLimiter(maxConcurrent: 2)

        await withTaskGroup(of: (UInt64, Data?).self) { group in
            for entry in entries {
                let cached = prefetched[entry.url]
                group.addTask {
                    let jpeg = try? await limiter.run {
                        if let c = cached { return c }
                        return await ThumbnailService.generate(for: entry, db: db)
                    }
                    return (entry.id, jpeg)
                }
            }
            for await (id, jpeg) in group {
                guard let jpeg else { continue }
                thumbnails[id] = jpeg
            }
        }
    }

    // MARK: - Filtered view

    func filteredGroups(ratings: [UInt64: XmpData]) -> [ShotGroup] {
        guard filterMinRating != nil || filterLabel != nil else { return groups }
        return groups.filter { group in
            group.memberIDs.contains { id in
                let xmp = ratings[id]
                if let min = filterMinRating, (xmp?.rating ?? 0) < min { return false }
                if let lbl = filterLabel, xmp?.label != lbl { return false }
                return true
            }
        }
    }
}
