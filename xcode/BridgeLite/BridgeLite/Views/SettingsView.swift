import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var showRestartAlert = false
    @State private var cacheSize: Int64 = -1
    @State private var showClearCacheAlert = false

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            advancedTab
                .tabItem { Label(String(localized: "settings.tab.advanced", defaultValue: "Advanced"), systemImage: "gearshape.2") }
        }
        .frame(width: 440, height: 720)
        .onAppear { refreshCacheSize() }
        .alert(
            String(localized: "alert.cache.clear.title", defaultValue: "Clear Cache"),
            isPresented: $showClearCacheAlert
        ) {
            Button(String(localized: "alert.cache.clear.button", defaultValue: "Clear"), role: .destructive) {
                clearCacheFiles()
            }
            Button(String(localized: "alert.restart.button.later", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "alert.cache.clear.message",
                        defaultValue: "Thumbnails and EXIF data will be deleted from the cache. They will be rebuilt automatically when you next open a folder."))
        }
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

    // MARK: - General tab

    private var generalTab: some View {
        @Bindable var settings = settings
        return Form {
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
                Picker(String(localized: "settings.shortcut.rating_keys", defaultValue: "Rating / Label Keys"),
                       selection: $settings.ratingShortcutModifier) {
                    ForEach(RatingShortcutModifier.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text(String(localized: "settings.shortcut.section", defaultValue: "Keyboard Shortcuts"))
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
            Section("Cache") {
                LabeledContent("Database Size") {
                    if cacheSize < 0 {
                        Text("Calculating…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Clear Cache", role: .destructive) {
                    showClearCacheAlert = true
                }
                .disabled(cacheSize <= 0)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        Form {
            Section {
                groupingControls
                Text(String(localized: "settings.grouping.description",
                            defaultValue: "These values rarely need adjustment. Changes take effect when you click Re-group or open a new folder."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Grouping")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Grouping controls

    @ViewBuilder
    private var groupingControls: some View {
        @Bindable var s = settings
        @State var isRegrouping = false
        Stepper(value: $s.groupingSplitThresholdSecs, in: 1...30) {
            LabeledContent(String(localized: "settings.grouping.split_threshold", defaultValue: "Split threshold")) {
                Text(String(format: String(localized: "settings.grouping.seconds %lld", defaultValue: "%lld s"), Int64(settings.groupingSplitThresholdSecs)))
                    .foregroundStyle(.secondary)
            }
        }
        .help(String(localized: "settings.grouping.split_threshold.help", defaultValue: "Same-name files with EXIF timestamps more than this many seconds apart are treated as separate cameras."))
        Text(String(localized: "settings.grouping.split_threshold.description",
                    defaultValue: "Same-name files (e.g. IMG_0001.CR3 + IMG_0001.JPG) are grouped together when their EXIF timestamps differ by no more than this value. Files exceeding the limit are split as same-name collisions from different cameras. Increase to tolerate larger clock offsets between RAW and JPEG; decrease to split more aggressively."))
            .font(.caption2)
            .foregroundStyle(.secondary)
        Stepper(value: $s.groupingPhashHammingThreshold, in: 2...32) {
            LabeledContent(String(localized: "settings.grouping.phash_threshold", defaultValue: "pHash threshold")) {
                Text("\(settings.groupingPhashHammingThreshold)")
                    .foregroundStyle(.secondary)
            }
        }
        .help(String(localized: "settings.grouping.phash_threshold.help", defaultValue: "Hamming distance limit for rescuing EXIF-stripped files (IAD) into a confirmed group. Lower = stricter matching."))
        Text(String(localized: "settings.grouping.phash_threshold.description",
                    defaultValue: "Rescues EXIF-stripped files (e.g. DxO / Lightroom exports) into a matching group using visual similarity (perceptual hash Hamming distance). Same-image cross-format conversions typically score ≤ 14; unrelated images typically score ≥ 20. Increase to widen the rescue net; decrease for stricter matching."))
            .font(.caption2)
            .foregroundStyle(.secondary)
        HStack {
            Button {
                isRegrouping = true
                NotificationCenter.default.post(name: .bridgeLiteRegroup, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { isRegrouping = false }
            } label: {
                if isRegrouping {
                    ProgressView().controlSize(.small)
                } else {
                    Text(String(localized: "settings.grouping.regroup_button", defaultValue: "Re-group"))
                }
            }
            .disabled(!settings.groupingNeedsApply)
            .help(String(localized: "settings.grouping.regroup_button.help", defaultValue: "Re-apply grouping logic with the current thresholds without re-scanning thumbnails or EXIF."))
            Spacer()
            Button(String(localized: "settings.grouping.reset_button", defaultValue: "Reset to Defaults"), role: .destructive) {
                s.groupingSplitThresholdSecs = 2
                s.groupingPhashHammingThreshold = 15
                NotificationCenter.default.post(name: .bridgeLiteRegroup, object: nil)
            }
            .help(String(localized: "settings.grouping.reset_button.help", defaultValue: "Restore split threshold to 2 s and pHash threshold to 15."))
        }
    }

    // MARK: - Rating Propagation grid

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

    // MARK: - Filter order list

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

    // MARK: - Helpers

    private func refreshCacheSize() {
        let base = LibraryStore.cacheDBURL().path
        let fm = FileManager.default
        cacheSize = [base, base + "-shm", base + "-wal"].reduce(0) { sum, path in
            let attrs = try? fm.attributesOfItem(atPath: path)
            return sum + (attrs?[.size] as? Int64 ?? 0)
        }
    }

    private func clearCacheFiles() {
        let base = LibraryStore.cacheDBURL().path
        let fm = FileManager.default
        for path in [base, base + "-shm", base + "-wal"] {
            try? fm.removeItem(atPath: path)
        }
        cacheSize = 0
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
