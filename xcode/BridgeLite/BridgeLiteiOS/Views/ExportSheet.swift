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

// MARK: - Share sheet presenter

/// ウィンドウ内の最前面 VC から UIActivityViewController を提示する。
/// SwiftUI の .sheet 内から呼ぶと AirDrop を含む全アクティビティが正しく表示されない
/// ため、この関数で直接 UIKit 層に提示する。
@MainActor
func presentShareSheet(urls: [URL], previewImage: UIImage? = nil, title: String? = nil) {
    guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let window = windowScene.windows.first(where: { $0.isKeyWindow }) else { return }
    var topVC = window.rootViewController
    while let presented = topVC?.presentedViewController { topVC = presented }
    guard let topVC else { return }

    var items: [Any]
    if let previewImage, let first = urls.first, let title {
        items = [ActivityURLWithPreview(url: first, previewImage: previewImage, title: title)]
            + Array(urls.dropFirst())
    } else {
        items = urls
    }

    let actVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
    // iPad では UIActivityViewController を popover として提示しないとクラッシュする。
    // push ナビゲーション（ズーム遷移）でも fullScreenCover でも安全なよう常時設定する。
    if let popover = actVC.popoverPresentationController {
        popover.sourceView = topVC.view
        popover.sourceRect = CGRect(
            x: topVC.view.bounds.midX,
            y: topVC.view.bounds.midY,
            width: 1, height: 1
        )
        popover.permittedArrowDirections = []
    }
    topVC.present(actVC, animated: true)
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
