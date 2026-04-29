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
    let settings: SettingsStore = .shared

    // パイプライン
    private let scanPipeline = ScanPipeline()
    private var pairingPipeline = PairingPipeline()
    private var phashPipeline = PHashPipeline()

    // UI 状態 — 選択
    private(set) var selectedIDs: Set<UInt64> = []
    private(set) var primaryID: UInt64?       // サイドバー/ビュワーで表示する「主」選択
    private var anchorID: UInt64?             // Shift+Click の始点
    var selectedID: UInt64? { primaryID }     // ViewerView 互換

    var columnVisibility: NavigationSplitViewVisibility = .all
    var viewerMode: Bool = false
    var compareMode: Bool = false
    var compareAnchorID: UInt64? = nil
    var gridColumnCount: Int = 4
    var showFilters: Bool = true
    var showSidebar: Bool = true
    var filter: FilterCriteria = FilterCriteria() {
        didSet { recomputeVisible() }
    }

    private(set) var visibleIDs: [UInt64] = []
    var statusMessage: String = ""
    var isLoading: Bool = false

    // Undo
    private var undoStack: [(description: String, perform: () -> Void)] = []
    private(set) var undoMessage: String?
    private var undoMessageTask: Task<Void, Never>?
    var canUndo: Bool { !undoStack.isEmpty }

    // Batch flush — coalesces rapid dict mutations to reduce @Observable invalidation frequency
    private var pendingThumbnails: [UInt64: CGImage] = [:]
    private var thumbnailFlushTask: Task<Void, Never>?
    private var pendingExif: [UInt64: ExifData] = [:]
    private var pendingXmp: [UInt64: XmpData] = [:]
    private var metaFlushTask: Task<Void, Never>?

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
                let exifLimiter = ConcurrencyLimiter(maxConcurrent: 8)
                await withTaskGroup(of: Void.self) { group in
                    for entry in allEntries {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            try? await exifLimiter.run {
                                async let exif = BridgeCore.fetchExif(url: entry.url, db: db)
                                async let xmp  = BridgeCore.readXmp(url: entry.url)
                                let (e, x) = await (exif, xmp)
                                await self.setExif(id: entry.id, exif: e)
                                await self.setXmp(id: entry.id, xmp: x)
                            }
                        }
                    }
                }
                await pairingPipeline.noteExifReady(list: capturedList, db: db, store: self)
            }

            // サムネイル → pHash → shot-group reindex (直列チェーン)
            statusMessage = String(localized: "Loading thumbnails…")
            // visibleIDs (sort order) first so top-of-grid thumbnails appear before off-screen ones
            let visibleSet = Set(visibleIDs)
            let entriesToLoad = visibleIDs.compactMap { entries[$0] }
                + orderedIDs.filter { !visibleSet.contains($0) }.compactMap { entries[$0] }
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

    // MARK: - 選択操作

    func selectEntry(_ id: UInt64) {
        selectedIDs = [id]
        primaryID = id
        anchorID = id
    }

    func toggleSelect(_ id: UInt64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if primaryID == id { primaryID = selectedIDs.first }
        } else {
            selectedIDs.insert(id)
            primaryID = id
            anchorID = id
        }
    }

    func rangeSelect(to id: UInt64) {
        guard let anchor = anchorID,
              let anchorIdx = visibleIDs.firstIndex(of: anchor),
              let targetIdx = visibleIDs.firstIndex(of: id) else {
            selectEntry(id); return
        }
        let lo = min(anchorIdx, targetIdx)
        let hi = max(anchorIdx, targetIdx)
        selectedIDs = Set(visibleIDs[lo...hi])
        primaryID = id
    }

    func selectAll() {
        let ids = visibleIDs
        selectedIDs = Set(ids)
        primaryID = ids.last
        anchorID = ids.first
    }

    func deselectAll() {
        selectedIDs = []
        primaryID = nil
        anchorID = nil
    }

    func navigateNext() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id), idx + 1 < visibleIDs.count else { return }
        selectEntry(visibleIDs[idx + 1])
    }

    func navigatePrev() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id), idx > 0 else { return }
        selectEntry(visibleIDs[idx - 1])
    }

    func navigateUp() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id) else { return }
        selectEntry(visibleIDs[max(0, idx - gridColumnCount)])
    }

    func navigateDown() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id) else { return }
        selectEntry(visibleIDs[min(visibleIDs.count - 1, idx + gridColumnCount)])
    }

    func navigateFirst() {
        guard !visibleIDs.isEmpty else { return }
        selectEntry(visibleIDs[0])
    }

    func navigateLast() {
        guard !visibleIDs.isEmpty else { return }
        selectEntry(visibleIDs[visibleIDs.count - 1])
    }

    func rangeNavigateNext() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id), idx + 1 < visibleIDs.count else { return }
        rangeSelect(to: visibleIDs[idx + 1])
    }

    func rangeNavigatePrev() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id), idx > 0 else { return }
        rangeSelect(to: visibleIDs[idx - 1])
    }

    func rangeNavigateUp() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id) else { return }
        rangeSelect(to: visibleIDs[max(0, idx - gridColumnCount)])
    }

    func rangeNavigateDown() {
        guard let id = primaryID else {
            if let first = visibleIDs.first { selectEntry(first) }; return
        }
        guard let idx = visibleIDs.firstIndex(of: id) else { return }
        rangeSelect(to: visibleIDs[min(visibleIDs.count - 1, idx + gridColumnCount)])
    }

    func rangeNavigateFirst() {
        guard !visibleIDs.isEmpty else { return }
        rangeSelect(to: visibleIDs[0])
    }

    func rangeNavigateLast() {
        guard !visibleIDs.isEmpty else { return }
        rangeSelect(to: visibleIDs[visibleIDs.count - 1])
    }

    func cyclePairVariant(reverse: Bool) {
        guard let id = primaryID,
              let entry = entries[id],
              let members = shotGroups[entry.shotId], members.count > 1 else { return }
        guard let idx = members.firstIndex(of: id) else { return }
        let next = reverse
            ? (idx == 0 ? members.count - 1 : idx - 1)
            : (idx + 1) % members.count
        selectEntry(members[next])
    }

    // MARK: - Undo

    var performUndoTitle: String? { undoStack.last.map { "Undo \($0.description)" } }

    func performUndo() {
        guard let record = undoStack.popLast() else { return }
        record.perform()
        showUndoMessage("取り消し: \(record.description)")
    }

    private func registerUndo(description: String, perform: @escaping () -> Void) {
        undoStack.append((description: description, perform: perform))
    }

    private func showUndoMessage(_ msg: String) {
        undoMessage = msg
        undoMessageTask?.cancel()
        undoMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.undoMessage = nil
        }
    }

    // MARK: - コピー

    enum CopyMode { case representativeOnly, allInGroup, filteredKindOnly }

    func triggerCopy() {
        guard !selectedIDs.isEmpty else { return }
        let mode: CopyMode
        if settings.confirmCopy {
            guard let m = showCopyAlert() else { return }
            mode = m
        } else {
            mode = .representativeOnly
        }
        copySelectedFiles(mode: mode)
    }

    private func showCopyAlert() -> CopyMode? {
        let alert = NSAlert()
        alert.messageText = "コピーの範囲を選択"
        alert.informativeText = "\(selectedIDs.count)グループのファイルをコピーします。"
        let hasKindFilter = !filter.filterKinds.isEmpty
        alert.addButton(withTitle: "代表ファイルのみ")
        if hasKindFilter { alert.addButton(withTitle: "フィルタ対象のみ") }
        alert.addButton(withTitle: "グループ全体")
        alert.addButton(withTitle: "キャンセル")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "次回から確認しない"

        let resp = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.confirmCopy = false }

        switch resp {
        case .alertFirstButtonReturn:  return .representativeOnly
        case .alertSecondButtonReturn: return hasKindFilter ? .filteredKindOnly : .allInGroup
        case .alertThirdButtonReturn:  return hasKindFilter ? .allInGroup : nil
        default: return nil
        }
    }

    private func copySelectedFiles(mode: CopyMode) {
        var urls: [URL] = []
        var seen = Set<URL>()

        func add(_ url: URL) { if seen.insert(url).inserted { urls.append(url) } }

        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            switch mode {
            case .representativeOnly:
                add(entry.url)
            case .allInGroup:
                let members = shotGroups[entry.shotId] ?? [id]
                members.compactMap { entries[$0]?.url }.forEach { add($0) }
            case .filteredKindOnly:
                guard !filter.filterKinds.isEmpty else { add(entry.url); continue }
                let members = shotGroups[entry.shotId] ?? [id]
                let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()
                for mid in members {
                    guard let mentry = entries[mid] else { continue }
                    let kind: PhotoKind = mentry.isRaw ? .raw
                        : isDevelopedMember(mid, groupMinDate: groupMinDate) ? .developed : .sooc
                    if filter.filterKinds.contains(kind) { add(mentry.url) }
                }
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    // MARK: - 削除

    func triggerDelete() {
        guard !selectedIDs.isEmpty else { return }
        if settings.confirmDelete {
            let groupCount = selectedIDs.count
            let fileCount = selectedIDs.reduce(0) { acc, id in
                guard let entry = entries[id] else { return acc }
                return acc + (shotGroups[entry.shotId]?.count ?? 1)
            }
            let alert = NSAlert()
            alert.messageText = "\(groupCount)グループ（\(fileCount)ファイル）をゴミ箱に移動しますか？"
            alert.informativeText = "グループ内のすべてのファイルが移動されます。Finderから復元できます。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "ゴミ箱に移動")
            alert.addButton(withTitle: "キャンセル")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "次回から確認しない"

            let resp = alert.runModal()
            if alert.suppressionButton?.state == .on { settings.confirmDelete = false }
            if resp != .alertFirstButtonReturn { return }
        }
        deleteSelectedGroups()
    }

    private func deleteSelectedGroups() {
        var deletedIDs: Set<UInt64> = []
        var fileCount = 0

        for repId in selectedIDs {
            guard let entry = entries[repId] else { continue }
            let members = shotGroups[entry.shotId] ?? [repId]
            for mid in members {
                guard let mentry = entries[mid] else { continue }
                try? FileManager.default.trashItem(at: mentry.url, resultingItemURL: nil)
                let xmpURL = mentry.url.deletingPathExtension().appendingPathExtension("xmp")
                if FileManager.default.fileExists(atPath: xmpURL.path) {
                    try? FileManager.default.trashItem(at: xmpURL, resultingItemURL: nil)
                }
                deletedIDs.insert(mid)
                fileCount += 1
            }
        }

        for id in deletedIDs {
            entries.removeValue(forKey: id)
            thumbnailImages.removeValue(forKey: id)
            exifData.removeValue(forKey: id)
            xmpData.removeValue(forKey: id)
        }
        orderedIDs = orderedIDs.filter { !deletedIDs.contains($0) }
        var newGroups: [UInt64: [UInt64]] = [:]
        for id in orderedIDs {
            guard let e = entries[id] else { continue }
            newGroups[e.shotId, default: []].append(id)
        }
        shotGroups = newGroups
        recomputeVisible()
        deselectAll()
        showUndoMessage("ゴミ箱に移動: \(fileCount) ファイル（Finderから復元できます）")
    }

    // MARK: - 一括評価トリガー

    func triggerRating(_ stars: Int) {
        guard !selectedIDs.isEmpty else { return }
        if selectedIDs.count > 1 && settings.confirmBulkRating {
            let label = stars == 0 ? "評価なし" : String(repeating: "★", count: stars)
            let alert = NSAlert()
            alert.messageText = "\(selectedIDs.count)枚の写真に「\(label)」を設定しますか？"
            alert.informativeText = "既存のレーティングは上書きされます。"
            alert.addButton(withTitle: "設定する")
            alert.addButton(withTitle: "キャンセル")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "次回から確認しない"

            let resp = alert.runModal()
            if alert.suppressionButton?.state == .on { settings.confirmBulkRating = false }
            if resp != .alertFirstButtonReturn { return }
        }
        applyRating(stars)
    }

    func applyRating(_ stars: Int) {
        guard !selectedIDs.isEmpty, let db = database else { return }
        // Expand to group targets based on propagation settings
        var allTargets: [(entry: PhotoEntry, old: Int?)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            for targetID in groupTargets(for: id, entry: entry) {
                guard let te = entries[targetID] else { continue }
                allTargets.append((entry: te, old: xmpData[targetID]?.rating))
                var current = xmpData[targetID] ?? XmpData()
                current.rating = stars == 0 ? nil : stars
                current.flag = nil
                xmpData[targetID] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
        }
        recomputeVisible()
        let desc = stars == 0 ? "レーティング解除" : "レーティング ★×\(stars)"
        registerUndo(description: desc) { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.rating = old
                self.xmpData[te.id] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
            self.recomputeVisible()
        }
    }

    func applyLabel(_ labelRaw: UInt8) {
        guard !selectedIDs.isEmpty, let db = database,
              let label = XmpLabel(rawValue: labelRaw) else { return }
        let pivot = primaryID.flatMap { xmpData[$0]?.label }
        let newLabel: XmpLabel? = pivot == label ? nil : label
        var allTargets: [(entry: PhotoEntry, old: XmpLabel?)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            for targetID in groupTargets(for: id, entry: entry) {
                guard let te = entries[targetID] else { continue }
                allTargets.append((entry: te, old: xmpData[targetID]?.label))
                var current = xmpData[targetID] ?? XmpData()
                current.label = newLabel
                xmpData[targetID] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
        }
        recomputeVisible()
        registerUndo(description: "ラベル変更") { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.label = old
                self.xmpData[te.id] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
            self.recomputeVisible()
        }
    }

    func togglePick() {
        guard !selectedIDs.isEmpty, let db = database else { return }
        let newFlag: XmpFlag? = xmpData[primaryID ?? selectedIDs.first!]?.flag == .pick ? nil : .pick
        var allTargets: [(entry: PhotoEntry, old: XmpFlag?)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            allTargets.append((entry: entry, old: xmpData[id]?.flag))
            var current = xmpData[id] ?? XmpData()
            current.flag = newFlag
            xmpData[id] = current
            let x = current
            Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
        }
        recomputeVisible()
        registerUndo(description: "Pick フラグ変更") { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.flag = old
                self.xmpData[te.id] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
            self.recomputeVisible()
        }
    }

    func toggleReject() {
        guard !selectedIDs.isEmpty, let db = database else { return }
        let newFlag: XmpFlag? = xmpData[primaryID ?? selectedIDs.first!]?.flag == .reject ? nil : .reject
        var allTargets: [(entry: PhotoEntry, old: XmpFlag?)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            allTargets.append((entry: entry, old: xmpData[id]?.flag))
            var current = xmpData[id] ?? XmpData()
            current.flag = newFlag
            xmpData[id] = current
            let x = current
            Task { _ = await BridgeCore.writeXmp(url: entry.url, xmp: x, db: db) }
        }
        recomputeVisible()
        registerUndo(description: "Reject フラグ変更") { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.flag = old
                self.xmpData[te.id] = current
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db) }
            }
            self.recomputeVisible()
        }
    }

    // MARK: - Computed

    private func recomputeVisible() {
        let liveReps: Set<UInt64>
        if !filter.filterKinds.isEmpty {
            liveReps = computeRepresentativesForKinds(filter.filterKinds, groups: shotGroups, entries: entries)
        } else {
            liveReps = computeRepresentatives(groups: shotGroups, entries: entries)
        }
        let reps = orderedIDs.filter { liveReps.contains($0) }
        let filtered: [UInt64]
        if !filter.isActive {
            filtered = reps
        } else {
            filtered = reps.filter { id in
                guard let entry = entries[id] else { return false }
                return filter.matches(entry: entry, exif: exifData[id], xmp: xmpData[id])
            }
        }
        visibleIDs = sortedIDs(filtered)
    }

    func applyOrder() { recomputeVisible() }

    private func sortedIDs(_ ids: [UInt64]) -> [UInt64] {
        let key = settings.sortKey
        let asc = settings.sortAscending
        return ids.sorted { a, b in
            let cmp = compareIDs(a, b, key: key)
            if cmp != .orderedSame {
                return asc ? cmp == .orderedAscending : cmp == .orderedDescending
            }
            let an = entries[a]?.filename ?? ""
            let bn = entries[b]?.filename ?? ""
            return an < bn
        }
    }

    private func compareIDs(_ a: UInt64, _ b: UInt64, key: SortKey) -> ComparisonResult {
        switch key {
        case .filename:
            return (entries[a]?.filename ?? "").compare(entries[b]?.filename ?? "")
        case .createdDate:
            let da = entries[a]?.createdDate ?? .distantPast
            let db = entries[b]?.createdDate ?? .distantPast
            return da.compare(db)
        case .modifiedDate:
            let da = entries[a]?.modifiedDate ?? .distantPast
            let db = entries[b]?.modifiedDate ?? .distantPast
            return da.compare(db)
        case .fileSize:
            let sa = entries[a]?.fileSize ?? 0
            let sb = entries[b]?.fileSize ?? 0
            return sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
        case .rating:
            let ra = xmpData[a]?.rating ?? 0
            let rb = xmpData[b]?.rating ?? 0
            return ra == rb ? .orderedSame : (ra < rb ? .orderedAscending : .orderedDescending)
        }
    }

    var availableCameras: [String] {
        Array(Set(exifData.values.compactMap { $0.cameraName })).sorted()
    }

    var availableLenses: [String] {
        Array(Set(exifData.values.compactMap { $0.lensName })).sorted()
    }

    var availableArtists: [String] {
        Array(Set(exifData.values.compactMap { $0.artist })).sorted()
    }

    // MARK: - Private

    func setThumbnail(id: UInt64, image: CGImage) {
        pendingThumbnails[id] = image
        guard thumbnailFlushTask == nil else { return }
        thumbnailFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            thumbnailImages.merge(pendingThumbnails) { _, new in new }
            pendingThumbnails = [:]
            thumbnailFlushTask = nil
        }
    }

    func setExif(id: UInt64, exif: ExifData?) {
        guard let exif else { return }
        pendingExif[id] = exif
        scheduleMetaFlush()
    }

    func setXmp(id: UInt64, xmp: XmpData?) {
        guard let xmp else { return }
        pendingXmp[id] = xmp
        scheduleMetaFlush()
    }

    private func scheduleMetaFlush() {
        guard metaFlushTask == nil else { return }
        metaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            exifData.merge(pendingExif) { _, new in new }
            xmpData.merge(pendingXmp) { _, new in new }
            pendingExif = [:]
            pendingXmp = [:]
            metaFlushTask = nil
            recomputeVisible()
        }
    }

    func applyReindexedGroups(_ groups: [UInt64: [UInt64]]) {
        // Update each entry's shotId to match its reindexed group key
        for (shotId, memberIds) in groups {
            for memberId in memberIds {
                entries[memberId]?.shotId = shotId
            }
        }
        shotGroups = groups
        recomputeVisible()
    }

    // MARK: - Tab lifecycle

    func suspend() {
        thumbnailImages = [:]
    }

    func resume() {
        guard let db = database, !orderedIDs.isEmpty else { return }
        let entriesToLoad = orderedIDs.compactMap { entries[$0] }
        let capturedPhash = phashPipeline
        Task {
            await ThumbnailPipeline.loadAll(entries: entriesToLoad, store: self, db: db, phashPipeline: capturedPhash)
        }
    }

    private func reset() {
        entries = [:]
        orderedIDs = []
        shotGroups = [:]
        thumbnailImages = [:]
        exifData = [:]
        xmpData = [:]
        visibleIDs = []
        selectedIDs = []
        primaryID = nil
        anchorID = nil
        undoStack = []
        undoMessage = nil
        undoMessageTask?.cancel()
        undoMessageTask = nil
        thumbnailFlushTask?.cancel()
        thumbnailFlushTask = nil
        metaFlushTask?.cancel()
        metaFlushTask = nil
        pendingThumbnails = [:]
        pendingExif = [:]
        pendingXmp = [:]
        viewerMode = false
        compareMode = false
        compareAnchorID = nil
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
        recomputeVisible()
    }

    private func isDevelopedMember(_ id: UInt64, groupMinDate: Date?) -> Bool {
        guard let entry = entries[id], !entry.isRaw else { return false }
        if entry.hasDevelopedSuffix { return true }
        if xmpData[id]?.developed == true { return true }
        if exifData[id]?.isDeveloped == true { return true }
        if let created = entry.createdDate, let minDate = groupMinDate,
           created.timeIntervalSince(minDate) > 60 { return true }
        return false
    }

    private func computeRepresentativesForKinds(
        _ kinds: Set<PhotoKind>,
        groups: [UInt64: [UInt64]],
        entries: [UInt64: PhotoEntry]
    ) -> Set<UInt64> {
        var reps = Set<UInt64>()

        for (_, members) in groups {
            guard !members.isEmpty else { continue }

            let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()

            var devMembers: [UInt64] = []
            var soocMembers: [UInt64] = []
            var rawMembers: [UInt64] = []

            for id in members {
                guard let entry = entries[id] else { continue }
                if entry.isRaw {
                    rawMembers.append(id)
                } else if isDevelopedMember(id, groupMinDate: groupMinDate) {
                    devMembers.append(id)
                } else {
                    soocMembers.append(id)
                }
            }

            // 現像済み: developed かつ SOOC が同グループに存在する場合のみ
            if kinds.contains(.developed), !devMembers.isEmpty, !soocMembers.isEmpty {
                reps.insert(devMembers[0])
            // カメラ出力: SOOC が存在するグループ
            } else if kinds.contains(.sooc), !soocMembers.isEmpty {
                reps.insert(soocMembers[0])
            // RAW: グループ内で最新タイムスタンプの RAW
            } else if kinds.contains(.raw), !rawMembers.isEmpty {
                let newest = rawMembers.max {
                    (entries[$0]?.createdDate ?? .distantPast) < (entries[$1]?.createdDate ?? .distantPast)
                }!
                reps.insert(newest)
            }
        }

        return reps
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

    private func entryKind(id: UInt64, entry: PhotoEntry, groupMinDate: Date?) -> PhotoKind {
        if entry.isRaw { return .raw }
        if isDevelopedMember(id, groupMinDate: groupMinDate) { return .developed }
        return .sooc
    }

    private func groupTargets(for id: UInt64, entry: PhotoEntry) -> [UInt64] {
        guard let members = shotGroups[entry.shotId], !members.isEmpty else { return [id] }
        let groupMinDate = members.compactMap { entries[$0]?.createdDate }.min()
        let sourceKind   = entryKind(id: id, entry: entry, groupMinDate: groupMinDate)
        let targetKinds  = settings.propagationMatrix.targets(for: sourceKind)
        return members.filter { mid in
            guard let me = entries[mid] else { return false }
            return targetKinds.contains(entryKind(id: mid, entry: me, groupMinDate: groupMinDate))
        }
    }

    private func dbURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("BridgeLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.db")
    }
}
