import SwiftUI

struct AboutView: View {
    private static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private static let copyright: String = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("BridgeLite")
                .font(.title2.bold())
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("about.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(Self.copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(width: 390)
        .fixedSize(horizontal: true, vertical: true)
    }
}
