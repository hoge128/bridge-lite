import SwiftUI

// MARK: - Filter category

enum FilterCategory: String, CaseIterable, Identifiable {
    case kind, rating, label, aperture, focal, shutter, iso, camera, lens, artist
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .rating:   return "star"
        case .label:    return "circle.fill"
        case .kind:     return "photo"
        case .camera:   return "camera"
        case .lens:     return "camera.aperture"
        case .artist:   return "person"
        case .iso:      return "film"
        case .focal:    return "scope"
        case .shutter:  return "timer"
        case .aperture: return "f.cursive"
        }
    }

    var title: String {
        switch self {
        case .rating:   return String(localized: "filter.category.rating",   defaultValue: "Rating")
        case .label:    return String(localized: "filter.category.label",    defaultValue: "Label")
        case .kind:     return String(localized: "filter.category.kind",     defaultValue: "File Type")
        case .camera:   return String(localized: "filter.category.camera",   defaultValue: "Camera")
        case .lens:     return String(localized: "filter.category.lens",     defaultValue: "Lens")
        case .artist:   return String(localized: "filter.category.artist",   defaultValue: "Artist")
        case .iso:      return String(localized: "filter.category.iso",      defaultValue: "ISO")
        case .focal:    return String(localized: "filter.category.focal",    defaultValue: "Focal")
        case .shutter:  return String(localized: "filter.category.shutter",  defaultValue: "Shutter")
        case .aperture: return String(localized: "filter.category.aperture", defaultValue: "Aperture")
        }
    }
}

// MARK: - Pattern C: Scrollable glass capsule strip

struct FilterBarView: View {
    @Binding var selectedCategory: FilterCategory?
    var scanStore: ScanStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                chipStrip
                    .padding(.vertical, 4)
            }
            .onChange(of: selectedCategory) { _, newVal in
                if let cat = newVal {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(cat, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 52)
    }

    // iOS 26: GlassEffectContainer で隣接カプセルを1枚の glass blob に連結
    @ViewBuilder
    private var chipStrip: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer {
                chipHStack
            }
        } else {
            chipHStack
        }
    }

    private var chipHStack: some View {
        HStack(spacing: 8) {
            if scanStore.isFilterActive {
                resetChip
                    .transition(.scale.combined(with: .opacity))
                    .id("reset")
            }
            ForEach(scanStore.filterCategoryOrder) { cat in
                GlassFilterChip(
                    category: cat,
                    isSelected: selectedCategory == cat,
                    isActive: scanStore.isFilterActive(for: cat)
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedCategory = selectedCategory == cat ? nil : cat
                    }
                }
                .id(cat)
            }
        }
    }

    private var resetChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                scanStore.clearAllFilters()
                selectedCategory = nil
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                Text(String(localized: "filter.reset_all", defaultValue: "Reset"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .foregroundStyle(Color.red)
        }
        .buttonStyle(GlassChipButtonStyle(isSelected: true, isActive: false, tintColor: .red))
        .contentShape(Capsule())
    }
}

// MARK: - Glass chip

private struct GlassFilterChip: View {
    let category: FilterCategory
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Text(category.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(GlassChipButtonStyle(isSelected: isSelected, isActive: isActive))
        .contentShape(Capsule())
    }
}

private struct GlassChipButtonStyle: ButtonStyle {
    var isSelected: Bool
    var isActive: Bool
    var tintColor: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        GlassChipBody(configuration: configuration, isSelected: isSelected, isActive: isActive, tintColor: tintColor)
    }

    private struct GlassChipBody: View {
        let configuration: Configuration
        let isSelected: Bool
        let isActive: Bool
        let tintColor: Color

        var body: some View {
            if #available(iOS 26, *) {
                configuration.label
                    .glassEffect(
                        isActive
                            ? .regular.interactive(true).tint(tintColor.opacity(0.22))
                            : .regular.interactive(true).tint(isSelected ? tintColor.opacity(0.22) : Color.clear.opacity(0)),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                isSelected ? tintColor.opacity(0.55) : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isSelected ? tintColor.opacity(0.40) : .clear,
                        radius: 8, x: 0, y: 1
                    )
                    .opacity(configuration.isPressed ? 0.72 : 1)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1)
            } else {
                configuration.label
                    .background(
                        isActive || isSelected
                            ? AnyShapeStyle(tintColor.opacity(isActive ? 0.16 : 0.14))
                            : AnyShapeStyle(.ultraThinMaterial),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                isSelected ? tintColor.opacity(0.55) : Color.secondary.opacity(0.2),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isSelected ? tintColor.opacity(0.38) : .clear,
                        radius: 8, x: 0, y: 1
                    )
                    .opacity(configuration.isPressed ? 0.72 : 1)
                    .scaleEffect(configuration.isPressed ? 0.96 : 1)
            }
        }
    }
}

// MARK: - Options panel (floating glass card above bar)

struct FilterOptionsPanelView: View {
    let category: FilterCategory
    var scanStore: ScanStore
    let ratings: [UInt64: XmpData]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if scanStore.isFilterActive(for: category) {
                    Button(String(localized: "filter.clear", defaultValue: "Clear")) {
                        scanStore.clearFilter(category)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 16)

            FilterCategoryContent(category: category, scanStore: scanStore, ratings: ratings)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .padding(.top, 14)
        .adaptiveGlass(cornerRadius: 20)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Category chips content

struct FilterCategoryContent: View {
    let category: FilterCategory
    @Bindable var scanStore: ScanStore
    var ratings: [UInt64: XmpData] = [:]

    var body: some View {
        Group {
            switch category {
            case .rating:  ratingRow
            case .label:   labelRow
            case .kind:    kindRow
            case .camera:
                chipRow(values: scanStore.availableCameras,
                        isActive: { scanStore.filterCameras.contains($0) },
                        toggle:   { scanStore.toggleCamera($0) })
            case .lens:
                chipRow(values: scanStore.availableLenses,
                        isActive: { scanStore.filterLenses.contains($0) },
                        toggle:   { scanStore.toggleLens($0) })
            case .artist:
                chipRow(values: scanStore.availableArtists,
                        isActive: { scanStore.filterArtists.contains($0) },
                        toggle:   { scanStore.toggleArtist($0) })
            case .iso:      isoHistogram
            case .focal:    focalHistogram
            case .shutter:  shutterHistogram
            case .aperture: apertureHistogram
            }
        }
    }

    private var isoHistogram: some View {
        ExifHistogramView(bars: scanStore.isoBuckets,
                          minText: $scanStore.isoMin,
                          maxText: $scanStore.isoMax)
            .frame(height: 56)
    }

    private var focalHistogram: some View {
        ExifHistogramView(bars: scanStore.focalBuckets,
                          minText: $scanStore.focalMin,
                          maxText: $scanStore.focalMax)
            .frame(height: 56)
    }

    private var shutterHistogram: some View {
        ExifHistogramView(bars: scanStore.shutterBuckets,
                          minText: $scanStore.shutterMin,
                          maxText: $scanStore.shutterMax)
            .frame(height: 56)
    }

    private var apertureHistogram: some View {
        ExifHistogramView(bars: scanStore.apertureBuckets,
                          minText: $scanStore.apertureMin,
                          maxText: $scanStore.apertureMax)
            .frame(height: 56)
    }

    private var ratingRow: some View {
        let counts = scanStore.ratingCounts(from: ratings)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ratingChip(star: 0, label: String(localized: "No Rating"),
                           count: counts[0] ?? 0)
                ForEach(1...5, id: \.self) { star in
                    ratingChip(star: star,
                               label: String(repeating: "★", count: star),
                               count: counts[star] ?? 0)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func ratingChip(star: Int, label: String, count: Int) -> some View {
        Button { scanStore.toggleRating(star) } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption)
                Text("(\(count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .buttonStyle(.adaptiveGlass(isActive: scanStore.filterRatings.contains(star)))
    }

    private var labelRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(XmpLabel.allCases, id: \.self) { label in
                    let active = scanStore.filterLabels.contains(label)
                    Button { scanStore.toggleLabel(label) } label: {
                        Circle()
                            .fill(label.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(active ? Color.accentColor : Color.clear, lineWidth: 2.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var kindRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([PhotoKind.raw, .sooc, .developed, .indeterminate], id: \.self) { kind in
                        Button(kind.localizedName) {
                            scanStore.toggleKind(kind)
                        }
                        .buttonStyle(.adaptiveGlass(isActive: scanStore.filterKinds.contains(kind)))
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                scanStore.filterCameraOnly.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: scanStore.filterCameraOnly ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(scanStore.filterCameraOnly ? Color.accentColor : Color.secondary)
                    Text(String(localized: "filter.kind.camera_only", defaultValue: "Camera shots only"))
                        .font(.caption)
                        .foregroundStyle(scanStore.filterCameraOnly ? Color.primary : Color.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func chipRow(
        values: [String],
        isActive: @escaping (String) -> Bool,
        toggle: @escaping (String) -> Void
    ) -> some View {
        Group {
            if values.isEmpty {
                Text(String(localized: "filter.no_data", defaultValue: "No data"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(values, id: \.self) { v in
                            Button(v) { toggle(v) }
                                .buttonStyle(.adaptiveGlass(isActive: isActive(v)))
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}
