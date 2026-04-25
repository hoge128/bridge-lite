import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("B")
                .font(.system(size: 60, weight: .bold, design: .monospaced))
                .foregroundStyle(.accent)
            Text("BridgeLite")
                .font(.title2.bold())
            Text("Lightweight RAW+JPG image viewer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Version 0.1.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.escape)
        }
        .padding(32)
        .frame(width: 300, height: 250)
    }
}
