import SwiftUI

struct AboutView: View {
    private static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private static let copyright: String = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    private static let githubURL = URL(string: "https://github.com/hoge128/bridge-lite")!

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
            Link("GitHub", destination: Self.githubURL)
                .font(.caption)
            Divider()
            Text(Self.copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "Sparkle 2.9.1 — © 2006–2022 Andy Matuschak,\nElgato Systems GmbH, Kornel Lesiński, Mayur Pawashe\nand contributors. MIT License.")
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
