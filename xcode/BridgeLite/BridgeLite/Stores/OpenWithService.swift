import AppKit
import UniformTypeIdentifiers

enum OpenWithService {
    @MainActor
    static func defaultApplicationURL(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    static func applicationName(at appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
    }

    static func applicationIcon(at appURL: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @MainActor
    static func open(_ urls: [URL], with appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
            if let error { print("OpenWith failed: \(error)") }
        }
    }

    @MainActor
    static func presentAddApplicationPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Application")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
