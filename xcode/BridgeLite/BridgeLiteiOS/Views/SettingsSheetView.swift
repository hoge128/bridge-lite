import SwiftUI

struct SettingsSheetView: View {
    @Bindable var scanStore: ScanStore
    @State private var showCacheClearConfirm = false
    @State private var showPropagationHelp = false
    @State private var showMetadataHelp = false
    @State private var showThumbQualityHelp = false
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

                Section {
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
                } header: {
                    HStack {
                        Text(String(localized: "settings.metadata.section", defaultValue: "Metadata"))
                        Spacer()
                        Button {
                            showMetadataHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .popover(isPresented: $showMetadataHelp, arrowEdge: .top) {
                            metadataHelpPopover
                        }
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

                Section {
                    Picker(String(localized: "settings.thumb_quality.title", defaultValue: "Thumbnail Quality"),
                           selection: $scanStore.thumbnailQualityMode) {
                        ForEach(ThumbnailQualityMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    Text(String(localized: "settings.thumb_quality.hint",
                                defaultValue: "After switching, tap Clear Cache below to regenerate thumbnails."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text(String(localized: "settings.thumb_quality.section", defaultValue: "Thumbnails"))
                        Spacer()
                        Button {
                            showThumbQualityHelp = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .popover(isPresented: $showThumbQualityHelp, arrowEdge: .top) {
                            thumbQualityHelpPopover
                        }
                    }
                }

                Section(String(localized: "settings.render.section", defaultValue: "RAW Rendering")) {
                    Toggle(isOn: $scanStore.autoRenderRawDetail) {
                        Label(
                            String(localized: "settings.render.auto_detail", defaultValue: "Auto-render in Detail view"),
                            systemImage: "camera.aperture"
                        )
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

                Section {
                    Link(destination: URL(string: "https://hoge128.github.io/bridge-lite/privacy-policy")!) {
                        Label(String(localized: "settings.privacy_policy", defaultValue: "Privacy Policy"), systemImage: "hand.raised")
                    }
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

    // MARK: - Metadata help popover

    private var metadataHelpPopover: some View {
        let raw = String(localized: "settings.metadata.help.body",
                         defaultValue: "**Embed** — Rating is written directly into the JPEG file. The file is self-contained and portable, but the original is modified.\n\n**Sidecar** — Rating is saved as a separate `.xmp` file next to the image. The original is never modified, but you must copy the `.xmp` alongside the image when transferring to other software (Lightroom, Capture One, etc.).\n\nRAW files always use a sidecar regardless of this setting.\n\n**Note:** In Sidecar mode, a JPEG and its paired RAW share the same `.xmp` file (e.g. `IMG_0001.xmp`). Rating one automatically updates the other.")
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

    // MARK: - Thumbnail quality help popover

    private var thumbQualityHelpPopover: some View {
        let raw = String(localized: "settings.thumb_quality.help.body",
                         defaultValue: "**Quality** — Falls back to decoding the full image when no embedded thumbnail exists or when the embedded one is too small. Best visual quality but slower for HEIF and DNG.\n\n**Speed** — Reads only the embedded thumbnail. If no embedded thumbnail exists, the slot is left blank until you scroll past it. Fastest; never decodes full pixel data before full-screen view.")
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
                if scanStore.jpgWriteMode == .sidecar {
                    propagationLockedCell
                } else {
                    Toggle("", isOn: $store.soocToRaw).labelsHidden()
                }
                Toggle("", isOn: $store.soocToDeveloped).labelsHidden()
            }
            GridRow {
                Text("RAW").font(.caption)
                if scanStore.jpgWriteMode == .sidecar {
                    propagationLockedCell
                } else {
                    Toggle("", isOn: $store.rawToSooc).labelsHidden()
                }
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
