import SwiftUI

struct DateModeToggle: View {
    @Binding var filter: FilterCriteria

    var body: some View {
        Picker("", selection: Binding<DateMode>(
            get: { filter.dateMode },
            set: { newMode in
                var f = filter
                if newMode == .range {
                    f.dateAllowList = []
                } else {
                    f.dateMin = ""
                    f.dateMax = ""
                }
                f.dateMode = newMode
                filter = f
            }
        )) {
            Text("Range").tag(DateMode.range)
            Text("Multi").tag(DateMode.multi)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
    }
}
