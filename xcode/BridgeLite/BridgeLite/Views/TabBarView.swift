import SwiftUI

struct TabBarView: View {
    @Environment(TabManager.self) private var tabManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItemView(tab: tab, index: index, isActive: index == tabManager.activeIndex)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }

            Divider().frame(height: 14).padding(.horizontal, 4)

            Button {
                tabManager.addTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .help("New Tab (⌘T)")
        }
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TabItemView: View {
    let tab: TabManager.Tab
    let index: Int
    let isActive: Bool
    @Environment(TabManager.self) private var tabManager
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? .primary : .tertiary)

            Text(tab.store.currentDirectoryURL?.lastPathComponent ?? "New Tab")
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: 150, alignment: .leading)

            Button {
                tabManager.close(index: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .opacity((isHovered || isActive) && tabManager.tabs.count > 1 ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive
                      ? Color.accentColor.opacity(0.15)
                      : isHovered ? Color.secondary.opacity(0.08) : .clear)
        }
        .onTapGesture { tabManager.switchTo(index: index) }
        .onHover { isHovered = $0 }
    }
}
