import SwiftUI

struct FilterSheetView: View {
    @Binding var minRating: Int?
    @Binding var filterLabel: XmpLabel?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("最低レーティング") {
                    HStack(spacing: 4) {
                        Button("なし") {
                            minRating = nil
                        }
                        .buttonStyle(.bordered)
                        .tint(minRating == nil ? .accentColor : .secondary)

                        ForEach(1...5, id: \.self) { star in
                            Button(String(repeating: "★", count: star)) {
                                minRating = minRating == star ? nil : star
                            }
                            .buttonStyle(.bordered)
                            .tint(minRating == star ? .accentColor : .secondary)
                            .font(.caption)
                        }
                    }
                }

                Section("ラベル") {
                    HStack(spacing: 12) {
                        labelPill(nil, name: "なし")
                        ForEach(XmpLabel.allCases, id: \.self) { label in
                            labelPill(label, name: label.name)
                        }
                    }
                }
            }
            .navigationTitle("フィルター")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { onDismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("クリア") {
                        minRating = nil
                        filterLabel = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func labelPill(_ label: XmpLabel?, name: String) -> some View {
        let isSelected = filterLabel == label
        Button(name) {
            filterLabel = isSelected ? nil : label
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? (label?.color ?? .accentColor) : .secondary)
    }
}
