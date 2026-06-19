import Foundation

@MainActor
protocol ReindexedGroupSink: AnyObject, Sendable {
    /// Applies reindexShotGroups output (members keyed by Rust sequential IDs) to the store,
    /// remapping Rust IDs to globally-unique store IDs via `list` (path join). Pass the same
    /// `list` that produced `groups`.
    func applyRustReindexedGroups(_ groups: [UInt64: [UInt64]], list: BridgeCoreImageList?, generation: Int)
}

actor PairingPipeline {
    private var exifReady = false
    private var phashReady = false
    private var reindexed = false
    private var splitThresholdSecs: Int64 = 2
    private var phashHammingThreshold: UInt32 = 15

    func noteExifReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: any ReindexedGroupSink, splitThresholdSecs: Int64, phashHammingThreshold: UInt32, generation: Int) async {
        self.splitThresholdSecs = splitThresholdSecs
        self.phashHammingThreshold = phashHammingThreshold
        exifReady = true
        await maybeReindex(list: list, db: db, store: store, generation: generation)
    }

    func notePhashReady(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: any ReindexedGroupSink, splitThresholdSecs: Int64, phashHammingThreshold: UInt32, generation: Int) async {
        self.splitThresholdSecs = splitThresholdSecs
        self.phashHammingThreshold = phashHammingThreshold
        phashReady = true
        await maybeReindex(list: list, db: db, store: store, generation: generation)
    }

    private func maybeReindex(list: BridgeCoreImageList?, db: BridgeCoreDatabase, store: any ReindexedGroupSink, generation: Int) async {
        // Reindex once both EXIF and pHash batches are complete.
        guard exifReady && phashReady else { return }
        guard !reindexed else { return }
        reindexed = true

        guard let list else { return }
        let groups = await BridgeCore.reindexShotGroups(list: list, db: db, splitThresholdSecs: splitThresholdSecs, phashHammingThreshold: phashHammingThreshold)
        await store.applyRustReindexedGroups(groups, list: list, generation: generation)
    }
}
