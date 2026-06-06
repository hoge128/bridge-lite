import Foundation

@MainActor
@Observable
final class RecentFoldersStore {
    static let shared = RecentFoldersStore()

    private static let maxCount = 5

    /// Resolved folder URLs for display and for opening. In the sandboxed
    /// (Mac App Store) build these are security-scoped URLs resolved from
    /// bookmarks; `startAccessingSecurityScopedResource()` is called later, when
    /// the folder is actually opened (see LibraryStore.beginScopedAccess).
    private(set) var recentURLs: [URL] = []

    #if APPSTORE
    // Sandboxed build: persist security-scoped bookmarks so a recent folder can
    // be reopened across launches (a plain path grants no access under sandbox).
    private static let defaultsKey = "recentFolderBookmarks"
    private var bookmarks: [Data] = []
    #else
    // Direct (DMG) build: not sandboxed, plain paths are sufficient (unchanged).
    private static let defaultsKey = "recentFolderURLs"
    #endif

    private init() { load() }

    func record(_ url: URL) {
        #if APPSTORE
        // The folder is open and holds access here, so bookmark creation succeeds.
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        // Drop any existing entry for the same path, keeping URL/bookmark in sync.
        var newURLs: [URL] = []
        var newBookmarks: [Data] = []
        for (u, b) in zip(recentURLs, bookmarks) where u.path != url.path {
            newURLs.append(u)
            newBookmarks.append(b)
        }
        newURLs.insert(url, at: 0)
        newBookmarks.insert(data, at: 0)
        recentURLs = Array(newURLs.prefix(Self.maxCount))
        bookmarks = Array(newBookmarks.prefix(Self.maxCount))
        UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
        #else
        var urls = recentURLs.filter { $0.path != url.path }
        urls.insert(url, at: 0)
        recentURLs = Array(urls.prefix(Self.maxCount))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: Self.defaultsKey)
        #endif
    }

    func clear() {
        recentURLs = []
        #if APPSTORE
        bookmarks = []
        #endif
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    private func load() {
        #if APPSTORE
        let stored = (UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Data]) ?? []
        var urls: [URL] = []
        var valid: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            // Note: don't checkResourceIsReachable() here — without active scoped
            // access that would wrongly drop valid entries under the sandbox.
            urls.append(url)
            valid.append(data)
        }
        recentURLs = urls
        bookmarks = valid
        // Persist the pruned list if any bookmark failed to resolve.
        if valid.count != stored.count {
            UserDefaults.standard.set(valid, forKey: Self.defaultsKey)
        }
        #else
        let paths = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        recentURLs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { (try? $0.checkResourceIsReachable()) == true }
        #endif
    }
}
