import SwiftUI

struct FilterSheetView: View {
    @Binding var minRating: Int?
    @Binding var filterLabel: XmpLabel?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ratingSection
                    labelSection
                }
                .padding()
            }
            .glassNavigationBar()
            .navigationTitle(String(localized: "filter.title", defaultValue: "Filter"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { onDismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "filter.clear", defaultValue: "Clear")) {
                        minRating = nil
                        filterLabel = nil
                    }
                }
            }
        }
    }

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "filter.min_rating", defaultValue: "Minimum Rating"))
                .font(.headline)
            HStack(spacing: 6) {
                Button(String(localized: "filter.none", defaultValue: "None")) { minRating = nil }
                    .buttonStyle(.adaptiveGlass(isActive: minRating == nil))
                ForEach(1...5, id: \.self) { star in
                    Button(String(repeating: "★", count: star)) {
                        minRating = minRating == star ? nil : star
                    }
                    .buttonStyle(.adaptiveGlass(isActive: minRating == star))
                    .font(.caption)
                }
            }
        }
        .padding()
        .adaptiveGlass(cornerRadius: 16)
    }

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "filter.label", defaultValue: "Label"))
                .font(.headline)
            HStack(spacing: 14) {
                labelCircle(nil, name: String(localized: "filter.none", defaultValue: "None"))
                ForEach(XmpLabel.allCases, id: \.self) { label in
                    labelCircle(label, name: label.name)
                }
            }
        }
        .padding()
        .adaptiveGlass(cornerRadius: 16)
    }

    @ViewBuilder
    private func labelCircle(_ label: XmpLabel?, name: String) -> some View {
        let isSelected = filterLabel == label
        Button {
            filterLabel = isSelected ? nil : label
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(label?.color ?? Color(.systemGray4))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
