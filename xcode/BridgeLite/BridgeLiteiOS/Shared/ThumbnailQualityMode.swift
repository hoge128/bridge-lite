import Foundation

enum ThumbnailQualityMode: String, CaseIterable, Identifiable {
    case quality    // 埋め込み無し・極小時はフル画像デコードでフォールバック（現状動作）
    case speed      // 埋め込みのみ。無ければ nil を返す
    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .quality: return String(localized: "thumb_quality.quality", defaultValue: "Quality")
        case .speed:   return String(localized: "thumb_quality.speed",   defaultValue: "Speed")
        }
    }
}
