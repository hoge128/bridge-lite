import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isResetHovered = false
    @State private var fileTypeExpanded = true
    @State private var cameraExpanded = true
    @State private var artistExpanded = true
    @State private var lensExpanded = true
    @State private var ratingExpanded = true
    @State private var labelExpanded = true
    @State private var isoExpanded = true
    @State private var focalExpanded = true
    @State private var shutterExpanded = true
    @State private var apertureExpanded = true
    @State private var dateExpanded = true
    @State private var luminanceExpanded = true

    // MARK: - Body

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
                        filterSectionView(for: section, filter: $store.filter)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(minWidth: 180)
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionLabel(
        _ title: LocalizedStringKey,
        isExpanded: Binding<Bool>,
        help: String,
        isActive: Bool,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Button { isExpanded.wrappedValue.toggle() } label: {
                Text(title)
                    .font(.caption2).kerning(1.2)
                    .foregroundStyle(.secondary).textCase(.uppercase)
            }
            .buttonStyle(.plain)
            .help(help)
            Spacer()
            if isActive {
                Button(String(localized: "filter.clear", defaultValue: "Clear"), action: onClear)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Section views

    @ViewBuilder
    private func filterSectionView(for section: FilterSection, filter: Binding<FilterCriteria>) -> some View {
        switch section {
        case .fileType:
            GroupBox {
                DisclosureGroup(isExpanded: $fileTypeExpanded) {
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
                    sectionLabel("File Type", isExpanded: $fileTypeExpanded,
                                 help: "Filter by file type and camera origin",
                                 isActive: filter.wrappedValue.isFileTypeActive) {
                        var f = filter.wrappedValue; f.clearFileType(); filter.wrappedValue = f
                    }
                }
            }

        case .camera:
            if !store.availableCameras.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $cameraExpanded) {
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
                        sectionLabel("Camera", isExpanded: $cameraExpanded,
                                     help: "Uncheck cameras to exclude them from results",
                                     isActive: filter.wrappedValue.isCameraActive) {
                            var f = filter.wrappedValue; f.clearCamera(); filter.wrappedValue = f
                        }
                    }
                }
            }

        case .artist:
            if !store.availableArtists.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $artistExpanded) {
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
                        sectionLabel("Photographer", isExpanded: $artistExpanded,
                                     help: "Uncheck photographers to exclude them (read from EXIF Artist field)",
                                     isActive: filter.wrappedValue.isArtistActive) {
                            var f = filter.wrappedValue; f.clearArtist(); filter.wrappedValue = f
                        }
                    }
                }
            }

        case .lens:
            if !store.availableLenses.isEmpty {
                GroupBox {
                    DisclosureGroup(isExpanded: $lensExpanded) {
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
                        sectionLabel("Lens", isExpanded: $lensExpanded,
                                     help: "Uncheck lenses to exclude them from results",
                                     isActive: filter.wrappedValue.isLensActive) {
                            var f = filter.wrappedValue; f.clearLens(); filter.wrappedValue = f
                        }
                    }
                }
            }

        case .rating:
            GroupBox {
                DisclosureGroup(isExpanded: $ratingExpanded) {
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
                    sectionLabel("Rating", isExpanded: $ratingExpanded,
                                 help: "Show only photos with checked ratings. Nothing checked = show all ratings",
                                 isActive: filter.wrappedValue.isRatingActive) {
                        var f = filter.wrappedValue; f.clearRating(); filter.wrappedValue = f
                    }
                }
            }

        case .label:
            GroupBox {
                DisclosureGroup(isExpanded: $labelExpanded) {
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
                    sectionLabel("Label", isExpanded: $labelExpanded,
                                 help: "Click to filter by label color. Multiple selection supported",
                                 isActive: filter.wrappedValue.isLabelActive) {
                        var f = filter.wrappedValue; f.clearLabel(); filter.wrappedValue = f
                    }
                }
            }

        case .iso:
            GroupBox {
                DisclosureGroup(isExpanded: $isoExpanded) {
                    ExifHistogramView(bars: store.isoBuckets, isLoading: store.isLoading, minText: filter.isoMin, maxText: filter.isoMax)
                } label: {
                    sectionLabel("ISO", isExpanded: $isoExpanded,
                                 help: "Filter by ISO sensitivity. Click bars to select range or type values directly",
                                 isActive: filter.wrappedValue.isISOActive) {
                        var f = filter.wrappedValue; f.clearISO(); filter.wrappedValue = f
                    }
                }
            }

        case .focal:
            GroupBox {
                DisclosureGroup(isExpanded: $focalExpanded) {
                    ExifHistogramView(bars: store.focalBuckets, isLoading: store.isLoading, minText: filter.focalMin, maxText: filter.focalMax)
                } label: {
                    sectionLabel("Focal Length", isExpanded: $focalExpanded,
                                 help: "Filter by focal length (35mm equiv). Click bars to select range",
                                 isActive: filter.wrappedValue.isFocalActive) {
                        var f = filter.wrappedValue; f.clearFocal(); filter.wrappedValue = f
                    }
                }
            }

        case .shutter:
            GroupBox {
                DisclosureGroup(isExpanded: $shutterExpanded) {
                    ExifHistogramView(bars: store.shutterBuckets, isLoading: store.isLoading, minText: filter.shutterMin, maxText: filter.shutterMax)
                } label: {
                    sectionLabel("Shutter", isExpanded: $shutterExpanded,
                                 help: "Filter by shutter speed. 1/2000s shown as '2k', 1/60s as '60'",
                                 isActive: filter.wrappedValue.isShutterActive) {
                        var f = filter.wrappedValue; f.clearShutter(); filter.wrappedValue = f
                    }
                }
            }

        case .aperture:
            GroupBox {
                DisclosureGroup(isExpanded: $apertureExpanded) {
                    ExifHistogramView(bars: store.apertureBuckets, isLoading: store.isLoading, minText: filter.apertureMin, maxText: filter.apertureMax)
                } label: {
                    sectionLabel("Aperture", isExpanded: $apertureExpanded,
                                 help: "Filter by aperture (F-number). Click bars to select range",
                                 isActive: filter.wrappedValue.isApertureActive) {
                        var f = filter.wrappedValue; f.clearAperture(); filter.wrappedValue = f
                    }
                }
            }

        case .date:
            GroupBox {
                DisclosureGroup(isExpanded: $dateExpanded) {
                    CalendarPickerView()
                        .padding(.top, 4)
                } label: {
                    sectionLabel("Date", isExpanded: $dateExpanded,
                                 help: "Filter by shooting date. Click presets or tap calendar days to select a range or individual dates.",
                                 isActive: filter.wrappedValue.isDateActive) {
                        var f = filter.wrappedValue; f.clearDate(); filter.wrappedValue = f
                    }
                }
            }

        case .luminance:
            GroupBox {
                DisclosureGroup(isExpanded: $luminanceExpanded) {
                    ExifHistogramView(bars: store.luminanceBuckets, isLoading: store.isLoading, minText: filter.luminanceMin, maxText: filter.luminanceMax)
                } label: {
                    sectionLabel("Luminance", isExpanded: $luminanceExpanded,
                                 help: "Filter by average luminance (0 = dark, 255 = bright)",
                                 isActive: filter.wrappedValue.isLuminanceActive) {
                        var f = filter.wrappedValue; f.clearLuminance(); filter.wrappedValue = f
                    }
                }
            }
        }
    }
}
