import SwiftUI

@Observable @MainActor
final class TabManager {
    struct Tab: Identifiable {
        let id = UUID()
        let store: LibraryStore
    }

    private(set) var tabs: [Tab]
    private(set) var activeIndex: Int = 0

    init() {
        tabs = [Tab(store: LibraryStore())]
    }

    var activeStore: LibraryStore { tabs[activeIndex].store }
    var activeTab: Tab { tabs[activeIndex] }

    // Open URL in the active tab if empty, otherwise in a new tab.
    func openInBestTab(url: URL) {
        if activeStore.currentDirectoryURL == nil {
            Task { await activeStore.openDirectory(url) }
        } else {
            addTab()
            Task { await activeStore.openDirectory(url) }
        }
    }

    func addTab() {
        tabs[activeIndex].store.suspend()
        tabs.append(Tab(store: LibraryStore()))
        activeIndex = tabs.count - 1
    }

    func switchTo(index: Int) {
        guard index != activeIndex, tabs.indices.contains(index) else { return }
        tabs[activeIndex].store.suspend()
        activeIndex = index
        tabs[activeIndex].store.resume()
    }

    func close(index: Int) {
        guard tabs.count > 1 else { return }
        let wasActive = index == activeIndex
        tabs[index].store.suspend()
        tabs.remove(at: index)
        if wasActive {
            activeIndex = min(index, tabs.count - 1)
            tabs[activeIndex].store.resume()
        } else if index < activeIndex {
            activeIndex -= 1
        }
    }
}
