import SwiftUI

struct XmpData: Sendable, Equatable {
    var rating: Int?       // 0-5, nil = unset
    var label: XmpLabel?
    var flag: XmpFlag?     // Pick / Reject (nil = unflagged)
    var developed: Bool = false
    var caption: String?   // dc:description (nil = unset, "" = clear on write)
}

/// Pick/Reject フラグ。rawValue は FFI の flag u8 (0 = none, 1 = pick, 2 = reject) と一致。
/// ディスク上は Lightroom Classic 13.2+ 形式 (xmpDM:pick / xmpDM:good) で読み書きされる。
enum XmpFlag: UInt8, Sendable, CaseIterable {
    case pick   = 1
    case reject = 2

    var color: Color {
        switch self {
        case .pick:   return .green
        case .reject: return Color(red: 0.85, green: 0.25, blue: 0.25)
        }
    }

    var systemImage: String {
        switch self {
        case .pick:   return "flag.fill"
        case .reject: return "xmark.circle.fill"
        }
    }

    var name: String {
        switch self {
        case .pick:   return String(localized: "flag.pick",   defaultValue: "Pick")
        case .reject: return String(localized: "flag.reject", defaultValue: "Reject")
        }
    }
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

