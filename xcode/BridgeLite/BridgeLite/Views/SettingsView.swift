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
            }
            Section {
                propagationGrid
                Text("Row: source kind  ·  Column: kinds that receive the same rating/label.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Rating Propagation")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 460)
    }

    @ViewBuilder
    private var propagationGrid: some View {
        @Bindable var s = settings
        let isJa = s.language == "ja"
        let soocLabel = isJa ? "カメラ出力" : "SOOC"
        let devLabel  = isJa ? "現像済み"   : "Developed"

        Grid(alignment: .center, horizontalSpacing: 16, verticalSpacing: 8) {
            // 列ヘッダ
            GridRow {
                Text("").gridCellAnchor(.center)
                Text(soocLabel).font(.caption).foregroundStyle(.secondary)
                Text("RAW").font(.caption).foregroundStyle(.secondary)
                Text(devLabel).font(.caption).foregroundStyle(.secondary)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            // SOOC 行
            GridRow {
                Text(soocLabel).font(.caption)
                lockedCell
                Toggle("", isOn: $s.soocToRaw).labelsHidden()
                Toggle("", isOn: $s.soocToDeveloped).labelsHidden()
            }
            // RAW 行
            GridRow {
                Text("RAW").font(.caption)
                Toggle("", isOn: $s.rawToSooc).labelsHidden()
                lockedCell
                Toggle("", isOn: $s.rawToDeveloped).labelsHidden()
            }
            // Developed 行
            GridRow {
                Text(devLabel).font(.caption)
                Toggle("", isOn: $s.developedToSooc).labelsHidden()
                Toggle("", isOn: $s.developedToRaw).labelsHidden()
                lockedCell
            }
        }
        .padding(.vertical, 4)
    }

    private var lockedCell: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .help("Always applied to itself")
    }
}
