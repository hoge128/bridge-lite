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

    /// True if the filename stem contains a known developed-software suffix (e.g. "-DxO_DeepPRIME XD2s").
    /// Works synchronously without waiting for EXIF/XMP to load.
    var hasDevelopedSuffix: Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return BridgeCoreConstants.softwareFilenameMarkers.contains { stem.contains($0) }
    }
}
