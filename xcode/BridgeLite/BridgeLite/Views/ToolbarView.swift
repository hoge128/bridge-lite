import SwiftUI

// MARK: - Liquid Glass style view mode picker
// [BETA DISABLED] デイリーモードはスキャン中のフリーズが未解決のため非表示。
// 再有効化する場合は ToolbarView.principal ブロックに ViewModePicker を戻す。

private struct ViewModePicker: View {
    @Binding var selection: ViewMode

    var body: some View {
        HStack(spacing: 2) {
            pill(String(localized: "All Photos"), mode: .all)
            pill(String(localized: "Daily"), mode: .daily)
        }
        .padding(3)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.10)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
        .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
    }

    private func pill(_ label: String, mode: ViewMode) -> some View {
        let isSelected = selection == mode
        return Text(label)
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [.white.opacity(0.70), .white.opacity(0.20)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
            }
    }
}

// MARK: -

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        @Bindable var settings = store.settings

        if !store.viewerMode && !store.compareMode {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { store.requestOpenFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
            }
        }

        ToolbarItemGroup(placement: .principal) {
            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                Button(action: { store.cancelLoading() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text(String(localized: "Cancel scanning"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let msg = store.undoMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { store.performUndo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .help(store.performUndoTitle ?? String(localized: "Undo (⌘Z)"))

            if !store.viewerMode && !store.compareMode {
                Menu {
                    Picker("", selection: $settings.sortKey) {
                        Text(SortKey.filename.localizedName).tag(SortKey.filename)
                        Text(SortKey.exifDate.localizedName).tag(SortKey.exifDate)
                        Text(SortKey.createdDate.localizedName).tag(SortKey.createdDate)
                        Text(SortKey.modifiedDate.localizedName).tag(SortKey.modifiedDate)
                        Text(SortKey.fileSize.localizedName).tag(SortKey.fileSize)
                        Text(SortKey.rating.localizedName).tag(SortKey.rating)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(String(localized: "Sort by \(settings.sortKey.localizedName)"))
                }
                .onChange(of: settings.sortKey) { store.applyOrder() }

                Button(action: { settings.sortAscending.toggle() }) {
                    Image(systemName: settings.sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(settings.sortAscending
                      ? String(localized: "Ascending")
                      : String(localized: "Descending"))
                .onChange(of: settings.sortAscending) { store.applyOrder() }

                Toggle(isOn: $store.showSidebar) {
                    Label("Metadata", systemImage: "sidebar.right")
                }
            }
        }
    }
}
