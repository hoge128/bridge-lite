import SwiftUI

// フィルタパネル。
//
// 性能方針（重要）:
// - ルートにライブブラー（.ultraThinMaterial）を置かない。NavigationSplitView の sidebar 列が
//   OS 標準のサイドバー背景を提供するため不要。縦長パネル全面のブラー再合成はクリックごとの
//   体感遅延の主因だった（CLAUDE.md「SidebarView ルートに material を置く」禁止と同種）。
// - 各フィルタセクションは独立した View struct に分割し、@Observable の再描画を局所化する。
//   非同期 aggregates（ratingCounts/buckets/availability）更新時に該当セクションのみ再描画され、
//   パネル全体の作り直しを避ける。
struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isResetHovered = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack {
                Text("Filters")
                    .font(.caption2)
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { store.resetFilter() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption2)
                        Text("Reset")
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(isResetHovered ? .white : .red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isResetHovered
                            ? Color.red
                            : Color.red.opacity(0.15),
                        in: Capsule()
                    )
                }
                .buttonStyle(.borderless)
                .disabled(!store.filter.isActive)
                .opacity(store.filter.isActive ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: store.filter.isActive)
                .onHover { isResetHovered = $0 }
                .help("Reset Filters")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Flatten")
                            .font(.caption)
                        Spacer()
                        Toggle("", isOn: $store.filter.flatten)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .disabled(!store.filter.nameSearch.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .help(store.filter.nameSearch.isEmpty
                          ? "Show every file individually. Disables grouping and replaces the kind filter with an extension filter."
                          : String(localized: "Locked while searching"))

                    ForEach(store.settings.filterSectionOrder) { section in
                        sectionView(for: section)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(minWidth: 180)
    }

    // 各セクションは独立 struct。親 body はインスタンス化するだけで store.filter を読まないため、
    // フィルタ変更で親が肥大に再評価されることはない（各 struct が必要な分だけ観測する）。
    @ViewBuilder
    private func sectionView(for section: FilterSection) -> some View {
        switch section {
        case .fileType:  FileTypeFilterSection()
        case .camera:    CameraFilterSection()
        case .artist:    ArtistFilterSection()
        case .lens:      LensFilterSection()
        case .rating:    RatingFilterSection()
        case .label:     LabelFilterSection()
        case .flag:      FlagFilterSection()
        case .iso:       IsoFilterSection()
        case .focal:     FocalFilterSection()
        case .focal35:   Focal35FilterSection()
        case .shutter:   ShutterFilterSection()
        case .aperture:  ApertureFilterSection()
        case .date:      DateFilterSection()
        case .timeOfDay: TimeOfDayFilterSection()
        case .luminance: LuminanceFilterSection()
        }
    }
}

// MARK: - 共有セクションラベル

private struct FilterSectionLabel: View {
    @Environment(LibraryStore.self) private var store
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let help: String
    let isActive: Bool
    let onClear: () -> Void

    var body: some View {
        HStack {
            Button { isExpanded.toggle() } label: {
                Text(title)
                    .font(.caption2).kerning(1.2)
                    .foregroundStyle(.secondary).textCase(.uppercase)
            }
            .buttonStyle(.plain)
            .help(help)
            Spacer()
            if isActive {
                Button(String(localized: "filter.clear", defaultValue: "Clear")) {
                    onClear()
                    // クリアで表示件数が増えても、選択中サムネイルが画面内に残るようスクロールを復元
                    store.noteFilterSectionCleared()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - File Type

private struct FileTypeFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    if filter.wrappedValue.flatten {
                        ForEach(store.availableExtensions, id: \.self) { ext in
                            Toggle(isOn: Binding(
                                get: { !filter.wrappedValue.excludedExtensions.contains(ext) },
                                set: { on in
                                    var f = filter.wrappedValue
                                    if on { f.excludedExtensions.remove(ext) }
                                    else  { f.excludedExtensions.insert(ext) }
                                    filter.wrappedValue = f
                                }
                            )) { Text(".\(ext.uppercased())").font(.caption).monospaced() }
                            .toggleStyle(.checkbox)
                            .help("Uncheck extensions to exclude them from results")
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterKinds.contains(.raw) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterKinds.insert(.raw) } else { f.filterKinds.remove(.raw) }
                                filter.wrappedValue = f
                            }
                        )) { Text("RAW").font(.caption) }
                        .toggleStyle(.checkbox)
                        .help("Use RAW as the representative thumbnail per group (groups without RAW are hidden)")

                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterKinds.contains(.sooc) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterKinds.insert(.sooc) } else { f.filterKinds.remove(.sooc) }
                                filter.wrappedValue = f
                            }
                        )) { Text(PhotoKind.sooc.localizedName).font(.caption) }
                        .toggleStyle(.checkbox)
                        .help("Use camera JPEG as the representative thumbnail per group (groups without JPEG are hidden)")

                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterKinds.contains(.developed) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterKinds.insert(.developed) } else { f.filterKinds.remove(.developed) }
                                filter.wrappedValue = f
                            }
                        )) { Text(PhotoKind.developed.localizedName).font(.caption) }
                        .toggleStyle(.checkbox)
                        .help("Use developed JPEG as the representative thumbnail per group (groups without developed JPEG are hidden)")

                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterKinds.contains(.indeterminate) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterKinds.insert(.indeterminate) } else { f.filterKinds.remove(.indeterminate) }
                                filter.wrappedValue = f
                            }
                        )) { Text(PhotoKind.indeterminate.localizedName).font(.caption) }
                        .toggleStyle(.checkbox)
                        .help("Show only images where origin cannot be determined (no camera EXIF metadata)")
                    }

                    Divider()

                    Toggle(isOn: filter.cameraOnly) {
                        Text("Camera shots only").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help("Exclude images without camera Make/Model EXIF (screenshots, web images, etc.)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                FilterSectionLabel(title: "File Type", isExpanded: $expanded,
                                   help: "Filter by file type and camera origin",
                                   isActive: filter.wrappedValue.isFileTypeActive) {
                    var f = filter.wrappedValue; f.clearFileType(); filter.wrappedValue = f
                }
            }
        }
    }
}

// MARK: - Camera / Artist / Lens（除外リスト共通形）

private struct CameraFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        if !store.availableCameras.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.availableCameras, id: \.self) { cam in
                            Toggle(cam, isOn: Binding(
                                get: { !filter.wrappedValue.excludedCameras.contains(cam) },
                                set: { on in
                                    var f = filter.wrappedValue
                                    if on { f.excludedCameras.remove(cam) } else { f.excludedCameras.insert(cam) }
                                    filter.wrappedValue = f
                                }
                            ))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    FilterSectionLabel(title: "Camera", isExpanded: $expanded,
                                       help: "Uncheck cameras to exclude them from results",
                                       isActive: filter.wrappedValue.isCameraActive) {
                        var f = filter.wrappedValue; f.clearCamera(); filter.wrappedValue = f
                    }
                }
            }
        }
    }
}

private struct ArtistFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        if !store.availableArtists.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.availableArtists, id: \.self) { artist in
                            Toggle(artist, isOn: Binding(
                                get: { !filter.wrappedValue.excludedArtists.contains(artist) },
                                set: { on in
                                    var f = filter.wrappedValue
                                    if on { f.excludedArtists.remove(artist) } else { f.excludedArtists.insert(artist) }
                                    filter.wrappedValue = f
                                }
                            ))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    FilterSectionLabel(title: "Photographer", isExpanded: $expanded,
                                       help: "Uncheck photographers to exclude them (read from EXIF Artist field)",
                                       isActive: filter.wrappedValue.isArtistActive) {
                        var f = filter.wrappedValue; f.clearArtist(); filter.wrappedValue = f
                    }
                }
            }
        }
    }
}

private struct LensFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        if !store.availableLenses.isEmpty {
            GroupBox {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.availableLenses, id: \.self) { lens in
                            Toggle(lens, isOn: Binding(
                                get: { !filter.wrappedValue.excludedLenses.contains(lens) },
                                set: { on in
                                    var f = filter.wrappedValue
                                    if on { f.excludedLenses.remove(lens) } else { f.excludedLenses.insert(lens) }
                                    filter.wrappedValue = f
                                }
                            ))
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    FilterSectionLabel(title: "Lens", isExpanded: $expanded,
                                       help: "Uncheck lenses to exclude them from results",
                                       isActive: filter.wrappedValue.isLensActive) {
                        var f = filter.wrappedValue; f.clearLens(); filter.wrappedValue = f
                    }
                }
            }
        }
    }
}

// MARK: - Rating / Label / Flag

private struct RatingFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { filter.wrappedValue.filterRatings.contains(0) },
                        set: { on in
                            var f = filter.wrappedValue
                            if on { f.filterRatings.insert(0) } else { f.filterRatings.remove(0) }
                            filter.wrappedValue = f
                        }
                    )) {
                        HStack(spacing: 4) {
                            Text("No Rating").font(.caption)
                            Text("(\(store.ratingCounts[0] ?? 0))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)

                    ForEach(1...5, id: \.self) { n in
                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterRatings.contains(n) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterRatings.insert(n) } else { f.filterRatings.remove(n) }
                                filter.wrappedValue = f
                            }
                        )) {
                            HStack(spacing: 4) {
                                Text(String(repeating: "★", count: n)).font(.caption)
                                Text("(\(store.ratingCounts[n] ?? 0))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                FilterSectionLabel(title: "Rating", isExpanded: $expanded,
                                   help: "Show only photos with checked ratings. Nothing checked = show all ratings",
                                   isActive: filter.wrappedValue.isRatingActive) {
                    var f = filter.wrappedValue; f.clearRating(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct LabelFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                HStack(spacing: 6) {
                    ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                        Circle()
                            .fill(label.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    filter.wrappedValue.filterLabels.contains(label)
                                    ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                            .onTapGesture {
                                var f = filter.wrappedValue
                                if f.filterLabels.contains(label) { f.filterLabels.remove(label) }
                                else { f.filterLabels.insert(label) }
                                filter.wrappedValue = f
                            }
                            .help(label.name)
                    }
                }
                .padding(.top, 4)
            } label: {
                FilterSectionLabel(title: "Label", isExpanded: $expanded,
                                   help: "Click to filter by label color. Multiple selection supported",
                                   isActive: filter.wrappedValue.isLabelActive) {
                    var f = filter.wrappedValue; f.clearLabel(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct FlagFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(XmpFlag.allCases, id: \.rawValue) { flag in
                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.filterFlags.contains(flag) },
                            set: { on in
                                var f = filter.wrappedValue
                                if on { f.filterFlags.insert(flag) } else { f.filterFlags.remove(flag) }
                                filter.wrappedValue = f
                            }
                        )) {
                            HStack(spacing: 4) {
                                Image(systemName: flag.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(flag.color)
                                Text(flag.name).font(.caption)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                FilterSectionLabel(title: "Flag", isExpanded: $expanded,
                                   help: String(localized: "filter.flag.help",
                                                defaultValue: "Show only flagged photos (Pick / Reject). Nothing checked = show all"),
                                   isActive: filter.wrappedValue.isFlagActive) {
                    var f = filter.wrappedValue; f.clearFlag(); filter.wrappedValue = f
                }
            }
        }
    }
}

// MARK: - ヒストグラム系（ISO / Focal / 35mm / Shutter / Aperture / Luminance）

private struct IsoFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.isoBuckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.isoMin, maxText: filter.wrappedValue.isoMax,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.isoMin = newMin; f.isoMax = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "ISO", isExpanded: $expanded,
                                   help: "Filter by ISO sensitivity. Click bars to select range or type values directly",
                                   isActive: filter.wrappedValue.isISOActive) {
                    var f = filter.wrappedValue; f.clearISO(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct FocalFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.focalBuckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.focalMin, maxText: filter.wrappedValue.focalMax,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.focalMin = newMin; f.focalMax = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "filter.section.focal_lens", isExpanded: $expanded,
                                   help: String(localized: "filter.focal_lens.help",
                                                defaultValue: "Filter by actual lens focal length. Click bars to select range"),
                                   isActive: filter.wrappedValue.isFocalActive) {
                    var f = filter.wrappedValue; f.clearFocal(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct Focal35FilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.focal35Buckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.focal35Min, maxText: filter.wrappedValue.focal35Max,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.focal35Min = newMin; f.focal35Max = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "filter.section.focal_35mm", isExpanded: $expanded,
                                   help: String(localized: "filter.focal_35mm.help",
                                                defaultValue: "Filter by 35mm-equivalent focal length (EXIF 0xA405). Photos without the tag are not affected"),
                                   isActive: filter.wrappedValue.isFocal35Active) {
                    var f = filter.wrappedValue; f.clearFocal35(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct ShutterFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.shutterBuckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.shutterMin, maxText: filter.wrappedValue.shutterMax,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.shutterMin = newMin; f.shutterMax = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "Shutter", isExpanded: $expanded,
                                   help: "Filter by shutter speed. 1/2000s shown as '2k', 1/60s as '60'",
                                   isActive: filter.wrappedValue.isShutterActive) {
                    var f = filter.wrappedValue; f.clearShutter(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct ApertureFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.apertureBuckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.apertureMin, maxText: filter.wrappedValue.apertureMax,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.apertureMin = newMin; f.apertureMax = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "Aperture", isExpanded: $expanded,
                                   help: "Filter by aperture (F-number). Click bars to select range",
                                   isActive: filter.wrappedValue.isApertureActive) {
                    var f = filter.wrappedValue; f.clearAperture(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct LuminanceFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                ExifHistogramView(
                    bars: store.luminanceBuckets, isLoading: store.isLoading,
                    minText: filter.wrappedValue.luminanceMin, maxText: filter.wrappedValue.luminanceMax,
                    onCommit: { newMin, newMax in
                        var f = filter.wrappedValue; f.luminanceMin = newMin; f.luminanceMax = newMax; filter.wrappedValue = f
                    }
                )
                .equatable()
            } label: {
                FilterSectionLabel(title: "Luminance", isExpanded: $expanded,
                                   help: "Filter by average luminance (0 = dark, 255 = bright)",
                                   isActive: filter.wrappedValue.isLuminanceActive) {
                    var f = filter.wrappedValue; f.clearLuminance(); filter.wrappedValue = f
                }
            }
        }
    }
}

// MARK: - Date / Time of day

private struct DateFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                CalendarPickerView()
                    .padding(.top, 4)
            } label: {
                FilterSectionLabel(title: "Date", isExpanded: $expanded,
                                   help: "Filter by shooting date. Click presets or tap calendar days to select a range or individual dates.",
                                   isActive: filter.wrappedValue.isDateActive) {
                    var f = filter.wrappedValue; f.clearDate(); filter.wrappedValue = f
                }
            }
        }
    }
}

private struct TimeOfDayFilterSection: View {
    @Environment(LibraryStore.self) private var store
    @State private var expanded = true
    @State private var showTimeHelp = false

    var body: some View {
        @Bindable var store = store
        let filter = $store.filter
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { filter.wrappedValue.timeSpanMidnight },
                            set: { newVal in
                                var f = filter.wrappedValue
                                f.timeSpanMidnight = newVal
                                f.clearTime()   // モード切替で選択をクリア（表示の整合のため）
                                filter.wrappedValue = f
                            }
                        )) {
                            Text(String(localized: "filter.time.span_midnight",
                                        defaultValue: "Midnight pivot"))
                                .font(.caption2)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)

                        Button { showTimeHelp.toggle() } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showTimeHelp, arrowEdge: .bottom) {
                            Text(String(localized: "filter.time.span_midnight.help",
                                        defaultValue: "Puts midnight at the center of the axis (12 → 11) so you can pick a time range that crosses midnight in a single drag. Use it to filter photos shot overnight — e.g. dusk-to-dawn night scenes, concerts or parties that ran past midnight, New Year countdowns, or astrophotography (say 22:00–02:00)."))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(12)
                                .frame(width: 240)
                        }
                        Spacer()
                    }
                    ExifHistogramView(
                        bars: store.timeBuckets, isLoading: store.isLoading,
                        minText: filter.wrappedValue.timeMin, maxText: filter.wrappedValue.timeMax,
                        onCommit: { newMin, newMax in
                            var f = filter.wrappedValue; f.timeMin = newMin; f.timeMax = newMax; filter.wrappedValue = f
                        }
                    )
                    .equatable()
                }
            } label: {
                FilterSectionLabel(title: "filter.section.time_of_day", isExpanded: $expanded,
                                   help: String(localized: "filter.help.time_of_day",
                                                defaultValue: "Filter by time of day (EXIF capture time, 24h, date ignored). Select e.g. morning hours."),
                                   isActive: filter.wrappedValue.isTimeActive) {
                    var f = filter.wrappedValue; f.clearTime(); filter.wrappedValue = f
                }
            }
        }
    }
}
