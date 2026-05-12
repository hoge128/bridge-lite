import Foundation

/// ディレクトリスキャンパイプライン
/// Phase C.6 以降: BridgeCore.scanDirectory を使う
/// 現時点では FileManager ベースのフォールバック実装
actor ScanPipeline {
    static let supportedExtensionsSet: Set<String> = [
        // RAW
        "arw", "cr2", "cr3", "nef", "nrw", "rw2", "orf", "pef", "raf", "dng",
        // JPEG
        "jpg", "jpeg",
        // Other
        "heic", "heif", "tiff", "tif", "png"
    ]

    /// FileManager ベースのフォールバックスキャン (Phase C.6 で BridgeCore に委譲)
    func scan(url: URL) async throws -> [PhotoEntry] {
        return try await Task.detached(priority: BridgeQoS.scan) {
            var results: [PhotoEntry] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                    .creationDateKey, .isRegularFileKey
                ],
                options: [.skipsHiddenFiles]
            ) else {
                throw BridgeCoreError.io(path: url.path, message: "Cannot enumerate directory")
            }

            var idCounter: UInt64 = 1
            let allURLs = enumerator.allObjects.compactMap { $0 as? URL }
            for fileURL in allURLs {
                try Task.checkCancellation()
                let ext = fileURL.pathExtension.lowercased()
                guard ScanPipeline.supportedExtensionsSet.contains(ext) else { continue }

                let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
                )
                guard resourceValues?.isRegularFile == true else { continue }

                let isRaw = Self.rawExtensions.contains(ext)
                let fileSize = UInt64(resourceValues?.fileSize ?? 0)
                let modDate = resourceValues?.contentModificationDate
                let createDate = resourceValues?.creationDate

                let entry = PhotoEntry(
                    id: idCounter,
                    url: fileURL,
                    filename: fileURL.lastPathComponent,
                    isRaw: isRaw,
                    fileSize: fileSize,
                    modifiedDate: modDate,
                    createdDate: createDate,
                    hasJpgPartner: false,
                    shotId: idCounter  // Phase E で実際のペアリング後に更新
                )
                results.append(entry)
                idCounter += 1
            }
            return results
        }.value
    }

    private static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "rw2", "orf", "pef", "raf", "dng"
    ]
}
