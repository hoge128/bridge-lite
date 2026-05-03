import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var showRestartAlert = false
    @State private var cacheSize: Int64 = -1
    @State private var showClearCacheAlert = false
    @State private var showClearRenderCacheAlert = false

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
            String(localized: "alert.render.cache.clear.title", defaultValue: "Clear Render Cache"),
            isPresented: $showClearRenderCacheAlert
        ) {
            Button(String(localized: "alert.cache.clear.button", defaultValue: "Clear"), role: .destructive) {
                Task { await BridgeCore.clearRenderedCache(dbPath: LibraryStore.cacheDBURL()) }
            }
            Button(String(localized: "alert.restart.button.later", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "alert.render.cache.clear.message",
                        defaultValue: "Rendered RAW previews will be deleted. They will be regenerated on demand."))
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
                scopeGrid
            } header: {
                Text("Group Scope")
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
            Section {
                Picker(String(localized: "settings.metadata.jpg_write_mode", defaultValue: "JPEG Metadata"),
                       selection: $settings.jpgWriteMode) {
                    ForEach(JpgWriteMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                mdCaption("settings.metadata.jpg_write_mode.description",
                          defaultValue: "**Embed**: writes XMP directly into the JPEG file.\n**Sidecar**: creates a separate .xmp file and leaves the JPEG unchanged.")
                if settings.jpgWriteMode == .sidecar {
                    Picker(String(localized: "settings.metadata.conflict_policy", defaultValue: "When embedded XMP exists"),
                           selection: $settings.jpgSidecarConflictPolicy) {
                        ForEach(JpgSidecarConflictPolicy.allCases) { policy in
                            Text(policy.localizedName).tag(policy)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    mdCaption("settings.metadata.conflict_policy.description",
                              defaultValue: "Controls what happens when a JPEG already has ratings or labels embedded directly and you rate it in Sidecar mode.\n**Ask each time**: shows a confirmation listing the affected filenames.\n**Always propagate**: silently updates both sidecar and embedded.\n**Never propagate**: writes only to the sidecar.")
                }
            } header: {
                Text(String(localized: "settings.metadata.section", defaultValue: "Metadata"))
            }
            Section {
                Toggle(String(localized: "settings.folder_watch.toggle",
                              defaultValue: "Auto-update folder"),
                       isOn: $settings.folderWatchEnabled)
                Text(String(localized: "settings.folder_watch.description",
                            defaultValue: "Detects new files and adds them automatically"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "settings.folder_watch.section",
                            defaultValue: "Folder Updates"))
            }
            Section(String(localized: "settings.render.section", defaultValue: "RAW Rendering")) {
                Toggle(String(localized: "settings.render.auto_compare",
                              defaultValue: "Auto-render in Compare view"),
                       isOn: $settings.autoRenderRawCompare)
                Text(String(localized: "settings.render.auto_compare.description",
                            defaultValue: "Automatically renders each RAW column when the Compare view opens. Results are cached and reused."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "settings.render.auto_sidebar",
                              defaultValue: "Auto-render in Sidebar preview"),
                       isOn: $settings.autoRenderRawSidebar)
                Text(String(localized: "settings.render.auto_sidebar.description",
                            defaultValue: "Automatically renders the RAW preview in the right-side panel when selecting a photo. Results are cached and reused."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Toggle(String(localized: "settings.render.auto_thumbnails",
                              defaultValue: "Auto-render in Thumbnail grid"),
                       isOn: $settings.autoRenderRawThumbnails)
                Text(String(localized: "settings.render.auto_thumbnails.description",
                            defaultValue: "Replaces RAW thumbnails in the grid with engine-rendered results during scanning. Off by default due to increased scan load."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button(String(localized: "settings.render.cache.clear", defaultValue: "Clear Render Cache"),
                       role: .destructive) {
                    showClearRenderCacheAlert = true
                }
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
                @Bindable var s = settings
                Picker(
                    String(localized: "settings.cache.ttl.label", defaultValue: "Cache Retention"),
                    selection: $s.cacheTTLDays
                ) {
                    ForEach([30, 60, 90, 180, 365], id: \.self) { days in
                        Text(cacheTTLLabel(days)).tag(days)
                    }
                }
                Text(String(localized: "settings.cache.ttl.description",
                            defaultValue: "Thumbnails and perceptual hashes not refreshed within this period are removed at the next launch."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        @Bindable var s = settings
        let maxCacheMB = Int(ProcessInfo.processInfo.physicalMemory / 10 / (1024 * 1024) / 100) * 100
        return Form {
            Section {
                groupingControls
                Text(String(localized: "settings.grouping.description",
                            defaultValue: "These values rarely need adjustment. Changes take effect when you click Re-group or open a new folder."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Grouping")
            }
            Section {
                Stepper(value: $s.thumbnailCacheMB, in: 100...maxCacheMB, step: 100) {
                    LabeledContent(
                        String(localized: "settings.cache.memory.label", defaultValue: "Thumbnail Memory Cache")
                    ) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(settings.thumbnailCacheMB) * 1024 * 1024,
                            countStyle: .memory
                        ))
                        .foregroundStyle(.secondary)
                    }
                }
                Text(String(
                    format: String(localized: "settings.cache.memory.description %lld",
                                   defaultValue: "RAM used to hold decoded thumbnails. Max %lld MB (10%% of your RAM). Increase for smoother scrolling; reduce if other apps feel slow."),
                    Int64(maxCacheMB)
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "settings.cache.memory.section", defaultValue: "Performance"))
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

    // MARK: - Group Scope grid

    @ViewBuilder
    private var scopeGrid: some View {
        @Bindable var s = settings

        Grid(alignment: .center, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("").gridCellAnchor(.center)
                Text(GroupScopeMode.allInGroup.localizedName).font(.caption).foregroundStyle(.secondary)
                Text(GroupScopeMode.representative.localizedName).font(.caption).foregroundStyle(.secondary)
                Text(GroupScopeMode.askEachTime.localizedName).font(.caption).foregroundStyle(.secondary)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("Copy").font(.caption)
                scopeCell($s.copyScopeMode, value: .allInGroup)
                    .help(String(localized: "scope.cell.help.allInGroup", defaultValue: "Apply to all members of the shot group"))
                scopeCell($s.copyScopeMode, value: .representative)
                    .help(String(localized: "scope.cell.help.representative", defaultValue: "Apply only to the representative photo"))
                scopeCell($s.copyScopeMode, value: .askEachTime)
                    .help(String(localized: "scope.cell.help.askEachTime", defaultValue: "Ask which scope each time"))
            }
            GridRow {
                Text("Drag & Drop").font(.caption)
                scopeCell($s.dndScopeMode, value: .allInGroup)
                    .help(String(localized: "scope.cell.help.allInGroup", defaultValue: "Apply to all members of the shot group"))
                scopeCell($s.dndScopeMode, value: .representative)
                    .help(String(localized: "scope.cell.help.representative", defaultValue: "Apply only to the representative photo"))
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .gridCellAnchor(.center)
                    .help(String(localized: "scope.dnd.option.help", defaultValue: "Hold ⌥ while dragging to use the other scope"))
            }
            GridRow {
                Text("Delete").font(.caption)
                scopeCell($s.deleteScopeMode, value: .allInGroup)
                    .help(String(localized: "scope.cell.help.allInGroup", defaultValue: "Apply to all members of the shot group"))
                scopeCell($s.deleteScopeMode, value: .representative)
                    .help(String(localized: "scope.cell.help.representative", defaultValue: "Apply only to the representative photo"))
                scopeCell($s.deleteScopeMode, value: .askEachTime)
                    .help(String(localized: "scope.cell.help.askEachTime", defaultValue: "Ask which scope each time"))
            }
        }
        .padding(.vertical, 4)
        Text(String(localized: "scope.dnd.option.caption", defaultValue: "Drag & Drop: hold ⌥ while dragging to use the other scope."))
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func scopeCell(_ binding: Binding<GroupScopeMode>, value: GroupScopeMode) -> some View {
        Toggle("", isOn: Binding(
            get: { binding.wrappedValue == value },
            set: { if $0 { binding.wrappedValue = value } }
        ))
        .labelsHidden()
        .gridCellAnchor(.center)
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

    /// キャプション用テキスト。xcstrings の値に含まれる **bold** と \n を確実に描画するため
    /// AttributedString(markdown:) を明示的に使用する。
    private func mdCaption(_ key: StaticString, defaultValue: String.LocalizationValue) -> some View {
        let raw = String(localized: key, defaultValue: defaultValue)
        let attr = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
        return Text(attr)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func cacheTTLLabel(_ days: Int) -> String {
        if days >= 365 {
            return String(localized: "settings.cache.ttl.1year", defaultValue: "1 year")
        }
        return String(
            format: String(localized: "settings.cache.ttl.days %lld", defaultValue: "%lld days"),
            Int64(days)
        )
    }

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
