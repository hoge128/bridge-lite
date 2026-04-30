import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var showRestartAlert = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("General") {
                Picker("Language", selection: $settings.language) {
                    Text("日本語").tag("ja")
                    Text("English").tag("en")
                }
                .onChange(of: settings.language) { old, new in
                    guard old != new else { return }
                    showRestartAlert = true
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
            Section {
                filterOrderList
                Text("Drag rows to reorder filter sections in the sidebar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Filter Panel")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 620)
        .alert(
            String(localized: "alert.restart.title", defaultValue: "Restart Required"),
            isPresented: $showRestartAlert
        ) {
            Button(String(localized: "alert.restart.button.now", defaultValue: "Restart Now")) {
                relaunchApp()
            }
            Button(String(localized: "alert.restart.button.later", defaultValue: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "alert.restart.message", defaultValue: "BridgeLite must restart to apply the new language. If automatic restart fails, please quit and reopen manually."))
        }
    }

    @ViewBuilder
    private var propagationGrid: some View {
        @Bindable var s = settings
        let soocLabel = PhotoKind.sooc.localizedName
        let devLabel  = PhotoKind.developed.localizedName

        Grid(alignment: .center, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("").gridCellAnchor(.center)
                Text(soocLabel).font(.caption).foregroundStyle(.secondary)
                Text("RAW").font(.caption).foregroundStyle(.secondary)
                Text(devLabel).font(.caption).foregroundStyle(.secondary)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text(soocLabel).font(.caption)
                lockedCell
                Toggle("", isOn: $s.soocToRaw).labelsHidden()
                Toggle("", isOn: $s.soocToDeveloped).labelsHidden()
            }
            GridRow {
                Text("RAW").font(.caption)
                Toggle("", isOn: $s.rawToSooc).labelsHidden()
                lockedCell
                Toggle("", isOn: $s.rawToDeveloped).labelsHidden()
            }
            GridRow {
                Text(devLabel).font(.caption)
                Toggle("", isOn: $s.developedToSooc).labelsHidden()
                Toggle("", isOn: $s.developedToRaw).labelsHidden()
                lockedCell
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var filterOrderList: some View {
        @Bindable var settings = settings
        List {
            ForEach(settings.filterSectionOrder) { section in
                Text(section.localizedName)
                    .font(.body)
            }
            .onMove { from, to in
                settings.filterSectionOrder.move(fromOffsets: from, toOffset: to)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(height: 220)
    }

    private var lockedCell: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .help("Always applied to itself")
    }

    private func relaunchApp() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            NSApp.terminate(nil)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-b", bundleID]
        try? task.run()
        NSApp.terminate(nil)
    }
}
