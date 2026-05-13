import SwiftUI

struct RatingBarView: View {
    let entry: PhotoEntry
    @Binding var xmp: XmpData
    let onCommit: (XmpData) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= (xmp.rating ?? 0) ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= (xmp.rating ?? 0) ? .yellow : .secondary)
                        .onTapGesture {
                            let newRating = xmp.rating == star ? 0 : star
                            xmp.rating = newRating == 0 ? nil : newRating
                            onCommit(xmp)
                        }
                }
            }

            HStack(spacing: 8) {
                labelButton(nil, label: "なし")
                ForEach(XmpLabel.allCases, id: \.self) { label in
                    labelButton(label, label: label.name)
                }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func labelButton(_ label: XmpLabel?, label name: String) -> some View {
        let isSelected = xmp.label == label
        Button {
            xmp.label = isSelected ? nil : label
            onCommit(xmp)
        } label: {
            if let label {
                Circle()
                    .fill(label.color)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? .primary : .clear, lineWidth: 2)
                    )
            } else {
                Circle()
                    .fill(Color(.systemGray4))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .stroke(isSelected ? .primary : .clear, lineWidth: 2)
                    )
            }
        }
        .buttonStyle(.plain)
    }
}
