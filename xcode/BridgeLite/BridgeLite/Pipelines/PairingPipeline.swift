import Foundation

actor PairingPipeline {
    private var exifReady = false
    private var phashReady = false
    private var reindexed = false

    func noteExifReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore) async {
        exifReady = true
        await maybeReindex(list: list, db: db, store: store)
    }

    func notePhashReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore) async {
        phashReady = true
        await maybeReindex(list: list, db: db, store: store)
    }

    private func maybeReindex(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: LibraryStore) async {
        // Reindex once both EXIF and pHash batches are complete.
        guard exifReady && phashReady else { return }
        guard !reindexed else { return }
        reindexed = true

        guard let list else { return }
        let groups = await BridgeCore.reindexShotGroups(list: list, db: db)
        await store.applyReindexedGroups(groups)
    }
}
