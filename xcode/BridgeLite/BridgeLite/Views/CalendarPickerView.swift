import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DragDate (Transferable)

struct DragDate: Codable, Transferable {
    enum Granularity: String, Codable { case day, month }
    let anchorDate: Date
    let granularity: Granularity

    var rangeStart: Date { anchorDate }
    var rangeEnd: Date {
        switch granularity {
        case .day: return anchorDate
        case .month:
            return Calendar.current.date(
                byAdding: DateComponents(month: 1, day: -1), to: anchorDate
            ) ?? anchorDate
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}

// MARK: - Calendar extension

private extension Calendar {
    func generateDates(inside interval: DateInterval, matching components: DateComponents) -> [Date] {
        var dates: [Date] = []
        dates.append(interval.start)
        enumerateDates(startingAfter: interval.start, matching: components, matchingPolicy: .nextTime) { date, _, stop in
            if let date {
                if date < interval.end { dates.append(date) } else { stop = true }
            }
        }
        return dates
    }
}

// MARK: - CalendarPickerView

struct CalendarPickerView: View {
    @Environment(LibraryStore.self) private var store

    @State private var months: [Date] = []
    @State private var daysPerMonth: [Date: [Date]] = [:]
    @State private var rangeAnchor: Date? = nil
    @State private var selectedYear: Int? = nil
    @State private var drillDownMonth: Date? = nil

    private let compact = true
    private var cellSpacing: CGFloat { compact ? 1 : 3 }
    private var maxCount: Int { store.photosPerDay.values.max() ?? 1 }

    private static let monthHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f
    }()

    // MARK: - Body

    var body: some View {
        @Bindable var store = store
        VStack(spacing: compact ? 4 : 8) {
            DateModeToggle(filter: $store.filter)
                .frame(maxWidth: .infinity)

            if store.filter.dateMode == .range {
                RangeDropZone(filter: $store.filter, compact: compact)
            }

            if months.isEmpty {
                Text("No photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 8 : 16)
            } else if months.count > store.settings.calendarMaxMonths {
                if let drillMonth = drillDownMonth {
                    singleMonthView(for: drillMonth)
                } else {
                    YearMonthPickerView(
                        photosPerDay: store.photosPerDay,
                        filter: $store.filter,
                        selectedYear: $selectedYear,
                        compact: compact,
                        onDrillDown: { drillDownMonth = $0 }
                    )
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: cellSpacing), count: 7),
                        spacing: cellSpacing,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(months, id: \.self) { month in
                            Section(header: monthHeader(for: month)) {
                                ForEach(daysPerMonth[month, default: []], id: \.self) { date in
                                    let isInMonth = Calendar.current.isDate(date, equalTo: month, toGranularity: .month)
                                    if isInMonth {
                                        let dayNum = Calendar.current.component(.day, from: date)
                                        let dayDate = Calendar.current.startOfDay(for: date)
                                        let cnt = store.photosPerDay[dayDate] ?? 0
                                        CalendarDayCell(
                                            day: dayNum,
                                            count: cnt,
                                            maxCount: maxCount,
                                            selectionState: selectionState(for: dayDate, filter: store.filter),
                                            compact: compact
                                        )
                                        .modifier(DayInteractionModifier(
                                            enabled: cnt > 0,
                                            dragPayload: DragDate(anchorDate: dayDate, granularity: .day),
                                            onTap: { handleTap(dayDate) }
                                        ))
                                    } else {
                                        Color.clear
                                            .frame(width: compact ? 26 : 40, height: compact ? 26 : 50)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { buildCalendar() }
        .onChange(of: store.datasetInterval) { buildCalendar() }
        .onChange(of: store.photosPerDay.count) { buildCalendar() }
    }

    // MARK: - Month header

    @ViewBuilder
    private func monthHeader(for month: Date) -> some View {
        VStack(spacing: 2) {
            Text(Self.monthHeaderFormatter.string(from: month))
                .font(compact ? .system(size: 9, weight: .semibold) : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, compact ? 4 : 8)

            // 曜日ヘッダー
            let weekdays = orderedWeekdaySymbols()
            HStack(spacing: cellSpacing) {
                ForEach(weekdays, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: compact ? 8 : 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(compact ? .clear : Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Selection

    private func selectionState(for dayDate: Date, filter: FilterCriteria) -> CalendarDayCell.SelectionState {
        let isoFmt = FilterCriteria.isoDateFormatter
        switch filter.dateMode {
        case .range:
            let minDate = filter.dateMin.isEmpty ? nil : isoFmt.date(from: filter.dateMin)
            let maxDate = filter.dateMax.isEmpty ? nil : isoFmt.date(from: filter.dateMax)
            if let minDate, let maxDate {
                if dayDate == minDate { return .rangeStart }
                if dayDate == maxDate { return .rangeEnd }
                if dayDate > minDate && dayDate < maxDate { return .rangeMiddle }
            } else if let minDate, maxDate == nil {
                if dayDate == minDate { return .rangeStart }
                // rangeAnchor がセットされていれば当日のみ選択中として扱う
            }
            return .none
        case .multi:
            let iso = isoFmt.string(from: dayDate)
            return filter.dateAllowList.contains(iso) ? .multiSelected : .none
        }
    }

    // MARK: - Tap handling

    private func handleTap(_ dayDate: Date) {
        let isoFmt = FilterCriteria.isoDateFormatter
        var f = store.filter
        switch f.dateMode {
        case .range:
            let isoDay = isoFmt.string(from: dayDate)
            if let anchor = rangeAnchor {
                if dayDate == anchor {
                    f.dateMin = ""; f.dateMax = ""
                    rangeAnchor = nil
                } else if dayDate > anchor {
                    f.dateMax = isoDay
                    rangeAnchor = nil
                } else {
                    // anchor より前の日付は新しい開始日として設定し直す
                    f.dateMin = isoDay; f.dateMax = ""
                    rangeAnchor = dayDate
                }
            } else {
                f.dateMin = isoDay; f.dateMax = ""
                rangeAnchor = dayDate
            }
        case .multi:
            let iso = isoFmt.string(from: dayDate)
            if f.dateAllowList.contains(iso) {
                f.dateAllowList.remove(iso)
            } else {
                f.dateAllowList.insert(iso)
            }
        }
        store.filter = f   // 一回の代入で didSet を 1 回だけ発火
    }

    // MARK: - Calendar math

    private func buildCalendar() {
        guard let interval = store.datasetInterval else {
            months = []
            daysPerMonth = [:]
            return
        }
        let cal = Calendar.current
        // データセット全体（フィルタ非依存の datasetInterval）の全月を描画する。
        // 他フィルタで件数 0 になった月も消さず、0 件セル（淡色）として残すことで、
        // カレンダーの月数＝描画高さが変わらず、下のフィルタの描画位置がズレない。
        let allMonthStarts = cal.generateDates(
            inside: DateInterval(start: cal.startOfDay(for: interval.start),
                                 end: interval.end.addingTimeInterval(1)),
            matching: DateComponents(day: 1, hour: 0, minute: 0, second: 0)
        )
        // 月ごとの日付グリッド（週境界で padding）
        var result: [Date: [Date]] = [:]
        var allMonths: [Date] = []
        for month in allMonthStarts {
            guard let monthInterval = cal.dateInterval(of: .month, for: month),
                  let firstWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.start),
                  let lastWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.end)
            else { continue }
            result[month] = cal.generateDates(
                inside: DateInterval(start: firstWeek.start, end: lastWeek.end),
                matching: DateComponents(hour: 0, minute: 0, second: 0)
            )
            allMonths.append(month)
        }
        months = allMonths
        daysPerMonth = result
    }

    private func orderedWeekdaySymbols() -> [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    // MARK: - Drill-down single month view

    @ViewBuilder
    private func singleMonthView(for month: Date) -> some View {
        let cal = Calendar.current
        let days = daysForDrillDown(month: month)
        VStack(spacing: compact ? 4 : 6) {
            Button { drillDownMonth = nil } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text(Self.monthHeaderFormatter.string(from: month))
                }
                .font(compact ? .system(size: 9, weight: .semibold) : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)

            let weekdays = orderedWeekdaySymbols()
            HStack(spacing: cellSpacing) {
                ForEach(weekdays, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: compact ? 8 : 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: cellSpacing), count: 7),
                spacing: cellSpacing
            ) {
                ForEach(days, id: \.self) { date in
                    let isInMonth = cal.isDate(date, equalTo: month, toGranularity: .month)
                    if isInMonth {
                        let dayNum = cal.component(.day, from: date)
                        let dayDate = cal.startOfDay(for: date)
                        let cnt = store.photosPerDay[dayDate] ?? 0
                        CalendarDayCell(
                            day: dayNum, count: cnt, maxCount: maxCount,
                            selectionState: selectionState(for: dayDate, filter: store.filter),
                            compact: compact
                        )
                        .modifier(DayInteractionModifier(
                            enabled: cnt > 0,
                            dragPayload: DragDate(anchorDate: dayDate, granularity: .day),
                            onTap: { handleTap(dayDate) }
                        ))
                    } else {
                        Color.clear
                            .frame(width: compact ? 26 : 40, height: compact ? 26 : 50)
                    }
                }
            }
        }
    }

    private func daysForDrillDown(month: Date) -> [Date] {
        // Try cache first; generate on-the-fly if not present
        if let cached = daysPerMonth[month] { return cached }
        let cal = Calendar.current
        guard let monthInterval = cal.dateInterval(of: .month, for: month),
              let firstWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.start),
              let lastWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.end)
        else { return [] }
        return cal.generateDates(
            inside: DateInterval(start: firstWeek.start, end: lastWeek.end),
            matching: DateComponents(hour: 0, minute: 0, second: 0)
        )
    }
}

// MARK: - YearMonthPickerView

private struct YearMonthPickerView: View {
    let photosPerDay: [Date: Int]
    @Binding var filter: FilterCriteria
    @Binding var selectedYear: Int?
    let compact: Bool
    var onDrillDown: ((Date) -> Void)? = nil

    private static let monthAbbrevFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private var cal: Calendar { .current }

    private var availableYears: [Int] {
        let years = Set(photosPerDay.keys.map { cal.component(.year, from: $0) })
        return years.sorted()
    }

    private var displayYear: Int {
        selectedYear ?? availableYears.last ?? cal.component(.year, from: Date())
    }

    private func countForMonth(year: Int, month: Int) -> Int {
        photosPerDay.reduce(0) { acc, kv in
            let c = cal.dateComponents([.year, .month], from: kv.key)
            return (c.year == year && c.month == month) ? acc + kv.value : acc
        }
    }

    private func selectionState(year: Int, month: Int) -> MonthCell.SelectionState {
        let isoFmt = FilterCriteria.isoDateFormatter
        guard filter.dateMode == .range, !filter.dateMin.isEmpty else { return .none }
        guard let minDate = isoFmt.date(from: filter.dateMin) else { return .none }
        let minC = cal.dateComponents([.year, .month], from: minDate)
        let minKey = (minC.year ?? 0) * 100 + (minC.month ?? 0)
        let cellKey = year * 100 + month

        if filter.dateMax.isEmpty {
            return cellKey == minKey ? .rangeStart : .none
        }
        guard let maxDate = isoFmt.date(from: filter.dateMax) else { return .none }
        let maxC = cal.dateComponents([.year, .month], from: maxDate)
        let maxKey = (maxC.year ?? 0) * 100 + (maxC.month ?? 0)

        if cellKey == minKey { return .rangeStart }
        if cellKey == maxKey { return .rangeEnd }
        if cellKey > minKey && cellKey < maxKey { return .rangeMiddle }
        return .none
    }

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            yearSelector
            monthGrid
        }
    }

    @ViewBuilder
    private var yearSelector: some View {
        HStack(spacing: 4) {
            Button {
                if let idx = availableYears.firstIndex(of: displayYear), idx > 0 {
                    selectedYear = availableYears[idx - 1]
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(displayYear == availableYears.first)

            Menu(String(displayYear)) {
                ForEach(availableYears.reversed(), id: \.self) { y in
                    Button(String(y)) { selectedYear = y }
                }
            }
            .controlSize(.small)

            Button {
                if let idx = availableYears.firstIndex(of: displayYear), idx < availableYears.count - 1 {
                    selectedYear = availableYears[idx + 1]
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: compact ? 9 : 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(displayYear == availableYears.last)
        }
        .frame(maxWidth: .infinity)
    }

    private var monthGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 2 : 4), count: 4),
            spacing: compact ? 2 : 4
        ) {
            ForEach(1...12, id: \.self) { month in
                let cnt = countForMonth(year: displayYear, month: month)
                let anchor = cal.date(from: DateComponents(year: displayYear, month: month, day: 1)) ?? Date.distantPast
                MonthCell(
                    month: month,
                    year: displayYear,
                    count: cnt,
                    selectionState: selectionState(year: displayYear, month: month),
                    compact: compact,
                    formatter: Self.monthAbbrevFormatter
                )
                .contentShape(Rectangle())
                .draggable(DragDate(anchorDate: anchor, granularity: .month))
                .onTapGesture { onDrillDown?(anchor) }
            }
        }
    }
}

// MARK: - MonthCell

private struct MonthCell: View {
    enum SelectionState { case none, rangeStart, rangeEnd, rangeMiddle }

    let month: Int
    let year: Int
    let count: Int
    let selectionState: SelectionState
    let compact: Bool
    let formatter: DateFormatter

    private var cellHeight: CGFloat { compact ? 28 : 38 }
    private var isHighlighted: Bool { selectionState == .rangeStart || selectionState == .rangeEnd }

    private var monthName: String {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let d = Calendar.current.date(from: c) else { return "" }
        return formatter.string(from: d)
    }

    private var cellBackgroundColor: Color {
        switch selectionState {
        case .none:       return count == 0 ? Color.clear : Color.secondary.opacity(0.08)
        case .rangeStart, .rangeEnd: return Color.accentColor
        case .rangeMiddle: return Color.accentColor.opacity(0.25)
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(monthName)
                .font(.system(size: compact ? 10 : 12,
                              weight: isHighlighted ? .semibold : .regular))
            if count > 0 {
                Text(count >= 1000 ? "\(count / 1000)k" : "\(count)")
                    .font(.system(size: compact ? 7 : 9))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
        .foregroundStyle(
            count == 0
                ? Color.secondary.opacity(0.4)
                : (isHighlighted ? Color.white : Color.primary)
        )
        .background(cellBackgroundColor, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - RangeDropZone

private struct RangeDropZone: View {
    @Binding var filter: FilterCriteria
    let compact: Bool

    private static let displayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var isoFmt: DateFormatter { FilterCriteria.isoDateFormatter }

    private func applyDrop(_ drag: DragDate, to slot: DropSlot.Slot) {
        let date = slot == .from ? drag.rangeStart : drag.rangeEnd
        let str = isoFmt.string(from: date)
        var f = filter
        if slot == .from {
            f.dateMin = str
            // 新しい開始日が終了日以降なら終了日をクリア
            if let max = isoFmt.date(from: f.dateMax), date >= max {
                f.dateMax = ""
            }
        } else {
            // 終了日は開始日より後の日付のみ受け付ける
            if !f.dateMin.isEmpty, let min = isoFmt.date(from: f.dateMin), date <= min {
                return
            }
            f.dateMax = str
        }
        filter = f
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            DropSlot(
                value: filter.dateMin.isEmpty ? nil : filter.dateMin,
                slot: .from, compact: compact,
                onDrop: { applyDrop($0, to: .from) }
            )
            Text("〜")
                .font(.system(size: compact ? 9 : 11))
                .foregroundStyle(.secondary)
            DropSlot(
                value: filter.dateMax.isEmpty ? nil : filter.dateMax,
                slot: .to, compact: compact,
                onDrop: { applyDrop($0, to: .to) }
            )
            if !filter.dateMin.isEmpty || !filter.dateMax.isEmpty {
                Button {
                    var f = filter; f.dateMin = ""; f.dateMax = ""
                    filter = f
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: compact ? 10 : 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - DropSlot

private struct DropSlot: View {
    enum Slot { case from, to }

    let value: String?
    let slot: Slot
    let compact: Bool
    let onDrop: (DragDate) -> Void

    @State private var isTargeted = false

    private var placeholder: String {
        slot == .from
            ? String(localized: "range.drop.from", defaultValue: "From")
            : String(localized: "range.drop.to",   defaultValue: "To")
    }

    private var displayText: String {
        guard let value else { return placeholder }
        if slot == .from {
            let parts = value.split(separator: "-")
            if parts.count == 3 {
                return "\(parts[0])\n\(parts[1])-\(parts[2])"
            }
        }
        return value
    }

    var body: some View {
        Text(displayText)
            .multilineTextAlignment(.center)
            .font(.system(size: compact ? 9 : 11, weight: value != nil ? .medium : .regular))
            .foregroundStyle(value != nil ? Color.primary : Color.secondary)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .frame(minWidth: compact ? 64 : 84)
            .background(
                isTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [3, 2])
                    )
            )
            .dropDestination(for: DragDate.self) { items, _ in
                guard let item = items.first else { return false }
                onDrop(item)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

// MARK: - DayInteractionModifier

private struct DayInteractionModifier: ViewModifier {
    let enabled: Bool
    let dragPayload: DragDate
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(dragPayload)
                .contentShape(Rectangle())
                .onTapGesture { onTap() }
        } else {
            content
        }
    }
}

