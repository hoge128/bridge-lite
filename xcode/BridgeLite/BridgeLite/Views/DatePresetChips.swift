import SwiftUI

struct DatePresetChips: View {
    @Binding var filter: FilterCriteria
    let datasetEnd: Date?
    let compact: Bool

    private enum Preset: CaseIterable {
        case all, last24h, last7d, last30d, last90d, last1y

        var label: LocalizedStringKey {
            switch self {
            case .all:     return "All"
            case .last24h: return "Last 24h"
            case .last7d:  return "Last 7 days"
            case .last30d: return "Last 30 days"
            case .last90d: return "Last 90 days"
            case .last1y:  return "Last year"
            }
        }

        // compact ラベル（サイドバー用）
        var shortLabel: LocalizedStringKey {
            switch self {
            case .all:     return "All"
            case .last24h: return "24h"
            case .last7d:  return "7d"
            case .last30d: return "30d"
            case .last90d: return "90d"
            case .last1y:  return "1y"
            }
        }

        var days: Int? {
            switch self {
            case .all:     return nil
            case .last24h: return 1
            case .last7d:  return 7
            case .last30d: return 30
            case .last90d: return 90
            case .last1y:  return 365
            }
        }
    }

    var body: some View {
        let isoFmt = FilterCriteria.isoDateFormatter
        HStack(spacing: compact ? 3 : 5) {
            ForEach(Preset.allCases, id: \.self) { preset in
                Button {
                    applyPreset(preset, isoFmt: isoFmt)
                } label: {
                    Text(compact ? preset.shortLabel : preset.label)
                        .font(compact ? .system(size: 9, weight: .medium) : .caption)
                        .padding(.horizontal, compact ? 5 : 7)
                        .padding(.vertical, compact ? 2 : 3)
                        .background(
                            isActive(preset, isoFmt: isoFmt)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(isActive(preset, isoFmt: isoFmt) ? Color.white : Color.primary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func applyPreset(_ preset: Preset, isoFmt: DateFormatter) {
        var f = filter
        f.dateMode = .range
        f.dateAllowList = []
        if let days = preset.days {
            let anchor = datasetEnd ?? Date()
            let from = Calendar.current.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor
            f.dateMin = isoFmt.string(from: from)
            f.dateMax = ""
        } else {
            f.dateMin = ""
            f.dateMax = ""
        }
        filter = f   // 一回の代入で didSet を 1 回だけ発火
    }

    private func isActive(_ preset: Preset, isoFmt: DateFormatter) -> Bool {
        guard filter.dateMode == .range else { return false }
        guard let days = preset.days else {
            return filter.dateMin.isEmpty && filter.dateMax.isEmpty
        }
        guard !filter.dateMin.isEmpty else { return false }
        let anchor = datasetEnd ?? Date()
        guard let expected = Calendar.current.date(byAdding: .day, value: -(days - 1), to: anchor) else { return false }
        return filter.dateMin == isoFmt.string(from: expected) && filter.dateMax.isEmpty
    }
}
