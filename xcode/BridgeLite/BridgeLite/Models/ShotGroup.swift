import Foundation

/// Shot グループ: 同一シャッターから生まれた RAW+JPG のペア (+ 現像バリアント) を束ねる
struct ShotGroup: Identifiable, Sendable {
    let id: UInt64          // shotId
    var memberIDs: [UInt64] // PhotoEntry.id の配列 (先頭が代表)

    /// 代表エントリ ID
    var representativeID: UInt64? { memberIDs.first }

    /// RAW メンバー
    func rawIDs(entries: [UInt64: PhotoEntry]) -> [UInt64] {
        memberIDs.filter { entries[$0]?.isRaw == true }
    }

    /// JPG メンバー
    func jpgIDs(entries: [UInt64: PhotoEntry]) -> [UInt64] {
        memberIDs.filter { entries[$0]?.isRaw == false }
    }
}
