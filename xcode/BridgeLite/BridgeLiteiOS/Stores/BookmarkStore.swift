import Foundation

/// Security-Scoped Bookmark の永続化（iOS sandbox を跨ぐアクセス継続）
@MainActor
final class BookmarkStore {
    private static let key = "scanFolderBookmark"

    static func save(url: URL) {
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func restore() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if isStale {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return url
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
