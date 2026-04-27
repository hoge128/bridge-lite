import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isResetHovered = false

    // MARK: - Histogram bucket data

    private var isoBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤100",   100,      "",     "100"),
            ("200",    200,      "101",  "200"),
            ("400",    400,      "201",  "400"),
            ("800",    800,      "401",  "800"),
            ("1.6k",   1600,     "801",  "1600"),
            ("3.2k",   3200,     "1601", "3200"),
            ("6.4k",   6400,     "3201", "6400"),
            (">6k",    .infinity, "6401", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in store.exifData.values {
            guard let iso = exif.iso else { continue }
            let d = Double(iso)
            for (i, spec) in specs.enumerated() {
                if d <= spec.upTo { counts[i] += 1; break }
            }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i],
                       minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo,
                       upperBound: spec.upTo)
        }
    }

    private var focalBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤24",   24,       "",    "24"),
            ("35",    35,       "24",  "35"),
            ("50",    50,       "35",  "50"),
            ("85",    85,       "50",  "85"),
            ("135",   135,      "85",  "135"),
            ("200",   200,      "135", "200"),
            (">200",  .infinity, "200", ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in store.exifData.values {
            guard let mm = exif.effectiveFocalMm else { continue }
            for (i, spec) in specs.enumerated() {
                if mm <= spec.upTo { counts[i] += 1; break }
            }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i],
                       minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo,
                       upperBound: spec.upTo)
        }
    }

    private var shutterBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≥2k",  1.0 / 2000, "",       "1/2000"),
            ("1k",   1.0 / 1000, "1/2000", "1/1000"),
            ("500",  1.0 / 500,  "1/1000", "1/500"),
            ("250",  1.0 / 250,  "1/500",  "1/250"),
            ("125",  1.0 / 125,  "1/250",  "1/125"),
            ("60",   1.0 / 60,   "1/125",  "1/60"),
            ("<60",  .infinity,  "1/60",   ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in store.exifData.values {
            guard let s = exif.shutterSeconds else { continue }
            for (i, spec) in specs.enumerated() {
                if s <= spec.upTo { counts[i] += 1; break }
            }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i],
                       minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo,
                       upperBound: spec.upTo)
        }
    }

    private var apertureBuckets: [ExifBucket] {
        typealias Spec = (label: String, upTo: Double, minText: String, maxText: String)
        let specs: [Spec] = [
            ("≤1.8",  1.8,      "",    "1.8"),
            ("2.8",   2.8,      "1.8", "2.8"),
            ("4",     4.0,      "2.8", "4"),
            ("5.6",   5.6,      "4",   "5.6"),
            ("8",     8.0,      "5.6", "8"),
            ("11",    11.0,     "8",   "11"),
            (">11",   .infinity, "11",  ""),
        ]
        var counts = Array(repeating: 0, count: specs.count)
        for exif in store.exifData.values {
            guard let f = exif.fnumberValue else { continue }
            for (i, spec) in specs.enumerated() {
                if f <= spec.upTo { counts[i] += 1; break }
            }
        }
        return specs.enumerated().map { i, spec in
            ExifBucket(label: spec.label, count: counts[i],
                       minText: spec.minText, maxText: spec.maxText,
                       lowerBound: i == 0 ? -.infinity : specs[i - 1].upTo,
                       upperBound: spec.upTo)
        }
    }

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

                // File Kind
                SectionBox("File Type") {
                    let isJa = store.settings.language == "ja"
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { store.filter.filterKinds.contains(.raw) },
                            set: { on in
                                if on { store.filter.filterKinds.insert(.raw) }
                                else  { store.filter.filterKinds.remove(.raw) }
                            }
                        )) { Text("RAW").font(.caption) }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { store.filter.filterKinds.contains(.sooc) },
                            set: { on in
                                if on { store.filter.filterKinds.insert(.sooc) }
                                else  { store.filter.filterKinds.remove(.sooc) }
                            }
                        )) { Text(isJa ? "カメラ出力" : "SOOC").font(.caption) }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { store.filter.filterKinds.contains(.developed) },
                            set: { on in
                                if on { store.filter.filterKinds.insert(.developed) }
                                else  { store.filter.filterKinds.remove(.developed) }
                            }
                        )) { Text(isJa ? "現像済み" : "Developed").font(.caption) }
                        .toggleStyle(.checkbox)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)

                // Camera
                if !store.availableCameras.isEmpty {
                    SectionBox("Camera") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.availableCameras, id: \.self) { cam in
                                Toggle(cam, isOn: Binding(
                                    get: { !store.filter.excludedCameras.contains(cam) },
                                    set: { on in
                                        if on { store.filter.excludedCameras.remove(cam) }
                                        else  { store.filter.excludedCameras.insert(cam) }
                                    }
                                ))
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Lens
                if !store.availableLenses.isEmpty {
                    GroupBox {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(store.availableLenses, id: \.self) { lens in
                                    Toggle(lens, isOn: Binding(
                                        get: { !store.filter.excludedLenses.contains(lens) },
                                        set: { on in
                                            if on { store.filter.excludedLenses.remove(lens) }
                                            else  { store.filter.excludedLenses.insert(lens) }
                                        }
                                    ))
                                    .font(.caption)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Lens")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Rating
                SectionBox("Rating") {
                    HStack(spacing: 6) {
                        Button {
                            if store.filter.filterRatings.contains(0) { store.filter.filterRatings.remove(0) }
                            else { store.filter.filterRatings.insert(0) }
                        } label: {
                            Image(systemName: "nosign")
                                .foregroundStyle(store.filter.filterRatings.contains(0)
                                    ? Color.primary : Color.secondary.opacity(0.3))
                        }
                        .buttonStyle(.plain)
                        .help("No Rating")

                        Divider().frame(height: 14)

                        ForEach(1...5, id: \.self) { n in
                            Button {
                                if store.filter.filterRatings.contains(n) { store.filter.filterRatings.remove(n) }
                                else { store.filter.filterRatings.insert(n) }
                            } label: {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(store.filter.filterRatings.contains(n)
                                        ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.25))
                            }
                            .buttonStyle(.plain)
                            .help("\(n) Star\(n == 1 ? "" : "s")")
                        }
                    }
                    .font(.system(size: 15))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)

                // Label
                SectionBox("Label") {
                    HStack(spacing: 6) {
                        ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                            Circle()
                                .fill(label.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().stroke(
                                        store.filter.filterLabels.contains(label)
                                        ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                                .onTapGesture {
                                    if store.filter.filterLabels.contains(label) {
                                        store.filter.filterLabels.remove(label)
                                    } else {
                                        store.filter.filterLabels.insert(label)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)

                // Flag
                SectionBox("Flag") {
                    HStack(spacing: 8) {
                        ForEach([XmpFlag.pick, XmpFlag.reject], id: \.rawValue) { flag in
                            Button {
                                if store.filter.filterFlags.contains(flag) {
                                    store.filter.filterFlags.remove(flag)
                                } else {
                                    store.filter.filterFlags.insert(flag)
                                }
                            } label: {
                                Text(flag == .pick ? "✓ Pick" : "✕ Reject")
                                    .font(.caption)
                                    .foregroundStyle(
                                        store.filter.filterFlags.contains(flag)
                                        ? Color.accentColor : Color.primary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)

                // ISO range
                SectionBox("ISO") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: isoBuckets,
                        minText: $store.filter.isoMin,
                        maxText: $store.filter.isoMax
                    )
                }
                .padding(.horizontal, 8)

                // Focal length (mm, 35mm equiv)
                SectionBox("Focal Length") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: focalBuckets,
                        minText: $store.filter.focalMin,
                        maxText: $store.filter.focalMax
                    )
                }
                .padding(.horizontal, 8)

                // Shutter speed (seconds, fractions OK: 1/200)
                GroupBox {
                    DisclosureGroup {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: shutterBuckets,
                            minText: $store.filter.shutterMin,
                            maxText: $store.filter.shutterMax
                        )
                    } label: {
                        Text("Shutter")
                            .font(.caption2)
                            .kerning(1.2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
                .padding(.horizontal, 8)

                // Aperture (F値)
                GroupBox {
                    DisclosureGroup {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: apertureBuckets,
                            minText: $store.filter.apertureMin,
                            maxText: $store.filter.apertureMax
                        )
                    } label: {
                        Text("Aperture")
                            .font(.caption2)
                            .kerning(1.2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
                .padding(.horizontal, 8)

                // Date
                GroupBox {
                    DisclosureGroup {
                        @Bindable var store = store
                        VStack(alignment: .leading, spacing: 8) {
                            DateFilterRow(
                                label: "From",
                                date: store.filter.dateFrom,
                                onSet: { store.filter.dateFrom = Calendar.current.startOfDay(for: Date()) },
                                onPick: { store.filter.dateFrom = $0 },
                                onClear: { store.filter.dateFrom = nil }
                            )
                            DateFilterRow(
                                label: "To",
                                date: store.filter.dateTo,
                                onSet: { store.filter.dateTo = Calendar.current.startOfDay(for: Date()) },
                                onPick: { store.filter.dateTo = $0 },
                                onClear: { store.filter.dateTo = nil }
                            )
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack {
                            Text("Date")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            if store.filter.dateFrom != nil || store.filter.dateTo != nil {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)

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
}

// MARK: - DateFilterRow

private struct DateFilterRow: View {
    let label: String
    let date: Date?
    let onSet: () -> Void
    let onPick: (Date) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            if let date {
                DatePicker(
                    "",
                    selection: Binding(get: { date }, set: onPick),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .font(.caption)

                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
            } else {
                Button("Set date", action: onSet)
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
