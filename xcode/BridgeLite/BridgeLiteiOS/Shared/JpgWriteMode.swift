import Foundation

enum JpgWriteMode: String, CaseIterable, Identifiable {
    case embed
    case sidecar
    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .embed:   return String(localized: "jpg_write_mode.embed",   defaultValue: "Embed")
        case .sidecar: return String(localized: "jpg_write_mode.sidecar", defaultValue: "Sidecar")
        }
    }
}

enum JpgMetadataDefaults {
    static let jpgWriteModeKey = "jpgWriteMode"
    static let hasShownJpgEmbedWarningKey = "hasShownJpgEmbedWarning"
    private static let legacyIOSJpgWriteModeKey = "ios.jpgWriteMode"
    private static let legacyIOSHasShownJpgEmbedWarningKey = "ios.hasShownJpgEmbedWarning"

    static func readJpgWriteMode() -> JpgWriteMode {
        if let raw = UserDefaults.standard.string(forKey: jpgWriteModeKey),
           let mode = JpgWriteMode(rawValue: raw) {
            return mode
        }
        if let raw = UserDefaults.standard.string(forKey: legacyIOSJpgWriteModeKey),
           let mode = JpgWriteMode(rawValue: raw) {
            return mode
        }
        return .embed
    }

    static func migrateLegacyKeysIfNeeded() {
        if UserDefaults.standard.string(forKey: jpgWriteModeKey) == nil,
           let legacyMode = UserDefaults.standard.string(forKey: legacyIOSJpgWriteModeKey),
           JpgWriteMode(rawValue: legacyMode) != nil {
            UserDefaults.standard.set(legacyMode, forKey: jpgWriteModeKey)
        }
        if UserDefaults.standard.object(forKey: hasShownJpgEmbedWarningKey) == nil,
           let legacyShown = UserDefaults.standard.object(forKey: legacyIOSHasShownJpgEmbedWarningKey) as? Bool {
            UserDefaults.standard.set(legacyShown, forKey: hasShownJpgEmbedWarningKey)
        }
    }

    static func hasShownJpgEmbedWarning() -> Bool {
        if let shown = UserDefaults.standard.object(forKey: hasShownJpgEmbedWarningKey) as? Bool {
            return shown
        }
        return (UserDefaults.standard.object(forKey: legacyIOSHasShownJpgEmbedWarningKey) as? Bool) ?? false
    }

    static func resetJpgEmbedWarning() {
        UserDefaults.standard.removeObject(forKey: hasShownJpgEmbedWarningKey)
        UserDefaults.standard.removeObject(forKey: legacyIOSHasShownJpgEmbedWarningKey)
    }
}
