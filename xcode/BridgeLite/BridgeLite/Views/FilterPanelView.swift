import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

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
                    .font(.headline)
                    .padding(.horizontal)

                // Camera
                if !store.availableCameras.isEmpty {
                    GroupBox("Camera") {
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
                    GroupBox("Lens") {
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
                    }
                    .padding(.horizontal, 8)
                }

                // Rating
                GroupBox("Rating") {
                    let isJa = store.settings.language == "ja"
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0...5, id: \.self) { n in
                            Toggle(isOn: Binding(
                                get: { store.filter.filterRatings.contains(n) },
                                set: { on in
                                    if on { store.filter.filterRatings.insert(n) }
                                    else  { store.filter.filterRatings.remove(n) }
                                }
                            )) {
                                HStack(spacing: 4) {
                                    if n == 0 {
                                        Text(isJa ? "評価なし" : "No rating")
                                            .font(.caption)
                                    } else {
                                        Text(String(repeating: "★", count: n))
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 8)

                // Label
                GroupBox("Label") {
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
                GroupBox("Flag") {
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
                GroupBox("ISO") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: isoBuckets,
                        minText: $store.filter.isoMin,
                        maxText: $store.filter.isoMax
                    )
                    HStack {
                        TextField("Min", text: $store.filter.isoMin)
                            .frame(width: 50)
                        Text("–")
                        TextField("Max", text: $store.filter.isoMax)
                            .frame(width: 50)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)

                // Focal length (mm, 35mm equiv)
                GroupBox("Focal Length (mm)") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: focalBuckets,
                        minText: $store.filter.focalMin,
                        maxText: $store.filter.focalMax
                    )
                    HStack {
                        TextField("Min", text: $store.filter.focalMin)
                            .frame(width: 50)
                        Text("–")
                        TextField("Max", text: $store.filter.focalMax)
                            .frame(width: 50)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)

                // Shutter speed (seconds, fractions OK: 1/200)
                GroupBox("Shutter (s)") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: shutterBuckets,
                        minText: $store.filter.shutterMin,
                        maxText: $store.filter.shutterMax
                    )
                    HStack {
                        TextField("e.g. 1/1000", text: $store.filter.shutterMin)
                            .frame(width: 65)
                        Text("–")
                        TextField("e.g. 1/60", text: $store.filter.shutterMax)
                            .frame(width: 65)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)

                // Aperture (F値)
                GroupBox("Aperture (f/)") {
                    @Bindable var store = store
                    ExifHistogramView(
                        bars: apertureBuckets,
                        minText: $store.filter.apertureMin,
                        maxText: $store.filter.apertureMax
                    )
                    HStack {
                        TextField("Min", text: $store.filter.apertureMin)
                            .frame(width: 50)
                        Text("–")
                        TextField("Max", text: $store.filter.apertureMax)
                            .frame(width: 50)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)

                Divider()
                    .padding(.horizontal, 8)

                Button("Reset Filters") { store.filter.reset() }
                    .disabled(!store.filter.isActive)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical)
        }
        .frame(minWidth: 180)
    }
}
