import SwiftUI

@Observable
final class SettingsStore {
    @AppStorage("defaultPath") var defaultPath: String = ""
    @AppStorage("language") var language: String = "ja"
    @AppStorage("theme") var theme: String = "system"
}
