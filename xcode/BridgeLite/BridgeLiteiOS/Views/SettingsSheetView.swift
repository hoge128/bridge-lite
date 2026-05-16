import SwiftUI

struct SettingsSheetView: View {
    @Bindable var scanStore: ScanStore
    @State private var showCacheClearConfirm = false
    @State private var showPropagationHelp = false
    @State private var cacheSizeBytes: Int64 = 0
    var onDismiss: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Sort")) {
                    Picker(String(localized: "Sort by"), selection: $scanStore.sortKey) {
                        ForEach(IOSSortKey.allCases, id: \.self) { key in
                            Text(key.localizedName).tag(key)
                        }
                    }
                    Toggle(String(localized: "Ascending"), isOn: $scanStore.sortAscending)
                }

                Section(String(localized: "settings.metadata.section", defaultValue: "Metadata")) {
                    Picker(String(localized: "settings.metadata.jpg_write_mode", defaultValue: "JPEG Metadata"),
                           selection: $scanStore.jpgWriteMode) {
                        ForEach(JpgWriteMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    Button(role: .destructive) {
                        JpgMetadataDefaults.resetJpgEmbedWarning()
                    } label: {
                        Label(String(localized: "settings.reset_embed_warning", defaultValue: "Reset Write Warning"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(scanStore.jpgWriteMode != .embed || !JpgMetadataDefaults.hasShownJpgEmbedWarning())
                }

                Section(String(localized: "settings.render.section", defaultValue: "RAW Rendering")) {
                    Toggle(isOn: $scanStore.autoRenderRawDetail) {
                        Label(
                            String(localized: "settings.render.auto_detail", defaultValue: "Auto-render in Detail view"),
                            systemImage: "camera.aperture"
                        )
                    }
                }

                Section {
                    propagationGrid
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                } header: {
                    HStack {
                        Text(String(localized: "settings.propagation.section", defaultValue: "Rating Propagation"))
                        Spacer()
                        Button {
                            showPropagationHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .popover(isPresented: $showPropagationHelp, arrowEdge: .top) {
                            propagationHelpPopover
                        }
                    }
                }

                Section(String(localized: "settings.filter_order.section", defaultValue: "Filter Order")) {
                    NavigationLink(String(localized: "settings.filter_order.customize", defaultValue: "Customize Order")) {
                        FilterOrderEditorView(scanStore: scanStore)
                    }
                }

                Section(String(localized: "Cache")) {
                    LabeledContent(String(localized: "Cache Size")) {
                        Text(Self.byteFormatter.string(fromByteCount: cacheSizeBytes))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showCacheClearConfirm = true
                    } label: {
                        Label(String(localized: "Clear Cache"), systemImage: "trash")
                    }
                    .disabled(cacheSizeBytes == 0)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done")) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { cacheSizeBytes = ScanStore.cacheSizeBytes() }
        .interactiveDismissDisabled(false)
        .confirmationDialog(
            String(localized: "Clear Cache?"),
            isPresented: $showCacheClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                scanStore.clearCache()
                onDismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Thumbnail cache will be deleted and regenerated on the next scan.")
        }
    }

    // MARK: - Propagation help popover

    private var propagationHelpPopover: some View {
        let raw = String(localized: "settings.propagation.help.body",
                         defaultValue: "When you rate or label a photo, the rating is automatically copied to the other file types in the same shot group.\n\n**Row**: the kind you are rating\n**Column**: the kinds that receive the same rating\n**✓**: always applies to the same kind")
        let attr = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(raw)
        return ScrollView {
            Text(attr)
                .font(.callout)
                .padding()
                .frame(maxWidth: 320, alignment: .leading)
        }
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Propagation grid

    @ViewBuilder
    private var propagationGrid: some View {
        @Bindable var store = scanStore
        let soocLabel = PhotoKind.sooc.localizedName
        let devLabel  = PhotoKind.developed.localizedName

        Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("").gridCellAnchor(.center)
                Text(soocLabel).font(.caption).foregroundStyle(.secondary)
                Text("RAW").font(.caption).foregroundStyle(.secondary)
                Text(devLabel).font(.caption).foregroundStyle(.secondary)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text(soocLabel).font(.caption)
                propagationLockedCell
                Toggle("", isOn: $store.soocToRaw).labelsHidden()
                Toggle("", isOn: $store.soocToDeveloped).labelsHidden()
            }
            GridRow {
                Text("RAW").font(.caption)
                Toggle("", isOn: $store.rawToSooc).labelsHidden()
                propagationLockedCell
                Toggle("", isOn: $store.rawToDeveloped).labelsHidden()
            }
            GridRow {
                Text(devLabel).font(.caption)
                Toggle("", isOn: $store.developedToSooc).labelsHidden()
                Toggle("", isOn: $store.developedToRaw).labelsHidden()
                propagationLockedCell
            }
        }
    }

    private var propagationLockedCell: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.secondary)
            .gridCellAnchor(.center)
    }
}

// MARK: - Filter Order Editor

struct FilterOrderEditorView: View {
    @Bindable var scanStore: ScanStore

    var body: some View {
        List {
            ForEach(scanStore.filterCategoryOrder) { cat in
                Label(cat.title, systemImage: cat.icon)
            }
            .onMove { from, to in
                scanStore.filterCategoryOrder.move(fromOffsets: from, toOffset: to)
                scanStore.saveFilterCategoryOrder()
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(String(localized: "settings.filter_order.title", defaultValue: "Filter Order"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(String(localized: "settings.filter_order.reset", defaultValue: "Reset to Default")) {
                    withAnimation { scanStore.resetFilterCategoryOrder() }
                }
                .disabled(scanStore.filterCategoryOrder == FilterCategory.allCases)
            }
        }
    }
}
