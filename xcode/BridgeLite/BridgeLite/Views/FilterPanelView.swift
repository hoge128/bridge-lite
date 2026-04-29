import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    @State private var isResetHovered = false
    @State private var ratingExpanded = true
    @State private var cameraExpanded = true
    @State private var artistExpanded = true
    @State private var labelExpanded = true
    @State private var isoExpanded = true
    @State private var focalExpanded = true
    @State private var shutterExpanded = true
    @State private var apertureExpanded = true
    @State private var dateExpanded = true

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

    // MARK: - Date histogram buckets

    private static let exifDateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private func photoDate(for id: UInt64) -> Date? {
        if let dt = store.exifData[id]?.datetime,
           let d = Self.exifDateParser.date(from: dt) { return d }
        return store.entries[id]?.createdDate
    }

    private var dateBuckets: [ExifBucket] {
        let cal = Calendar.current
        let dates = store.entries.keys.compactMap { photoDate(for: $0) }
        guard let minDate = dates.min(), let maxDate = dates.max() else { return [] }
        let daySpan = cal.dateComponents([.day], from: minDate, to: maxDate).day ?? 0
        return daySpan <= 14
            ? buildDailyBuckets(dates: dates, from: minDate, to: maxDate)
            : buildMonthlyBuckets(dates: dates, from: minDate, to: maxDate)
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let monthLabelFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM"; return f
    }()

    private func buildMonthlyBuckets(dates: [Date], from minDate: Date, to maxDate: Date) -> [ExifBucket] {
        let cal = Calendar.current
        let isoFmt = Self.isoDateFormatter
        let lblFmt = Self.monthLabelFormatter
        let multiYear = cal.component(.year, from: minDate) != cal.component(.year, from: maxDate)
        var buckets: [ExifBucket] = []
        var cursor = cal.date(from: cal.dateComponents([.year, .month], from: minDate))!
        while cursor <= maxDate {
            let nextMonth = cal.date(byAdding: .month, value: 1, to: cursor)!
            let lastDay = cal.date(byAdding: .day, value: -1, to: nextMonth)!
            let count = dates.filter { $0 >= cursor && $0 < nextMonth }.count
            let label: String
            if multiYear {
                let m = cal.component(.month, from: cursor)
                let y = cal.component(.year, from: cursor) % 100
                label = String(format: "%d/'%02d", m, y)
            } else {
                label = lblFmt.string(from: cursor)
            }
            buckets.append(ExifBucket(
                label: label, count: count,
                minText: isoFmt.string(from: cursor), maxText: isoFmt.string(from: lastDay),
                lowerBound: cursor.timeIntervalSince1970, upperBound: lastDay.timeIntervalSince1970
            ))
            cursor = nextMonth
        }
        return buckets
    }

    private func buildDailyBuckets(dates: [Date], from minDate: Date, to maxDate: Date) -> [ExifBucket] {
        let cal = Calendar.current
        let isoFmt = Self.isoDateFormatter
        var buckets: [ExifBucket] = []
        var cursor = cal.startOfDay(for: minDate)
        let end = cal.startOfDay(for: maxDate)
        while cursor <= end {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cursor)!
            let count = dates.filter { $0 >= cursor && $0 < nextDay }.count
            let dateStr = isoFmt.string(from: cursor)
            let m = cal.component(.month, from: cursor)
            let d = cal.component(.day, from: cursor)
            buckets.append(ExifBucket(
                label: "\(m)/\(d)", count: count,
                minText: dateStr, maxText: dateStr,
                lowerBound: cursor.timeIntervalSince1970, upperBound: nextDay.timeIntervalSince1970 - 1
            ))
            cursor = nextDay
        }
        return buckets
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
                    GroupBox {
                        DisclosureGroup(isExpanded: $cameraExpanded) {
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
                                    .toggleStyle(.checkbox)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        } label: {
                            Button { cameraExpanded.toggle() } label: {
                                Text("Camera")
                                    .font(.caption2)
                                    .kerning(1.2)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Photographer (EXIF Artist)
                if !store.availableArtists.isEmpty {
                    GroupBox {
                        DisclosureGroup(isExpanded: $artistExpanded) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(store.availableArtists, id: \.self) { artist in
                                    Toggle(artist, isOn: Binding(
                                        get: { !store.filter.excludedArtists.contains(artist) },
                                        set: { on in
                                            if on { store.filter.excludedArtists.remove(artist) }
                                            else  { store.filter.excludedArtists.insert(artist) }
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
                                    .font(.caption2)
                                    .kerning(1.2)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                            .buttonStyle(.plain)
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
                                    .toggleStyle(.checkbox)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                GroupBox {
                    DisclosureGroup(isExpanded: $ratingExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: Binding(
                                get: { store.filter.filterRatings.contains(0) },
                                set: { on in
                                    if on { store.filter.filterRatings.insert(0) }
                                    else  { store.filter.filterRatings.remove(0) }
                                }
                            )) { Text("No Rating").font(.caption) }
                            .toggleStyle(.checkbox)

                            ForEach(1...5, id: \.self) { n in
                                Toggle(isOn: Binding(
                                    get: { store.filter.filterRatings.contains(n) },
                                    set: { on in
                                        if on { store.filter.filterRatings.insert(n) }
                                        else  { store.filter.filterRatings.remove(n) }
                                    }
                                )) {
                                    Text(String(repeating: "★", count: n))
                                        .font(.caption)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    } label: {
                        Button { ratingExpanded.toggle() } label: {
                            Text("Rating")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Label
                GroupBox {
                    DisclosureGroup(isExpanded: $labelExpanded) {
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
                        .padding(.top, 4)
                    } label: {
                        Button { labelExpanded.toggle() } label: {
                            Text("Label")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
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
                GroupBox {
                    DisclosureGroup(isExpanded: $isoExpanded) {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: isoBuckets,
                            minText: $store.filter.isoMin,
                            maxText: $store.filter.isoMax
                        )
                    } label: {
                        Button { isoExpanded.toggle() } label: {
                            Text("ISO")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Focal length (mm, 35mm equiv)
                GroupBox {
                    DisclosureGroup(isExpanded: $focalExpanded) {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: focalBuckets,
                            minText: $store.filter.focalMin,
                            maxText: $store.filter.focalMax
                        )
                    } label: {
                        Button { focalExpanded.toggle() } label: {
                            Text("Focal Length")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Shutter speed (seconds, fractions OK: 1/200)
                GroupBox {
                    DisclosureGroup(isExpanded: $shutterExpanded) {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: shutterBuckets,
                            minText: $store.filter.shutterMin,
                            maxText: $store.filter.shutterMax
                        )
                    } label: {
                        Button { shutterExpanded.toggle() } label: {
                            Text("Shutter")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Aperture (F値)
                GroupBox {
                    DisclosureGroup(isExpanded: $apertureExpanded) {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: apertureBuckets,
                            minText: $store.filter.apertureMin,
                            maxText: $store.filter.apertureMax
                        )
                    } label: {
                        Button { apertureExpanded.toggle() } label: {
                            Text("Aperture")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                // Date
                GroupBox {
                    DisclosureGroup(isExpanded: $dateExpanded) {
                        @Bindable var store = store
                        ExifHistogramView(
                            bars: dateBuckets,
                            minText: $store.filter.dateMin,
                            maxText: $store.filter.dateMax
                        )
                    } label: {
                        Button { dateExpanded.toggle() } label: {
                            Text("Date")
                                .font(.caption2)
                                .kerning(1.2)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .buttonStyle(.plain)
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

