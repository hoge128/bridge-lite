import Foundation

@MainActor
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore()

    private static let maxCount = 5
    private static let defaultsKey = "recentFolderURLs"

    private(set) var recentURLs: [URL] = []

    private init() { load() }

    func record(_ url: URL) {
        var urls = recentURLs.filter { $0.path != url.path }
        urls.insert(url, at: 0)
        recentURLs = Array(urls.prefix(Self.maxCount))
        save()
    }

    func clear() {
        recentURLs = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        recentURLs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { (try? $0.checkResourceIsReachable()) == true }
    }

    private func save() {
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: Self.defaultsKey)
    }
}
