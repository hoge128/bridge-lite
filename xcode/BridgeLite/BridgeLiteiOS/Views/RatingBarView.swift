import SwiftUI

struct RatingBarView: View {
    let entry: PhotoEntry
    @Binding var xmp: XmpData
    let onCommit: (XmpData) -> Void

    var body: some View {
        VStack(spacing: 10) {
            // 星レーティング
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        let newRating = xmp.rating == star ? 0 : star
                        xmp.rating = newRating == 0 ? nil : newRating
                        onCommit(xmp)
                    } label: {
                        Image(systemName: star <= (xmp.rating ?? 0) ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(star <= (xmp.rating ?? 0) ? Color.yellow : Color.white.opacity(0.7))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .adaptiveGlass(cornerRadius: 20)

            // カラーラベル
            HStack(spacing: 10) {
                labelButton(nil, color: Color(.systemGray4), name: String(localized: "filter.none", defaultValue: "None"))
                ForEach(XmpLabel.allCases, id: \.self) { label in
                    labelButton(label, color: label.color, name: label.name)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .adaptiveGlass(cornerRadius: 20)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func labelButton(_ label: XmpLabel?, color: Color, name: String) -> some View {
        let isSelected = xmp.label == label
        Button {
            xmp.label = isSelected ? nil : label
            onCommit(xmp)
        } label: {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 1 : 0), lineWidth: 2.5)
                )
                .shadow(color: isSelected ? color.opacity(0.6) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
    }
}
