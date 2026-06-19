import SwiftUI
import AppKit

struct OpenWithMenu: View {
    let targetURLs: [URL]
    let primaryURL: URL

    private var settings: SettingsStore { SettingsStore.shared }

    var body: some View {
        Menu(String(localized: "Open With")) {
            let defaultApp = OpenWithService.defaultApplicationURL(for: primaryURL)

            if let defaultApp {
                appButton(defaultApp, isDefault: true)
                Divider()
            }

            let favorites = settings.favoriteApps
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .filter { $0 != defaultApp }

            ForEach(favorites, id: \.path) { app in
                appButton(app, isDefault: false)
            }

            if !favorites.isEmpty { Divider() }

            Button(String(localized: "Add Application…")) {
                if let app = OpenWithService.presentAddApplicationPanel(),
                   !settings.favoriteApps.contains(app) {
                    settings.favoriteApps.append(app)
                }
            }

            Button(String(localized: "Manage Applications…")) {
                NotificationCenter.default.post(
                    name: .bridgeLiteOpenManageApplications, object: nil)
            }
        }
    }

    @ViewBuilder
    private func appButton(_ appURL: URL, isDefault: Bool) -> some View {
        let name = OpenWithService.applicationName(at: appURL)
        let displayText = isDefault
            ? String(format: String(localized: "%@ (Default)"), name)
            : name
        Button {
            OpenWithService.open(targetURLs, with: appURL)
        } label: {
            Label {
                Text(displayText)
            } icon: {
                Image(nsImage: OpenWithService.applicationIcon(at: appURL))
            }
        }
    }
}

extension Notification.Name {
    static let bridgeLiteOpenManageApplications =
        Notification.Name("bridgeLiteOpenManageApplications")
}
