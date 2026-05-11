import SwiftUI

struct CalendarDayCell: View {
    enum SelectionState: Equatable {
        case none
        case rangeStart
        case rangeEnd
        case rangeMiddle
        case multiSelected
    }

    let day: Int                    // 1-31
    let count: Int
    let maxCount: Int
    let selectionState: SelectionState
    let compact: Bool

    private var cellSize: CGFloat { compact ? 26 : 40 }

    private var bubbleDiameter: CGFloat {
        guard maxCount > 0, count > 0 else { return 0 }
        let ratio = sqrt(Double(count) / Double(maxCount))
        let base: CGFloat = compact ? 10 : 14
        let extra: CGFloat = compact ? 12 : 20
        return base + extra * ratio
    }

    private var isSelected: Bool {
        selectionState == .rangeStart || selectionState == .rangeEnd || selectionState == .multiSelected
    }

    var body: some View {
        ZStack {
            // Range 中間帯（セル幅いっぱい）
            if selectionState == .rangeMiddle {
                Color.accentColor.opacity(0.15)
                    .frame(height: cellSize)
            }
            // 写真数バブル
            if count > 0 {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
                    .frame(width: bubbleDiameter, height: bubbleDiameter)
            }
            // 選択円
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: cellSize * 0.82, height: cellSize * 0.82)
            }
            // 日付・枚数テキスト
            VStack(spacing: 0) {
                Text("\(day)")
                    .font(.system(size: compact ? 9 : 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : (count > 0 ? Color.primary : Color.secondary.opacity(0.4)))
                if !compact, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 7))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
        }
        .frame(width: cellSize, height: compact ? cellSize : cellSize + 10)
    }
}
