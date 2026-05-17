import Foundation
import Observation

/// XMP レーティング・ラベルの読み書きと in-memory キャッシュ管理
@Observable
@MainActor
final class RatingStore {

    var ratings: [UInt64: XmpData] = [:]

    // MARK: - Load

    func loadAll(entries: [PhotoEntry], jpgWriteMode: JpgWriteMode = .embed) async {
        await withTaskGroup(of: (UInt64, XmpData?).self) { group in
            for entry in entries {
                group.addTask {
                    let xmp = await BridgeCore.readXmp(url: entry.url, jpgWriteMode: jpgWriteMode)
                    return (entry.id, xmp)
                }
            }
            for await (id, xmp) in group {
                if let xmp { ratings[id] = xmp }
            }
        }
    }

    // MARK: - Write

    func setRating(_ rating: Int?, for entry: PhotoEntry, db: BridgeCoreDatabase,
                   jpgWriteMode: JpgWriteMode = .embed) async {
        var xmp = ratings[entry.id] ?? XmpData()
        xmp.rating = rating
        ratings[entry.id] = xmp
        _ = await BridgeCore.writeXmp(url: entry.url, xmp: xmp, db: db,
                                      jpgWriteMode: jpgWriteMode, captionPresent: false)
    }

    func setLabel(_ label: XmpLabel?, for entry: PhotoEntry, db: BridgeCoreDatabase,
                  jpgWriteMode: JpgWriteMode = .embed) async {
        var xmp = ratings[entry.id] ?? XmpData()
        xmp.label = label
        ratings[entry.id] = xmp
        _ = await BridgeCore.writeXmp(url: entry.url, xmp: xmp, db: db,
                                      jpgWriteMode: jpgWriteMode, captionPresent: false)
    }
}
