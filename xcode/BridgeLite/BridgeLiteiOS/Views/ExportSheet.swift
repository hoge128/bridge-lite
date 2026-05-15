import SwiftUI
import UIKit
import LinkPresentation

/// 共有シートの先頭アイテムにサムネイルプレビューを添付する UIActivityItemSource。
/// LPLinkMetadata.imageProvider にサムネイル UIImage を渡すことで、
/// 共有シートのプレビュー欄にファイルの中身が表示される。
final class ActivityURLWithPreview: NSObject, UIActivityItemSource {
    private let url: URL
    private let previewImage: UIImage
    private let title: String

    init(url: URL, previewImage: UIImage, title: String) {
        self.url = url
        self.previewImage = previewImage
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ vc: UIActivityViewController) -> Any { url }

    func activityViewController(_ vc: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }

    func activityViewControllerLinkMetadata(_ vc: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = title
        meta.imageProvider = NSItemProvider(object: previewImage)
        return meta
    }
}

/// UIActivityViewController を SwiftUI から正しく呼び出すブリッジ。
/// .sheet 内に UIActivityViewController を直接置くと activities リストが空になるため、
/// 透明な UIViewController をコンテナにして present(_:animated:) で重ねる方式を使う。
struct ExportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard vc.presentedViewController == nil else { return }
        let actVC = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        actVC.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async { onDismiss() }
        }
        vc.present(actVC, animated: true)
    }
}

// MARK: - Export guide (shown when no filter is active)

struct ExportGuideSheet: View {
    let fileCount: Int
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {

                Label(
                    String(localized: "export.guide.count \(fileCount)"),
                    systemImage: "doc.on.doc"
                )
                .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        String(localized: "export.guide.no_filter_title", defaultValue: "No filters applied"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                    Text(String(localized: "export.guide.no_filter_body",
                                defaultValue: "All representative files will be exported. Use filters to narrow down the target."))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "export.guide.examples_title", defaultValue: "Filter examples:"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "export.guide.example_sooc",
                                    defaultValue: "• File Type › Camera Output  →  SOOC JPG only"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "export.guide.example_rating",
                                    defaultValue: "• Rating › ★★★ or above  →  high-rated photos only"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))

                Spacer()

                Button(action: onContinue) {
                    Text(String(localized: "export.guide.continue", defaultValue: "Export anyway"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle(String(localized: "export.guide.title", defaultValue: "Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel"), action: onCancel)
                }
            }
        }
        .presentationDetents([.medium])
    }
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
