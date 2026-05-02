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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filters")
                    .font(.caption2)
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal)
                    .padding(.top, 4)

                HStack {
                    Text("Flatten")
                        .font(.caption)
                    Spacer()
                    Toggle("", isOn: $store.filter.flatten)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .help("Show every file individually. Disables grouping and replaces the kind filter with an extension filter.")

                ForEach(store.settings.filterSectionOrder) { section in
                    filterSectionView(for: section, filter: $store.filter)
                        .padding(.horizontal, 8)
                }

                Divider()
                    .padding(.horizontal, 8)

                Button(action: { store.filter.reset() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Filters")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        isResetHovered && store.filter.isActive
                            ? Color.secondary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                }
                .buttonStyle(.borderless)
                .disabled(!store.filter.isActive)
                .opacity(store.filter.isActive || isResetHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: store.filter.isActive)
                .animation(.easeInOut(duration: 0.15), value: isResetHovered)
                .onHover { isResetHovered = $0 }
                .padding(.horizontal, 8)
            }
            .padding(.vertical)
        }
        .frame(minWidth: 180)
        .background(.ultraThinMaterial)
    }

    // MARK: - Section views

    @ViewBuilder
    private func filterSectionView(for section: FilterSection, filter: Binding<FilterCriteria>) -> some View {
        switch section {
        case .fileType:
            SectionBox("File Type", isExpanded: $fileTypeExpanded) {
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
                        Button { cameraExpanded.toggle() } label: {
                            Text("Camera")
                                .font(.caption2).kerning(1.2)
                                .foregroundStyle(.secondary).textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                        .help("Uncheck cameras to exclude them from results")
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
                        Button { artistExpanded.toggle() } label: {
                            Text("Photographer")
                                .font(.caption2).kerning(1.2)
                                .foregroundStyle(.secondary).textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                        .help("Uncheck photographers to exclude them (read from EXIF Artist field)")
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
                        Button { lensExpanded.toggle() } label: {
                            Text("Lens")
                                .font(.caption2).kerning(1.2)
                                .foregroundStyle(.secondary).textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                        .help("Uncheck lenses to exclude them from results")
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
                        )) { Text("No Rating").font(.caption) }
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
                                Text(String(repeating: "★", count: n)).font(.caption)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Button { ratingExpanded.toggle() } label: {
                        Text("Rating")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Show only photos with checked ratings. Nothing checked = show all ratings")
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
                                    Circle().stroke(
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
                    Button { labelExpanded.toggle() } label: {
                        Text("Label")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Click to filter by label color. Multiple selection supported")
                }
            }

        case .iso:
            GroupBox {
                DisclosureGroup(isExpanded: $isoExpanded) {
                    ExifHistogramView(bars: store.isoBuckets, minText: filter.isoMin, maxText: filter.isoMax)
                } label: {
                    Button { isoExpanded.toggle() } label: {
                        Text("ISO")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by ISO sensitivity. Click bars to select range or type values directly")
                }
            }

        case .focal:
            GroupBox {
                DisclosureGroup(isExpanded: $focalExpanded) {
                    ExifHistogramView(bars: store.focalBuckets, minText: filter.focalMin, maxText: filter.focalMax)
                } label: {
                    Button { focalExpanded.toggle() } label: {
                        Text("Focal Length")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by focal length (35mm equiv). Click bars to select range")
                }
            }

        case .shutter:
            GroupBox {
                DisclosureGroup(isExpanded: $shutterExpanded) {
                    ExifHistogramView(bars: store.shutterBuckets, minText: filter.shutterMin, maxText: filter.shutterMax)
                } label: {
                    Button { shutterExpanded.toggle() } label: {
                        Text("Shutter")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by shutter speed. 1/2000s shown as '2k', 1/60s as '60'")
                }
            }

        case .aperture:
            GroupBox {
                DisclosureGroup(isExpanded: $apertureExpanded) {
                    ExifHistogramView(bars: store.apertureBuckets, minText: filter.apertureMin, maxText: filter.apertureMax)
                } label: {
                    Button { apertureExpanded.toggle() } label: {
                        Text("Aperture")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by aperture (F-number). Click bars to select range")
                }
            }

        case .date:
            GroupBox {
                DisclosureGroup(isExpanded: $dateExpanded) {
                    ExifHistogramView(bars: store.dateBuckets, minText: filter.dateMin, maxText: filter.dateMax)
                } label: {
                    Button { dateExpanded.toggle() } label: {
                        Text("Date")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by shooting date. Within 14 days = daily buckets, otherwise monthly")
                }
            }

        case .luminance:
            GroupBox {
                DisclosureGroup(isExpanded: $luminanceExpanded) {
                    ExifHistogramView(bars: store.luminanceBuckets, minText: filter.luminanceMin, maxText: filter.luminanceMax)
                } label: {
                    Button { luminanceExpanded.toggle() } label: {
                        Text("Luminance")
                            .font(.caption2).kerning(1.2)
                            .foregroundStyle(.secondary).textCase(.uppercase)
                    }
                    .buttonStyle(.plain)
                    .help("Filter by average luminance (0 = dark, 255 = bright)")
                }
            }
        }
    }
}

