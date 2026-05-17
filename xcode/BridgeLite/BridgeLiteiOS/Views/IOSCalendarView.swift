import SwiftUI

// MARK: - IOSCalendarView

struct IOSCalendarView: View {
    @Bindable var scanStore: ScanStore
    var ratings: [UInt64: XmpData] = [:]

    @State private var rangeAnchor: Date?

    fileprivate enum SelectionState {
        case none
        case rangeStart
        case rangeEnd
        case rangeMiddle
        case multiSelected
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    private static let summaryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        return calendar
    }

    var body: some View {
        let counts = scanStore.photosPerDay(from: ratings)
        let maxCount = counts.values.max() ?? 1

        VStack(alignment: .leading, spacing: 12) {
            modePicker

            if scanStore.dateMode == .range {
                rangeSummary
            }

            if counts.isEmpty {
                Text(String(localized: "calendar.no_photos", defaultValue: "No photos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                monthList(counts: counts, maxCount: maxCount)
            }
        }
    }

    private var modePicker: some View {
        Picker(
            "",
            selection: Binding<DateMode>(
                get: { scanStore.dateMode },
                set: { newMode in
                    if newMode == .range {
                        scanStore.dateAllowList = []
                    } else {
                        scanStore.dateMin = ""
                        scanStore.dateMax = ""
                        rangeAnchor = nil
                    }
                    scanStore.dateMode = newMode
                }
            )
        ) {
            Text(String(localized: "calendar.mode.range", defaultValue: "Range")).tag(DateMode.range)
            Text(String(localized: "calendar.mode.multi", defaultValue: "Multi")).tag(DateMode.multi)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }

    @ViewBuilder
    private var rangeSummary: some View {
        if !rangeSummaryText.isEmpty {
            HStack(spacing: 8) {
                Text(rangeSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(String(localized: "filter.clear", defaultValue: "Clear")) {
                    scanStore.clearFilter(.date)
                    rangeAnchor = nil
                }
                .font(.caption)
                .buttonStyle(.adaptiveGlass(isActive: true))
            }
        }
    }

    private var rangeSummaryText: String {
        let minText = displayDate(scanStore.dateMin)
        let maxText = displayDate(scanStore.dateMax)

        if let minText, let maxText {
            return String(
                format: String(localized: "calendar.range.to", defaultValue: "%@ - %@"),
                minText,
                maxText
            )
        }

        if let minText {
            return String(
                format: String(localized: "calendar.range.from", defaultValue: "From: %@"),
                minText
            )
        }

        if let maxText {
            return String(
                format: String(localized: "calendar.range.to", defaultValue: "%@ - %@"),
                "",
                maxText
            )
        }

        return ""
    }

    private func monthList(counts: [Date: Int], maxCount: Int) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(monthsToDisplay(for: counts), id: \.self) { month in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(Self.monthFormatter.string(from: month))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        weekdayHeader

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                            spacing: 3
                        ) {
                            ForEach(Array(daysForMonth(month).enumerated()), id: \.offset) { _, date in
                                if let date {
                                    let day = calendar.component(.day, from: date)
                                    let count = counts[date] ?? 0
                                    IOSCalendarDayCell(
                                        day: day,
                                        count: count,
                                        maxCount: maxCount,
                                        selectionState: selectionState(for: date)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if count > 0 {
                                            handleTap(date)
                                        }
                                    }
                                    .allowsHitTesting(count > 0)
                                } else {
                                    Color.clear
                                        .frame(height: 40)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 360)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func monthsToDisplay(for counts: [Date: Int]) -> [Date] {
        let interval = scanStore.datasetDateInterval ?? fallbackInterval
        guard let startMonth = monthStart(for: interval.start),
              let endMonth = monthStart(for: interval.end) else {
            return []
        }
        // 写真がある月の集合（year * 100 + month）
        let monthsWithPhotos: Set<Int> = Set(counts.keys.compactMap { date in
            let c = calendar.dateComponents([.year, .month], from: date)
            guard let y = c.year, let m = c.month else { return nil }
            return y * 100 + m
        })
        var months: [Date] = []
        var cursor = startMonth
        while cursor <= endMonth {
            let c = calendar.dateComponents([.year, .month], from: cursor)
            if let y = c.year, let m = c.month, monthsWithPhotos.contains(y * 100 + m) {
                months.append(cursor)
            }
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    private var fallbackInterval: DateInterval {
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .month, value: -11, to: end) ?? end
        return DateInterval(start: start, end: end)
    }

    private func daysForMonth(_ month: Date) -> [Date?] {
        guard let monthRange = calendar.range(of: .day, in: .month, for: month) else {
            return []
        }

        let leadingBlanks = calendar.component(.weekday, from: month) - 1
        var days = Array<Date?>(repeating: nil, count: leadingBlanks)
        for day in monthRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: month) {
                days.append(calendar.startOfDay(for: date))
            }
        }

        let trailingBlanks = (7 - (days.count % 7)) % 7
        days.append(contentsOf: Array<Date?>(repeating: nil, count: trailingBlanks))
        return days
    }


    private func selectionState(for date: Date) -> SelectionState {
        switch scanStore.dateMode {
        case .range:
            let minDate = parseISODate(scanStore.dateMin)
            let maxDate = parseISODate(scanStore.dateMax)

            if let minDate, calendar.isDate(date, inSameDayAs: minDate) {
                return .rangeStart
            }
            if let maxDate, calendar.isDate(date, inSameDayAs: maxDate) {
                return .rangeEnd
            }
            if let minDate, let maxDate, date > minDate && date < maxDate {
                return .rangeMiddle
            }
            return .none
        case .multi:
            return scanStore.dateAllowList.contains(Self.isoDateString(from: date)) ? .multiSelected : .none
        }
    }

    private func handleTap(_ date: Date) {
        let iso = Self.isoDateString(from: date)

        switch scanStore.dateMode {
        case .range:
            if let anchor = rangeAnchor {
                if calendar.isDate(date, inSameDayAs: anchor) {
                    scanStore.dateMin = ""
                    scanStore.dateMax = ""
                    rangeAnchor = nil
                } else if date > anchor {
                    scanStore.dateMax = iso
                    rangeAnchor = nil
                } else {
                    scanStore.dateMin = iso
                    scanStore.dateMax = ""
                    rangeAnchor = date
                }
            } else {
                scanStore.dateMin = iso
                scanStore.dateMax = ""
                rangeAnchor = date
            }
        case .multi:
            if scanStore.dateAllowList.contains(iso) {
                scanStore.dateAllowList.remove(iso)
            } else {
                scanStore.dateAllowList.insert(iso)
            }
        }
    }

    private func displayDate(_ iso: String) -> String? {
        guard let date = parseISODate(iso) else {
            return nil
        }
        return Self.summaryFormatter.string(from: date)
    }

    private func parseISODate(_ iso: String) -> Date? {
        guard !iso.isEmpty else {
            return nil
        }
        return ScanStore.isoDateFormatter.date(from: iso).map { calendar.startOfDay(for: $0) }
    }

    private func monthStart(for date: Date) -> Date? {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components)
    }

    private static func isoDateString(from date: Date) -> String {
        ScanStore.isoDateFormatter.string(from: date)
    }
}

// MARK: - IOSCalendarDayCell

private struct IOSCalendarDayCell: View {
    let day: Int
    let count: Int
    let maxCount: Int
    let selectionState: IOSCalendarView.SelectionState

    private var isSelected: Bool {
        selectionState == .rangeStart || selectionState == .rangeEnd || selectionState == .multiSelected
    }

    private var bubbleDiameter: CGFloat {
        guard maxCount > 0, count > 0 else {
            return 0
        }
        let ratio = sqrt(Double(count) / Double(maxCount))
        return 10 + (22 * ratio)
    }

    var body: some View {
        ZStack {
            if selectionState == .rangeMiddle {
                Capsule()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(height: 28)
            }

            if count > 0 {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.34) : Color.secondary.opacity(0.17))
                    .frame(width: bubbleDiameter, height: bubbleDiameter)
            }

            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 31, height: 31)
            }

            VStack(spacing: 1) {
                Text("\(day)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white : (count > 0 ? Color.primary : Color.secondary.opacity(0.42)))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 7, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
            }
        }
        .frame(height: 40)
    }
}
