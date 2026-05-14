import SwiftUI
import UIKit

/// UIActivityViewController を SwiftUI から呼び出すブリッジ
struct ExportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onDismiss() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Export helpers

enum ExportService {
    /// Mac の computeRepresentatives 互換: developed > SOOC > RAW newest の優先順で代表 URL を収集する
    @MainActor
    static func urlsForGroups(
        _ groups: [ShotGroup],
        scanStore: ScanStore,
        xmps: [UInt64: XmpData]
    ) -> [URL] {
        groups.compactMap { scanStore.representativeURL(for: $0, xmps: xmps) }
    }

    /// 特定ラベルを持つエントリの URL を収集する
    static func urlsWithLabel(
        _ label: XmpLabel,
        entries: [UInt64: PhotoEntry],
        ratings: [UInt64: XmpData]
    ) -> [URL] {
        entries.values
            .filter { ratings[$0.id]?.label == label }
            .map { $0.url }
    }
}
