import Foundation

actor PairingPipeline {
    private var exifReady = false
    private var phashReady = false
    private var reindexed = false
    private var splitThresholdSecs: Int64 = 2
    private var phashHammingThreshold: UInt32 = 15

    func noteExifReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore, splitThresholdSecs: Int64, phashHammingThreshold: UInt32) async {
        self.splitThresholdSecs = splitThresholdSecs
        self.phashHammingThreshold = phashHammingThreshold
        exifReady = true
        await maybeReindex(list: list, db: db, store: store)
    }

    func notePhashReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore, splitThresholdSecs: Int64, phashHammingThreshold: UInt32) async {
        self.splitThresholdSecs = splitThresholdSecs
        self.phashHammingThreshold = phashHammingThreshold
        phashReady = true
        await maybeReindex(list: list, db: db, store: store)
    }

    private func maybeReindex(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore) async {
        // Reindex once both EXIF and pHash batches are complete.
        guard exifReady && phashReady else { return }
        guard !reindexed else { return }
        reindexed = true

        guard let list else { return }
        let groups = await BridgeCore.reindexShotGroups(list: list, db: db, splitThresholdSecs: splitThresholdSecs, phashHammingThreshold: phashHammingThreshold)
        await store.applyReindexedGroups(groups)
    }
}
