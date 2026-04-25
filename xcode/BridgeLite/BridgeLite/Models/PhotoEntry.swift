import Foundation

struct PhotoEntry: Identifiable, Hashable, Sendable {
    let id: UInt64
    let url: URL
    let filename: String
    let isRaw: Bool
    let fileSize: UInt64
    let modifiedDate: Date?
    let createdDate: Date?
    let hasJpgPartner: Bool
    var shotId: UInt64

    var formattedFileSize: String {
        let kb = Double(fileSize) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    var fileExtension: String {
        url.pathExtension.uppercased()
    }
}
