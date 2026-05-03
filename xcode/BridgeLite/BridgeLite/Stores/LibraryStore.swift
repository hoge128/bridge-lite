import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class LibraryStore {
    // エントリ一覧
    private(set) var entries: [UInt64: PhotoEntry] = [:]
    private(set) var orderedIDs: [UInt64] = []
    private(set) var shotGroups: [UInt64: [UInt64]] = [:]

    // @Observable state — UI が自動更新される
    private(set) var thumbnailBlobs: [UInt64: Data] = [:]
    private(set) var exifData: [UInt64: ExifData] = [:]
    private(set) var xmpData: [UInt64: XmpData] = [:]
    // RAW サムネイルの向き（埋め込み JPEG は orientation タグを持たないため別管理）
    var thumbnailOrientations: [UInt64: Image.Orientation] = [:]

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
    var viewerShowsMeta: Bool = false
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
    var depthExceeded: Bool = false

    enum ScanPhase { case idle, preScanning, scanning, loading }
    private(set) var scanPhase: ScanPhase = .idle
    private(set) var preScanTotalFiles: Int = 0
    private(set) var preScanImageFiles: Int = 0
    private(set) var loadedThumbnailCount: Int = 0

    // Undo
    private var undoStack: [(description: String, perform: () -> Void)] = []
    private(set) var undoMessage: String?
    private var undoMessageTask: Task<Void, Never>?
    var canUndo: Bool { !undoStack.isEmpty }

    // Batch flush — coalesces rapid dict mutations to reduce @Observable invalidation frequency
    private var pendingThumbnails: [UInt64: Data] = [:]
    private var thumbnailFlushTask: Task<Void, Never>?
    private var pendingExif: [UInt64: ExifData] = [:]
    private var pendingXmp: [UInt64: XmpData] = [:]
    private var metaFlushTask: Task<Void, Never>?

    // Per-entry change subjects — セルが自分の id のみ購読することで dict 全体観測を回避する
    let thumbnailDidUpdate = PassthroughSubject<UInt64, Never>()
    let exifDidUpdate = PassthroughSubject<UInt64, Never>()
    let xmpDidUpdate = PassthroughSubject<UInt64, Never>()

    // フォルダ切替時にキャンセルする fire-and-forget タスク
    private var exifLoadTask: Task<Void, Never>?
    private var thumbnailLoadTask: Task<Void, Never>?
    // フォルダオープン本体タスク（ユーザーがキャンセル可能）
    private var openDirTask: Task<Void, Never>?
    // プリスキャンタスク（Task.detached なので明示的にキャンセルが必要）
    private var preScanTask: Task<(Int, Int), Error>?

    private(set) var currentDirectoryURL: URL?
    private var database: BridgeCoreDatabase?
    var cacheDatabase: BridgeCoreDatabase? { database }
    private var lastImageList: BridgeCoreImageList?

    // MARK: - Folder watch state
    private var watcher: FolderWatcher?
    private var pausedWatcherEventId: FSEventStreamEventId?
    private var nextEntryID: UInt64 = 1

    // MARK: - 公開アクション

    func requestOpenFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "Open Folder")
        if panel.runModal() == .OK, let url = panel.url {
            if settings.warnSlowStorage {
                let kind = StorageProbe.probe(url: url)
                if kind == .rotational || kind == .network {
                    guard confirmSlowStorage(kind: kind) else { return }
                }
            }
            loadFolder(url)
        }
    }

    /// D&D・URL open・タブ切替など全エントリポイント共通のフォルダ開始メソッド。
    /// openDirTask を登録することで cancelLoading() が全ルートで効くようになる。
    func loadFolder(_ url: URL) {
        cancelLoading()
        openDirTask = Task { await openDirectory(url) }
    }

    private func confirmSlowStorage(kind: StorageKind) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.slow_storage.title",
                                   defaultValue: "This folder is on slow storage")
        alert.informativeText = kind == .rotational
            ? String(localized: "alert.slow_storage.message.hdd",
                     defaultValue: "The selected folder is on a rotational hard disk. Scanning may take significantly longer than on an SSD, and overall app performance may be reduced. For best results, copy the photos to internal SSD storage first.")
            : String(localized: "alert.slow_storage.message.network",
                     defaultValue: "The selected folder is on a network volume. Scanning will be slow and unreliable on unstable connections.")
        alert.addButton(withTitle: String(localized: "alert.slow_storage.continue",
                                          defaultValue: "Continue"))
        alert.addButton(withTitle: String(localized: "alert.slow_storage.cancel",
                                          defaultValue: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "alert.slow_storage.suppress",
                                                defaultValue: "Don't warn me again")

        let resp = alert.runModal()
        if alert.suppressionButton?.state == .on { settings.warnSlowStorage = false }
        return resp == .alertFirstButtonReturn
    }

    func cancelLoading() {
        watcher?.stop()
        preScanTask?.cancel()
        preScanTask = nil
        openDirTask?.cancel()
        openDirTask = nil
        exifLoadTask?.cancel()
        exifLoadTask = nil
        // thumbnailLoadTask は openDirectory 内で await しているため
        // openDirTask.cancel() でキャンセルが伝播する。resume() 経由のみ別途キャンセル。
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        scanPhase = .idle
        guard isLoading else { return }
        isLoading = false
        if orderedIDs.isEmpty {
            statusMessage = ""
            currentDirectoryURL = nil
        } else {
            statusMessage = String(format: String(localized: "%d photos"), orderedIDs.count)
        }
    }

    func openDirectory(_ url: URL) async {
        guard !isLoading else { return }
        isLoading = true
        depthExceeded = false
        scanPhase = .preScanning
        preScanTotalFiles = 0
        preScanImageFiles = 0
        loadedThumbnailCount = 0
        statusMessage = String(localized: "Counting files…")
        reset()
        currentDirectoryURL = url

        do {
            // Phase 1: プリスキャン（拡張子カウント）
            let (total, images) = try await runPreScan(url: url)
            try Task.checkCancellation()
            preScanTotalFiles = total
            preScanImageFiles = images

            // Phase 2: BridgeCore スキャン（Rust FFI、ブラックボックス）
            scanPhase = .scanning
            statusMessage = String(
                format: String(localized: "Scanning %d images…"),
                images
            )

            let db = try BridgeCoreDatabase.open(path: dbURL())
            database = db

            let scanned: [PhotoEntry]
            do {
                let (entries, list) = try await BridgeCore.scanDirectory(url: url, db: db)
                scanned = entries
                lastImageList = list
            } catch is CancellationError {
                scanPhase = .idle
                return
            } catch {
                scanned = try await scanPipeline.scan(url: url)
            }
            try Task.checkCancellation()
            ingest(scanned)

            // 深さ超過チェック（スキャンをブロックしない）
            Task { [weak self] in
                guard let self else { return }
                self.depthExceeded = await BridgeCore.hasImagesBeyondScanDepth(url: url)
            }

            // 並行: EXIF バッチ（1 connection）+ XMP 並列
            let allEntries = orderedIDs.compactMap { entries[$0] }
            let capturedList = lastImageList
            exifLoadTask = Task { [weak self] in
                guard let self else { return }

                // EXIF: 全件を 1 SQLite 接続で取得（fetch_exif_batch が 500 件チャンク IN 句を使用）
                if let imageList = capturedList {
                    let exifMap = await BridgeCore.fetchExifBatch(list: imageList, db: db)
                    await self.mergeExifBatch(exifMap)
                }

                // XMP: 8 並列で読み込み（XMP batch は将来対応）
                let xmpLimiter = ConcurrencyLimiter(maxConcurrent: 8)
                let jpgWriteMode = settings.jpgWriteMode
                await withTaskGroup(of: Void.self) { group in
                    for entry in allEntries {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            try? await xmpLimiter.run {
                                let xmp = await BridgeCore.readXmp(url: entry.url, jpgWriteMode: jpgWriteMode)
                                await self.setXmp(id: entry.id, xmp: xmp)
                            }
                        }
                    }
                }

                await pairingPipeline.noteExifReady(list: capturedList, db: db, store: self, splitThresholdSecs: Int64(settings.groupingSplitThresholdSecs), phashHammingThreshold: UInt32(settings.groupingPhashHammingThreshold))
            }

            // Phase 3: サムネイル → pHash → shot-group reindex（直列チェーン）
            // thumbnailLoadTask に入れず直接 await することで isLoading / scanPhase を
            // サムネイル完了まで維持し、オーバーレイの X/Y 進捗を最後まで表示させる。
            scanPhase = .loading
            statusMessage = String(
                format: String(localized: "Loading %d / %d"),
                0, orderedIDs.count
            )
            // visibleIDs (sort order) first so top-of-grid thumbnails appear before off-screen ones
            let visibleSet = Set(visibleIDs)
            let entriesToLoad = visibleIDs.compactMap { entries[$0] }
                + orderedIDs.filter { !visibleSet.contains($0) }.compactMap { entries[$0] }
            let capturedPhash = phashPipeline
            let capturedPairing = pairingPipeline
            await ThumbnailPipeline.loadAll(entries: entriesToLoad, store: self, db: db, phashPipeline: capturedPhash)
            await capturedPhash.waitForAllPending()
            await capturedPairing.notePhashReady(list: capturedList, db: db, store: self, splitThresholdSecs: Int64(settings.groupingSplitThresholdSecs), phashHammingThreshold: UInt32(settings.groupingPhashHammingThreshold))
            settings.appliedGroupingSplitThresholdSecs = settings.groupingSplitThresholdSecs
            settings.appliedGroupingPhashHammingThreshold = settings.groupingPhashHammingThreshold

            statusMessage = String(
                format: String(localized: "%d photos"),
                orderedIDs.count
            )
        } catch is CancellationError {
            // cancelLoading() が既に isLoading / currentDirectoryURL をリセット済み
            scanPhase = .idle
            return
        } catch {
            scanPhase = .idle
            statusMessage = error.localizedDescription
        }
        isLoading = false
        scanPhase = .idle
        startFolderWatchIfEnabled()
    }

    // MARK: - プリスキャン

    /// BridgeCore スキャン前にファイル数を素早く数えて分母を確定する。
    /// AsyncStream で 100 件ごとに live update し、完了時に最終値を返す。
    private func runPreScan(url: URL) async throws -> (Int, Int) {
        guard preScanTask == nil else { return (0, 0) }

        // [weak self] で MainActor に hop するため await を使う。
        // Task.detached 内の await self?.updatePreScanCounts(...) が
        // 100 件ごとに MainActor へ制御を渡し、UI を確実に更新する。
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> (Int, Int) in
            let supported = ScanPipeline.supportedExtensionsSet
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return (0, 0) }
            var total = 0, images = 0
            while let obj = enumerator.nextObject() {
                try Task.checkCancellation()
                guard let fileURL = obj as? URL else { continue }
                if fileURL.hasDirectoryPath { continue }
                total += 1
                if supported.contains(fileURL.pathExtension.lowercased()) { images += 1 }
                if total % 100 == 0 {
                    await self?.updatePreScanCounts(total: total, images: images)
                }
            }
            return (total, images)
        }
        preScanTask = task
        defer { preScanTask = nil }
        let result = try await task.value
        updatePreScanCounts(total: result.0, images: result.1)
        return result
    }

    private func updatePreScanCounts(total: Int, images: Int) {
        preScanTotalFiles = total
        preScanImageFiles = images
        statusMessage = String(
            format: String(localized: "Counting… %d images"),
            images
        )
    }

    // MARK: - サムネイル進捗

    /// サムネイル生成の試行完了を記録（成功・失敗問わず呼ぶこと）。
    /// scanPhase == .loading のときのみカウントし、resume() 時の二重カウントを防ぐ。
    func noteThumbnailAttemptFinished() {
        guard scanPhase == .loading else { return }
        loadedThumbnailCount += 1
        let total = orderedIDs.count
        // navigationTitle への負荷を抑えるため 50 件ごとまたは最終件で更新
        let isLast = loadedThumbnailCount >= total
        if isLast || loadedThumbnailCount % 50 == 0 {
            statusMessage = String(
                format: String(localized: "Loading %d / %d"),
                loadedThumbnailCount, total
            )
        }
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
        showUndoMessage(String(localized: "Undid: \(record.description)"))
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
        switch settings.copyScopeMode {
        case .representative: mode = .representativeOnly
        case .allInGroup:     mode = .allInGroup
        case .askEachTime:
            guard let m = showCopyAlert() else { return }
            mode = m
        }
        copySelectedFiles(mode: mode)
    }

    private func showCopyAlert() -> CopyMode? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Choose copy scope")
        let count = selectedIDs.count
        alert.informativeText = String(localized: "Files from \(count) group(s) will be copied.")
        let hasKindFilter = !filter.filterKinds.isEmpty
        alert.addButton(withTitle: String(localized: "Representative only"))
        if hasKindFilter { alert.addButton(withTitle: String(localized: "Filtered kind only")) }
        alert.addButton(withTitle: String(localized: "Entire group"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        let resp = alert.runModal()
        let chosen: CopyMode?
        switch resp {
        case .alertFirstButtonReturn:  chosen = .representativeOnly
        case .alertSecondButtonReturn: chosen = hasKindFilter ? .filteredKindOnly : .allInGroup
        case .alertThirdButtonReturn:  chosen = hasKindFilter ? .allInGroup : nil
        default: chosen = nil
        }
        if alert.suppressionButton?.state == .on, let c = chosen {
            switch c {
            case .representativeOnly: settings.copyScopeMode = .representative
            case .allInGroup:         settings.copyScopeMode = .allInGroup
            case .filteredKindOnly:   settings.copyScopeMode = .representative
            }
        }
        return chosen
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
                        : isDevelopedMember(mid, groupMinDate: groupMinDate) ? .developed
                        : isIndeterminateMember(mid) ? .indeterminate : .sooc
                    if filter.filterKinds.contains(kind) { add(mentry.url) }
                }
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// D&D の urlsProvider に渡す URL 配列を scope に従って生成する。
    func urlsFor(ids: Set<UInt64>, scope: GroupScopeMode) -> [URL] {
        var result: [URL] = []
        var seen = Set<URL>()
        func add(_ url: URL) { if seen.insert(url).inserted { result.append(url) } }
        for id in ids {
            guard let entry = entries[id] else { continue }
            if scope == .allInGroup {
                let members = shotGroups[entry.shotId] ?? [id]
                members.compactMap { entries[$0]?.url }.forEach { add($0) }
            } else {
                add(entry.url)
            }
        }
        return result
    }

    // MARK: - 削除

    func triggerDelete() {
        guard !selectedIDs.isEmpty else { return }
        switch settings.deleteScopeMode {
        case .representative: deleteSelectedRepresentatives()
        case .allInGroup:     deleteSelectedGroups()
        case .askEachTime:
            guard let scope = showDeleteAlert() else { return }
            if scope == .representative { deleteSelectedRepresentatives() }
            else { deleteSelectedGroups() }
        }
    }

    private func showDeleteAlert() -> GroupScopeMode? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Choose delete scope")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Representative only"))
        alert.addButton(withTitle: String(localized: "Entire group"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")

        let resp = alert.runModal()
        let chosen: GroupScopeMode?
        switch resp {
        case .alertFirstButtonReturn:  chosen = .representative
        case .alertSecondButtonReturn: chosen = .allInGroup
        default: chosen = nil
        }
        if alert.suppressionButton?.state == .on, let c = chosen {
            settings.deleteScopeMode = c
        }
        return chosen
    }

    private func deleteSelectedRepresentatives() {
        var deletedIDs: Set<UInt64> = []
        var fileCount = 0
        for repId in selectedIDs {
            guard let entry = entries[repId] else { continue }
            try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            let xmpURL = entry.url.deletingPathExtension().appendingPathExtension("xmp")
            if FileManager.default.fileExists(atPath: xmpURL.path) {
                try? FileManager.default.trashItem(at: xmpURL, resultingItemURL: nil)
            }
            deletedIDs.insert(repId)
            fileCount += 1
        }
        for id in deletedIDs {
            entries.removeValue(forKey: id)
            thumbnailBlobs.removeValue(forKey: id)
            luminanceScores.removeValue(forKey: id)
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
        showUndoMessage(String(localized: "Moved \(fileCount) file(s) to Trash (recoverable from Finder)"))
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
            thumbnailBlobs.removeValue(forKey: id)
            luminanceScores.removeValue(forKey: id)
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
        showUndoMessage(String(localized: "Moved \(fileCount) file(s) to Trash (recoverable from Finder)"))
    }

    // MARK: - 一括評価トリガー

    func triggerRating(_ stars: Int) {
        guard !selectedIDs.isEmpty else { return }
        if selectedIDs.count > 1 && settings.confirmBulkRating {
            let ratingLabel = stars == 0
                ? String(localized: "No Rating")
                : String(repeating: "★", count: stars)
            let count = selectedIDs.count
            let alert = NSAlert()
            alert.messageText = String(localized: "Set \"\(ratingLabel)\" for \(count) photo(s)?")
            alert.informativeText = String(localized: "Existing ratings will be overwritten.")
            alert.addButton(withTitle: String(localized: "Apply"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Don't ask again")

            let resp = alert.runModal()
            if alert.suppressionButton?.state == .on { settings.confirmBulkRating = false }
            if resp != .alertFirstButtonReturn { return }
        }
        applyRating(stars)
    }

    func applyRating(_ stars: Int) {
        guard !selectedIDs.isEmpty, let db = database else { return }
        var allTargets: [(entry: PhotoEntry, old: Int?)] = []
        var writeList:  [(entry: PhotoEntry, xmp: XmpData)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            let targets: [UInt64] = filter.flatten ? [id] : groupTargets(for: id, entry: entry)
            for targetID in targets {
                guard let te = entries[targetID] else { continue }
                allTargets.append((entry: te, old: xmpData[targetID]?.rating))
                var current = xmpData[targetID] ?? XmpData()
                current.rating = stars == 0 ? nil : stars
                xmpData[targetID] = current
                xmpDidUpdate.send(targetID)
                writeList.append((te, current))
            }
        }
        recomputeVisible()
        let desc = stars == 0
            ? String(localized: "Clear Rating")
            : String(localized: "Rating \(stars) Star(s)")
        registerUndo(description: desc) { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.rating = old
                self.xmpData[te.id] = current
                self.xmpDidUpdate.send(te.id)
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db, jpgWriteMode: self.settings.jpgWriteMode) }
            }
            self.recomputeVisible()
        }
        let mode = settings.jpgWriteMode
        let policy = settings.jpgSidecarConflictPolicy
        Task {
            for (te, x) in writeList {
                _ = await BridgeCore.writeXmp(url: te.url, xmp: x, db: db, jpgWriteMode: mode)
            }
            if mode == .sidecar {
                await self.checkAndHandleEmbedConflict(writeList: writeList, db: db, policy: policy)
            }
        }
    }

    func applyLabel(_ labelRaw: UInt8) {
        guard !selectedIDs.isEmpty, let db = database,
              let label = XmpLabel(rawValue: labelRaw) else { return }
        let pivot = primaryID.flatMap { xmpData[$0]?.label }
        let newLabel: XmpLabel? = pivot == label ? nil : label
        var allTargets: [(entry: PhotoEntry, old: XmpLabel?)] = []
        var writeList:  [(entry: PhotoEntry, xmp: XmpData)] = []
        for id in selectedIDs {
            guard let entry = entries[id] else { continue }
            let targets: [UInt64] = filter.flatten ? [id] : groupTargets(for: id, entry: entry)
            for targetID in targets {
                guard let te = entries[targetID] else { continue }
                allTargets.append((entry: te, old: xmpData[targetID]?.label))
                var current = xmpData[targetID] ?? XmpData()
                current.label = newLabel
                xmpData[targetID] = current
                xmpDidUpdate.send(targetID)
                writeList.append((te, current))
            }
        }
        recomputeVisible()
        registerUndo(description: String(localized: "Label Change")) { [weak self] in
            guard let self, let db = self.database else { return }
            for (te, old) in allTargets {
                guard self.entries[te.id] != nil else { continue }
                var current = self.xmpData[te.id] ?? XmpData()
                current.label = old
                self.xmpData[te.id] = current
                self.xmpDidUpdate.send(te.id)
                let x = current; let url = te.url
                Task { _ = await BridgeCore.writeXmp(url: url, xmp: x, db: db, jpgWriteMode: self.settings.jpgWriteMode) }
            }
            self.recomputeVisible()
        }
        let mode = settings.jpgWriteMode
        let policy = settings.jpgSidecarConflictPolicy
        Task {
            for (te, x) in writeList {
                _ = await BridgeCore.writeXmp(url: te.url, xmp: x, db: db, jpgWriteMode: mode)
            }
            if mode == .sidecar {
                await self.checkAndHandleEmbedConflict(writeList: writeList, db: db, policy: policy)
            }
        }
    }

    // MARK: - 埋め込み XMP 競合ハンドラ

    private func checkAndHandleEmbedConflict(
        writeList: [(entry: PhotoEntry, xmp: XmpData)],
        db: BridgeCoreDatabase,
        policy: JpgSidecarConflictPolicy
    ) async {
        guard policy != .neverPropagate else { return }

        var conflicting: [(entry: PhotoEntry, xmp: XmpData)] = []
        for (entry, xmp) in writeList {
            guard !entry.isRaw else { continue }
            let hasEmbedded = await BridgeCore.jpgHasRatedEmbeddedXmp(url: entry.url)
            if hasEmbedded { conflicting.append((entry, xmp)) }
        }
        guard !conflicting.isEmpty else { return }

        let shouldPropagate: Bool
        if policy == .alwaysPropagate {
            shouldPropagate = true
        } else {
            shouldPropagate = showEmbedConflictAlert(conflicting: conflicting)
        }

        if shouldPropagate {
            for (entry, xmp) in conflicting {
                _ = await BridgeCore.writeXmp(url: entry.url, xmp: xmp, db: db, jpgWriteMode: .embed)
            }
        }
    }

    @MainActor
    private func showEmbedConflictAlert(conflicting: [(entry: PhotoEntry, xmp: XmpData)]) -> Bool {
        let count = conflicting.count
        let listedFiles = conflicting.prefix(10).map { "• \($0.entry.filename)" }.joined(separator: "\n")
        let remainder = count > 10
            ? "\n" + String(format: String(localized: "alert.embed_conflict.more",
                                           defaultValue: "…and %lld more file(s)"), count - 10)
            : ""

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.embed_conflict.title",
                                   defaultValue: "Embedded XMP Detected")
        alert.informativeText = String(format: String(localized: "alert.embed_conflict.header",
                                                      defaultValue: "%lld JPEG file(s) already have ratings or labels embedded directly. Propagate the new value to the embedded XMP as well?"), count)
                                + "\n\n" + listedFiles + remainder
        alert.addButton(withTitle: String(localized: "alert.embed_conflict.propagate", defaultValue: "Propagate"))
        alert.addButton(withTitle: String(localized: "alert.embed_conflict.skip",      defaultValue: "Skip"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "alert.embed_conflict.suppress",
                                                defaultValue: "Remember this choice")

        let resp = alert.runModal()
        let propagate = resp == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            settings.jpgSidecarConflictPolicy = propagate ? .alwaysPropagate : .neverPropagate
        }
        return propagate
    }


    // MARK: - Computed

    private func recomputeVisible() {
        let liveReps: Set<UInt64>
        if filter.flatten {
            liveReps = Set(orderedIDs)
        } else if !filter.filterKinds.isEmpty {
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
                return filter.matches(entry: entry, exif: exifData[id], xmp: xmpData[id], luminance: luminanceScores[id])
            }
        }
        visibleIDs = sortedIDs(filtered)
        if settings.viewMode == .daily {
            rebuildDailyGroups()
        }
        recomputeAggregates(reps: reps)
    }

    func applyOrder() { recomputeVisible() }

    private func filteredIDs(using customFilter: FilterCriteria) -> [UInt64] {
        let liveReps: Set<UInt64>
        if filter.flatten {
            liveReps = Set(orderedIDs)
        } else if !filter.filterKinds.isEmpty {
            liveReps = computeRepresentativesForKinds(filter.filterKinds, groups: shotGroups, entries: entries)
        } else {
            liveReps = computeRepresentatives(groups: shotGroups, entries: entries)
        }
        let reps = orderedIDs.filter { liveReps.contains($0) }
        guard customFilter.isActive else { return reps }
        return reps.filter { id in
            guard let entry = entries[id] else { return false }
            return customFilter.matches(entry: entry, exif: exifData[id], xmp: xmpData[id], luminance: luminanceScores[id])
        }
    }

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
        case .exifDate:
            return photoDate(for: a).compare(photoDate(for: b))
        }
    }

    // Aggregate cache — recomputed by recomputeAggregates() inside recomputeVisible()
    private(set) var availableExtensions: [String] = []
    private(set) var availableCameras: [String] = []
    private(set) var availableLenses: [String] = []
    private(set) var availableArtists: [String] = []
    private(set) var isoBuckets: [ExifBucket] = []
    private(set) var focalBuckets: [ExifBucket] = []
    private(set) var shutterBuckets: [ExifBucket] = []
    private(set) var apertureBuckets: [ExifBucket] = []
    private(set) var dateBuckets: [ExifBucket] = []
    private(set) var luminanceBuckets: [ExifBucket] = []

    // 輝度スコア（0–255）— サムネイル到着後にバックグラウンド計算
    private(set) var luminanceScores: [UInt64: Int] = [:]

    // MARK: - Daily grouping
    // [BETA DISABLED] ViewModePicker 非表示中は到達しない。削除しないこと。

    struct DailyGroup: Identifiable {
        let date: Date
        let ids: [UInt64]
        var id: Date { date }
    }

    // view body は stored array を O(1) で読むだけ。@Observable の自動追跡で
    // body が 20Hz 再評価されても重い日付パース処理は走らない。
    private(set) var dailyGroups: [DailyGroup] = []

    private func rebuildDailyGroups() {
        let cal = Calendar.current
        var grouped: [Date: [UInt64]] = [:]
        for id in visibleIDs {
            let day = cal.startOfDay(for: photoDate(for: id))
            grouped[day, default: []].append(id)
        }
        let asc = settings.sortAscending
        let sortedDays = grouped.keys.sorted { asc ? $0 < $1 : $0 > $1 }
        dailyGroups = sortedDays.map { DailyGroup(date: $0, ids: grouped[$0]!) }
    }

    func refreshDailyGroupsIfNeeded() {
        guard settings.viewMode == .daily else { return }
        rebuildDailyGroups()
    }

    func photoDate(for id: UInt64) -> Date {
        if let dt = exifData[id]?.datetime, let d = Self.exifDateParser.date(from: dt) { return d }
        return entries[id]?.createdDate ?? .distantPast
    }

    private static let exifDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    // MARK: - Aggregate cache

    private enum HistogramAxis { case iso, focal, shutter, aperture, date, luminance }

    private func filteredIDsExcluding(_ axis: HistogramAxis, from reps: [UInt64]) -> [UInt64] {
        var f = filter
        switch axis {
        case .iso:       f.isoMin = "";       f.isoMax = ""
        case .focal:     f.focalMin = "";     f.focalMax = ""
        case .shutter:   f.shutterMin = "";   f.shutterMax = ""
        case .aperture:  f.apertureMin = "";  f.apertureMax = ""
        case .date:      f.dateMin = "";      f.dateMax = ""
        case .luminance: f.luminanceMin = ""; f.luminanceMax = ""
        }
        guard f.isActive else { return reps }
        return reps.filter { id in
            guard let entry = entries[id] else { return false }
            return f.matches(entry: entry, exif: exifData[id], xmp: xmpData[id], luminance: luminanceScores[id])
        }
    }

    private func recomputeAggregates(reps: [UInt64]) {
        availableExtensions = Array(Set(entries.values.map { $0.url.pathExtension.lowercased() }).filter { !$0.isEmpty }).sorted()
        availableCameras = Array(Set(exifData.values.compactMap { $0.cameraName })).sorted()
        availableLenses = Array(Set(exifData.values.compactMap { $0.lensName })).sorted()
        availableArtists = Array(Set(exifData.values.compactMap { $0.artist })).sorted()
        isoBuckets = buildISOBuckets(ids: filteredIDsExcluding(.iso, from: reps))
        focalBuckets = buildFocalBuckets(ids: filteredIDsExcluding(.focal, from: reps))
        shutterBuckets = buildShutterBuckets(ids: filteredIDsExcluding(.shutter, from: reps))
        apertureBuckets = buildApertureBuckets(ids: filteredIDsExcluding(.aperture, from: reps))
        dateBuckets = buildDateBuckets(ids: filteredIDsExcluding(.date, from: reps))
        luminanceBuckets = buildLuminanceBuckets(ids: filteredIDsExcluding(.luminance, from: reps))
    }

    private func buildISOBuckets(ids: [UInt64]) -> [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤100",   100,      "",     "100"),
            ("200",    200,      "101",  "200"),
            ("400",    400,      "201",  "400"),
            ("800",    800,      "401",  "800"),
            ("1.6k",   1600,     "801",  "1600"),
            ("3.2k",   3200,     "1601", "3200"),
            ("6.4k",   6400,     "3201", "6400"),
            (">6k",    .infinity, "6401", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for id in ids {
            guard let iso = exifData[id]?.iso else { continue }
            let d = Double(iso)
            for (i, spec) in specs.enumerated() { if d <= spec.upTo { counts[i] += 1; break } }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    private func buildFocalBuckets(ids: [UInt64]) -> [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤24",   24,       "",    "24"),
            ("35",    35,       "24",  "35"),
            ("50",    50,       "35",  "50"),
            ("85",    85,       "50",  "85"),
            ("135",   135,      "85",  "135"),
            ("200",   200,      "135", "200"),
            (">200",  .infinity, "200", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for id in ids {
            guard let mm = exifData[id]?.effectiveFocalMm else { continue }
            for (i, spec) in specs.enumerated() { if mm <= spec.upTo { counts[i] += 1; break } }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    private func buildShutterBuckets(ids: [UInt64]) -> [ExifBucket] {
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
        for id in ids {
            guard let s = exifData[id]?.shutterSeconds else { continue }
            for (i, spec) in specs.enumerated() { if s <= spec.upTo { counts[i] += 1; break } }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    private func buildApertureBuckets(ids: [UInt64]) -> [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤1.8",  1.8,      "",    "1.8"),
            ("2.8",   2.8,      "1.8", "2.8"),
            ("4",     4.0,      "2.8", "4"),
            ("5.6",   5.6,      "4",   "5.6"),
            ("8",     8.0,      "5.6", "8"),
            ("11",    11.0,     "8",   "11"),
            (">11",   .infinity, "11",  ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for id in ids {
            guard let f = exifData[id]?.fnumberValue else { continue }
            for (i, spec) in specs.enumerated() { if f <= spec.upTo { counts[i] += 1; break } }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    private func buildDateBuckets(ids: [UInt64]) -> [ExifBucket] {
        let cal = Calendar.current
        let dates = ids.compactMap { id -> Date? in
            let d = photoDate(for: id)
            return d == .distantPast ? nil : d
        }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return [] }
        let daySpan = cal.dateComponents([.day], from: minDate, to: maxDate).day ?? 0
        return daySpan <= 14
            ? buildDailyDateBuckets(dates: dates, from: minDate, to: maxDate)
            : buildMonthlyDateBuckets(dates: dates, from: minDate, to: maxDate)
    }

    private func buildMonthlyDateBuckets(dates: [Date], from minDate: Date, to maxDate: Date) -> [ExifBucket] {
        let cal = Calendar.current
        let isoFmt = Self.isoDateFormatter
        let lblFmt = Self.monthLabelFormatter
        let multiYear = cal.component(.year, from: minDate) != cal.component(.year, from: maxDate)
        var buckets: [ExifBucket] = []
        var cursor = cal.date(from: cal.dateComponents([.year, .month], from: minDate))!
        while cursor <= maxDate {
            let nextMonth = cal.date(byAdding: .month, value: 1, to: cursor)!
            let lastDay = cal.date(byAdding: .day, value: -1, to: nextMonth)!
            let count = dates.filter { $0 >= cursor && $0 < nextMonth }.count
            let label: String
            if multiYear {
                let m = cal.component(.month, from: cursor)
                let y = cal.component(.year, from: cursor) % 100
                label = String(format: "%d/'%02d", m, y)
            } else {
                label = lblFmt.string(from: cursor)
            }
            buckets.append(ExifBucket(
                label: label, count: count,
                minText: isoFmt.string(from: cursor), maxText: isoFmt.string(from: lastDay),
                lowerBound: cursor.timeIntervalSince1970, upperBound: lastDay.timeIntervalSince1970
            ))
            cursor = nextMonth
        }
        return buckets
    }

    private func buildDailyDateBuckets(dates: [Date], from minDate: Date, to maxDate: Date) -> [ExifBucket] {
        let cal = Calendar.current
        let isoFmt = Self.isoDateFormatter
        var buckets: [ExifBucket] = []
        var cursor = cal.startOfDay(for: minDate)
        let end = cal.startOfDay(for: maxDate)
        while cursor <= end {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cursor)!
            let count = dates.filter { $0 >= cursor && $0 < nextDay }.count
            let dateStr = isoFmt.string(from: cursor)
            let m = cal.component(.month, from: cursor)
            let d = cal.component(.day, from: cursor)
            buckets.append(ExifBucket(
                label: "\(m)/\(d)", count: count,
                minText: dateStr, maxText: dateStr,
                lowerBound: cursor.timeIntervalSince1970, upperBound: nextDay.timeIntervalSince1970 - 1
            ))
            cursor = nextDay
        }
        return buckets
    }

    private func buildLuminanceBuckets(ids: [UInt64]) -> [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("0",   31,        "",    "31"),
            ("32",  63,        "32",  "63"),
            ("64",  95,        "64",  "95"),
            ("96",  127,       "96",  "127"),
            ("128", 159,       "128", "159"),
            ("160", 191,       "160", "191"),
            ("192", 223,       "192", "223"),
            ("255", .infinity, "224", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for id in ids {
            guard let lum = luminanceScores[id] else { continue }
            let d = Double(lum)
            for (i, spec) in specs.enumerated() { if d <= spec.upTo { counts[i] += 1; break } }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i], minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo, upperBound: spec.upTo)
        }
    }

    // BT.709 輝度平均を 0–255 の整数で返す（32×32 グレースケールに縮小して計算）
    private nonisolated static func computeLuminance(jpeg: Data) -> Int? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.reduce(0, { $0 + Int($1) }) / (side * side)
    }

    func selectGroupIDs(_ ids: [UInt64]) {
        selectedIDs.formUnion(ids)
        if primaryID == nil { primaryID = ids.first }
    }

    func deselectGroupIDs(_ ids: [UInt64]) {
        let toRemove = Set(ids)
        selectedIDs.subtract(toRemove)
        if let pid = primaryID, toRemove.contains(pid) { primaryID = selectedIDs.first }
    }

    // MARK: - Private

    func setThumbnailOrientation(id: UInt64, orientation: Image.Orientation) {
        thumbnailOrientations[id] = orientation
    }

    func setThumbnail(id: UInt64, jpeg: Data) {
        pendingThumbnails[id] = jpeg
        guard thumbnailFlushTask == nil else { return }
        thumbnailFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            let flushed = pendingThumbnails
            thumbnailBlobs.merge(flushed) { _, new in new }
            pendingThumbnails = [:]
            thumbnailFlushTask = nil
            // サムネイルは sort/filter/aggregate に影響しないので recomputeVisible 不要
            for id in flushed.keys { thumbnailDidUpdate.send(id) }
            // 輝度スコアをバックグラウンドで計算（未計算分のみ）
            let toCompute = flushed.filter { luminanceScores[$0.key] == nil }
            if !toCompute.isEmpty {
                Task.detached(priority: .utility) { [weak self] in
                    var computed: [UInt64: Int] = [:]
                    for (id, jpeg) in toCompute {
                        if let score = LibraryStore.computeLuminance(jpeg: jpeg) {
                            computed[id] = score
                        }
                    }
                    guard !computed.isEmpty else { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        luminanceScores.merge(computed) { _, new in new }
                        recomputeVisible()
                    }
                }
            }
        }
    }

    func thumbnailImage(for id: UInt64) -> CGImage? {
        ThumbnailDecodeCache.shared.decode(id: id, blob: thumbnailBlobs[id])
    }

    /// RAW サムネイルを選択エンジンでバックグラウンドレンダリングし、完了後に差し替える。
    /// `autoRenderRawThumbnails` が false の場合は何もしない。
    func autoRenderThumbnailIfNeeded(entry: PhotoEntry, db: BridgeCoreDatabase) {
        guard SettingsStore.shared.autoRenderRawThumbnails, entry.isRaw else { return }
        let engine = RAWRenderEngine(rawValue: SettingsStore.shared.rawRenderEngine) ?? .apple
        Task { [weak self] in
            guard let (img, _) = await RAWRenderPipeline.shared.render(
                url: entry.url, engine: engine, target: .sidebar, db: db
            ) else { return }
            guard let scaled = img.scaledToFit(maxPixels: 200),
                  let thumbJpeg = scaled.jpegData(compressionQuality: 0.85) else { return }
            guard let self else { return }
            ThumbnailDecodeCache.shared.evict(id: entry.id)
            setThumbnail(id: entry.id, jpeg: thumbJpeg)
        }
    }

    func setExif(id: UInt64, exif: ExifData?) {
        pendingExif[id] = exif ?? ExifData()
        scheduleMetaFlush()
    }

    func mergeExifBatch(_ batch: [UInt64: ExifData]) {
        pendingExif.merge(batch) { _, new in new }
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
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            let flushedExif = pendingExif
            let flushedXmp  = pendingXmp
            exifData.merge(flushedExif) { _, new in new }
            xmpData.merge(flushedXmp)  { _, new in new }
            pendingExif = [:]
            pendingXmp = [:]
            metaFlushTask = nil
            recomputeVisible()
            for id in flushedExif.keys { exifDidUpdate.send(id) }
            for id in flushedXmp.keys  { xmpDidUpdate.send(id) }
        }
    }


    /// 設定の閾値を使ってグループを再計算する。スキャン済みデータ（EXIF/pHash）はそのまま使用。
    func regroup() async {
        guard let list = lastImageList, let db = database else {
            // フォルダ未オープンでも applied を current に揃え、ボタンを無効化する。
            settings.appliedGroupingSplitThresholdSecs = settings.groupingSplitThresholdSecs
            settings.appliedGroupingPhashHammingThreshold = settings.groupingPhashHammingThreshold
            return
        }
        let split = settings.groupingSplitThresholdSecs
        let phash = settings.groupingPhashHammingThreshold
        let groups = await BridgeCore.reindexShotGroups(
            list: list, db: db,
            splitThresholdSecs: Int64(split),
            phashHammingThreshold: UInt32(phash)
        )
        applyReindexedGroups(groups)
        settings.appliedGroupingSplitThresholdSecs = split
        settings.appliedGroupingPhashHammingThreshold = phash
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
        stopFolderWatch()
        thumbnailBlobs = [:]
        thumbnailOrientations = [:]
        luminanceScores = [:]
        ThumbnailDecodeCache.shared.evictAll()
    }

    func resume() {
        startFolderWatchIfEnabled()
        Task { await reconcileFolder() }
        guard let db = database, !orderedIDs.isEmpty else { return }
        let entriesToLoad = orderedIDs.compactMap { entries[$0] }
        let capturedPhash = phashPipeline
        Task {
            await ThumbnailPipeline.loadAll(entries: entriesToLoad, store: self, db: db, phashPipeline: capturedPhash)
        }
    }

    private func reset() {
        watcher?.stop()
        watcher = nil
        pausedWatcherEventId = nil
        nextEntryID = 1
        entries = [:]
        orderedIDs = []
        shotGroups = [:]
        thumbnailBlobs = [:]
        thumbnailOrientations = [:]
        luminanceScores = [:]
        ThumbnailDecodeCache.shared.evictAll()
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
        exifLoadTask?.cancel()
        exifLoadTask = nil
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        // openDirTask は cancelLoading() 経由でキャンセルする（reset は openDirectory() 内から呼ばれるため自己キャンセル不可）
        // preScanTask も同様（openDirectory 内の runPreScan が pending 中の場合に備える）
        preScanTask?.cancel()
        preScanTask = nil
        loadedThumbnailCount = 0
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
        nextEntryID = (ordered.max() ?? 0) + 1
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

    /// EXIF がロード済みでカメラ Make/Model が両方空 → カメラ直出しか現像済みか判断できない
    private func isIndeterminateMember(_ id: UInt64) -> Bool {
        guard let exif = exifData[id] else { return false }
        return (exif.make ?? "").isEmpty && (exif.model ?? "").isEmpty
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
            var indMembers: [UInt64] = []

            for id in members {
                guard let entry = entries[id] else { continue }
                if entry.isRaw {
                    rawMembers.append(id)
                } else if isDevelopedMember(id, groupMinDate: groupMinDate) {
                    devMembers.append(id)
                } else if isIndeterminateMember(id) {
                    indMembers.append(id)
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
            // 判定不能: IND が存在するグループ
            } else if kinds.contains(.indeterminate), !indMembers.isEmpty {
                reps.insert(indMembers[0])
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
        if isIndeterminateMember(id) { return .indeterminate }
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

    static func cacheDBURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("BridgeLite")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.db")
    }

    private func dbURL() -> URL { LibraryStore.cacheDBURL() }

    // MARK: - Folder watch lifecycle

    func startFolderWatchIfEnabled() {
        guard settings.folderWatchEnabled,
              let url = currentDirectoryURL,
              !isLoading else { return }
        if watcher == nil {
            watcher = FolderWatcher { [weak self] event in
                self?.handleFolderChange(event)
            }
        }
        watcher?.start(at: url, sinceEventId: pausedWatcherEventId)
        pausedWatcherEventId = nil
    }

    func stopFolderWatch() {
        pausedWatcherEventId = watcher?.lastEventId
        watcher?.stop()
    }

    func applyFolderWatchSetting() {
        if settings.folderWatchEnabled {
            startFolderWatchIfEnabled()
        } else {
            watcher?.stop()
            watcher = nil
            pausedWatcherEventId = nil
        }
    }

    // MARK: - Folder change handler

    private func handleFolderChange(_ event: FolderWatcher.Event) {
        Task { await applyIncrementalChange() }
    }

    /// Re-scans the current directory and applies diff (add/remove) to the live store.
    /// Uses `bridge_scan_directory` (full re-scan) to obtain correct shot_ids, then
    /// maps Rust sequential IDs back to LibraryStore's stable nextEntryID-based IDs.
    private func applyIncrementalChange() async {
        guard let url = currentDirectoryURL, let db = database, !isLoading else { return }

        guard let (freshEntries, freshList) = try? await BridgeCore.scanDirectory(url: url, db: db) else { return }

        let existingPaths = Set(entries.values.map { $0.url.path })
        let freshPathSet  = Set(freshEntries.map { $0.url.path })

        let removedPaths = existingPaths.subtracting(freshPathSet)
        let addedPaths   = freshPathSet.subtracting(existingPaths)

        guard !removedPaths.isEmpty || !addedPaths.isEmpty else {
            lastImageList = freshList
            return
        }

        // 1. Remove stale entries
        if !removedPaths.isEmpty {
            let pathToID = Dictionary(uniqueKeysWithValues: entries.values.map { ($0.url.path, $0.id) })
            let removedIDs = Set(removedPaths.compactMap { pathToID[$0] })
            removeEntriesCore(removedIDs)
        }

        // 2. Add new entries (remap sequential Rust IDs to nextEntryID)
        var newEntries: [PhotoEntry] = []
        if !addedPaths.isEmpty {
            for freshEntry in freshEntries where addedPaths.contains(freshEntry.url.path) {
                let newID = nextEntryID
                nextEntryID += 1
                let remapped = PhotoEntry(
                    id: newID,
                    url: freshEntry.url,
                    filename: freshEntry.filename,
                    isRaw: freshEntry.isRaw,
                    fileSize: freshEntry.fileSize,
                    modifiedDate: freshEntry.modifiedDate,
                    createdDate: freshEntry.createdDate,
                    hasJpgPartner: freshEntry.hasJpgPartner,
                    shotId: freshEntry.shotId
                )
                entries[newID] = remapped
                orderedIDs.append(newID)
                shotGroups[freshEntry.shotId, default: []].append(newID)
                newEntries.append(remapped)
            }
        }

        // 3. Update lastImageList and reindex shot groups.
        //    freshList uses Rust sequential IDs (0,1,2,...); convert to store IDs via path.
        lastImageList = freshList
        let pathToStoreID = Dictionary(uniqueKeysWithValues: entries.values.map { ($0.url.path, $0.id) })
        let rawGroups = await BridgeCore.reindexShotGroups(
            list: freshList, db: db,
            splitThresholdSecs: Int64(settings.groupingSplitThresholdSecs),
            phashHammingThreshold: UInt32(settings.groupingPhashHammingThreshold)
        )
        let convertedGroups = convertGroupsToStoreIDs(rawGroups, freshList: freshList, pathToStoreID: pathToStoreID)
        applyReindexedGroups(convertedGroups)

        // 4. Fire pipelines for newly added entries only
        if !newEntries.isEmpty {
            let capturedDB    = db
            let capturedPhash = phashPipeline
            let jpgWriteMode  = settings.jpgWriteMode
            thumbnailLoadTask = Task { [weak self] in
                guard let self else { return }
                await ThumbnailPipeline.loadAll(entries: newEntries, store: self, db: capturedDB, phashPipeline: capturedPhash)
            }
            exifLoadTask = Task { [weak self] in
                guard let self else { return }
                let xmpLimiter = ConcurrencyLimiter(maxConcurrent: 8)
                await withTaskGroup(of: Void.self) { group in
                    for entry in newEntries {
                        group.addTask { [weak self] in
                            guard let self else { return }
                            if let exif = await BridgeCore.fetchExif(url: entry.url, db: capturedDB) {
                                await self.setExif(id: entry.id, exif: exif)
                            }
                            try? await xmpLimiter.run {
                                let xmp = await BridgeCore.readXmp(url: entry.url, jpgWriteMode: jpgWriteMode)
                                await self.setXmp(id: entry.id, xmp: xmp)
                            }
                        }
                    }
                }
            }
        }

        statusMessage = String(format: String(localized: "%d photos"), orderedIDs.count)
    }

    /// Removes entries from the store, cleaning up all secondary dicts and selection state.
    private func removeEntriesCore(_ ids: Set<UInt64>) {
        for id in ids {
            entries.removeValue(forKey: id)
            thumbnailBlobs.removeValue(forKey: id)
            luminanceScores.removeValue(forKey: id)
            exifData.removeValue(forKey: id)
            xmpData.removeValue(forKey: id)
            thumbnailOrientations.removeValue(forKey: id)
        }
        orderedIDs.removeAll { ids.contains($0) }
        for key in shotGroups.keys {
            shotGroups[key]?.removeAll { ids.contains($0) }
            if shotGroups[key]?.isEmpty == true { shotGroups.removeValue(forKey: key) }
        }
        selectedIDs.subtract(ids)
        if let pid = primaryID, ids.contains(pid) {
            primaryID = selectedIDs.first
        }
    }

    /// Converts reindexShotGroups output (Rust sequential IDs) to LibraryStore IDs (path-based lookup).
    private func convertGroupsToStoreIDs(
        _ groups: [UInt64: [UInt64]],
        freshList: BridgeCoreImageList,
        pathToStoreID: [String: UInt64]
    ) -> [UInt64: [UInt64]] {
        let count = image_entry_list_count(freshList.inner)
        var freshIDToPath: [UInt64: String] = [:]
        freshIDToPath.reserveCapacity(Int(count))
        for i in 0..<count {
            let ffiEntry = image_entry_list_get(freshList.inner, UInt(i))
            freshIDToPath[ffi_image_entry_id(ffiEntry)] = ffi_image_entry_path(ffiEntry).toString()
        }

        var result: [UInt64: [UInt64]] = [:]
        result.reserveCapacity(groups.count)
        for (shotId, freshMemberIDs) in groups {
            let storeIDs = freshMemberIDs.compactMap { freshID -> UInt64? in
                guard let path = freshIDToPath[freshID] else { return nil }
                return pathToStoreID[path]
            }
            if !storeIDs.isEmpty { result[shotId] = storeIDs }
        }
        return result
    }

    /// Lightweight reconciliation on window resume: enumerate the directory and
    /// synthesize add/remove events for any divergence missed while suspended.
    private func reconcileFolder() async {
        guard settings.folderWatchEnabled,
              let url = currentDirectoryURL,
              !isLoading else { return }

        let supported = ScanPipeline.supportedExtensionsSet
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var diskPaths = Set<String>()
        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL, !fileURL.hasDirectoryPath else { continue }
            if supported.contains(fileURL.pathExtension.lowercased()) {
                diskPaths.insert(fileURL.path)
            }
        }

        let storePaths = Set(entries.values.map { $0.url.path })
        let addedPaths   = diskPaths.subtracting(storePaths)
        let removedPaths = storePaths.subtracting(diskPaths)

        if !addedPaths.isEmpty || !removedPaths.isEmpty {
            Task { await applyIncrementalChange() }
        }
    }
}
