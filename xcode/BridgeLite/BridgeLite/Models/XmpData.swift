import SwiftUI

struct XmpData: Sendable, Equatable {
    var rating: Int?       // 0-5, nil = unset
    var label: XmpLabel?
    var developed: Bool = false
}

enum XmpLabel: UInt8, Sendable, CaseIterable {
    case red    = 1
    case yellow = 2
    case green  = 3
    case blue   = 4
    case purple = 5

    var color: Color {
        switch self {
        case .red:    return .red
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        }
    }

    var name: String {
        switch self {
        case .red:    return String(localized: "Red")
        case .yellow: return String(localized: "Yellow")
        case .green:  return String(localized: "Green")
        case .blue:   return String(localized: "Blue")
        case .purple: return String(localized: "Purple")
        }
    }
}

