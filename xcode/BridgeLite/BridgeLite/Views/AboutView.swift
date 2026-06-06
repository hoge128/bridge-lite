import SwiftUI

struct AboutView: View {
    private static let version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    private static let copyright: String = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    private static let githubURL = URL(string: "https://github.com/hoge128/bridge-lite")!
    private static let privacyURL = URL(string: "https://hoge128.github.io/bridge-lite/privacy-policy")!

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
            #if APPSTORE
            Text("about.edition.appstore")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            #else
            Text("about.edition.direct")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            #endif
            Text("about.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("GitHub", destination: Self.githubURL)
                Link(String(localized: "settings.privacy_policy", defaultValue: "Privacy Policy"),
                     destination: Self.privacyURL)
            }
            .font(.caption)
            Divider()
            Text(Self.copyright)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if !APPSTORE
            // Sparkle is only bundled in the Direct (DMG) build.
            Text(verbatim: "Sparkle 2.9.1 — © 2006–2022 Andy Matuschak,\nElgato Systems GmbH, Kornel Lesiński, Mayur Pawashe\nand contributors. MIT License.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(width: 390)
        .fixedSize(horizontal: true, vertical: true)
    }
}
