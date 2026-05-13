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
    /// グループ内の代表エントリ URL を収集する（RAW 優先、なければ JPG）
    static func urlsForGroups(
        _ groups: [ShotGroup],
        entries: [UInt64: PhotoEntry]
    ) -> [URL] {
        groups.compactMap { group in
            let members = group.memberIDs.compactMap { entries[$0] }
            return (members.first(where: { $0.isRaw }) ?? members.first)?.url
        }
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
