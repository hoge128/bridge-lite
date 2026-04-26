import Foundation

@Observable
final class SettingsStore {
    var defaultPath: String = UserDefaults.standard.string(forKey: "defaultPath") ?? "" {
        didSet { UserDefaults.standard.set(defaultPath, forKey: "defaultPath") }
    }
    var language: String = UserDefaults.standard.string(forKey: "language") ?? "ja" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var theme: String = UserDefaults.standard.string(forKey: "theme") ?? "system" {
        didSet { UserDefaults.standard.set(theme, forKey: "theme") }
    }
}
