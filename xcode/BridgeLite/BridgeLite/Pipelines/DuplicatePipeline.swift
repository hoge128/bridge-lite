import Foundation

actor DuplicatePipeline {
    func compute(list: BridgeCoreImageList, db: BridgeCoreDatabase, store: LibraryStore, generation: Int) async {
        let groups = await BridgeCore.computeDuplicateGroups(list: list, db: db)
        await store.applyDuplicateGroups(groups, generation: generation)
    }
}
