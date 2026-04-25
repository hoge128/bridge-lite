import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("General") {
                // TODO: Phase F で実際の設定項目を追加
                Picker("Language", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                Picker("Theme", selection: $settings.theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("Library") {
                TextField("Default Path", text: $settings.defaultPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 300)
    }
}
