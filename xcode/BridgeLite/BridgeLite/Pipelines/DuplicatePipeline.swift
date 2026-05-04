import Foundation

actor DuplicatePipeline {
    func compute(list: BridgeCoreImageList, db: BridgeCoreDatabase, store: LibraryStore) async {
        let groups = await BridgeCore.computeDuplicateGroups(list: list, db: db)
        await store.applyDuplicateGroups(groups)
    }
}
