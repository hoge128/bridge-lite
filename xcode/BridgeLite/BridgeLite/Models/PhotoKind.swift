import Foundation

enum PhotoKind: Sendable, Hashable, CaseIterable {
    case raw, sooc, developed, indeterminate
}

extension PhotoKind {
    var localizedName: String {
        switch self {
        case .raw:           return String(localized: "kind.raw", defaultValue: "RAW")
        case .sooc:          return String(localized: "kind.sooc", defaultValue: "SOOC")
        case .developed:     return String(localized: "kind.developed", defaultValue: "Developed")
        case .indeterminate: return String(localized: "kind.indeterminate", defaultValue: "Indeterminate")
        }
    }

    var localizedBadgeName: String {
        switch self {
        case .raw:           return String(localized: "kind.raw.badge", defaultValue: "RAW")
        case .sooc:          return String(localized: "kind.sooc.badge", defaultValue: "SOOC")
        case .developed:     return String(localized: "kind.developed.badge", defaultValue: "Retouched")
        case .indeterminate: return String(localized: "kind.indeterminate.badge", defaultValue: "IND")
        }
    }

    // SOOC → RAW → Developed → Indeterminate
    var displayOrder: Int {
        switch self {
        case .sooc:          return 0
        case .raw:           return 1
        case .developed:     return 2
        case .indeterminate: return 3
        }
    }
}
