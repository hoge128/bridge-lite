import Foundation

enum PhotoKind: Sendable, Hashable {
    case raw, sooc, developed, indeterminate

    var badgeName: String {
        switch self {
        case .raw:           return "RAW"
        case .sooc:          return "カメラ出力"
        case .developed:     return "現像済み"
        case .indeterminate: return "判定不能"
        }
    }
}
