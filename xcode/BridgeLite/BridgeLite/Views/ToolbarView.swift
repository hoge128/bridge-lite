import SwiftUI

// MARK: - Liquid Glass style view mode picker
// [BETA DISABLED] デイリーモードはスキャン中のフリーズが未解決のため非表示。
// 再有効化する場合は ToolbarView.principal ブロックに ViewModePicker を戻す。

private struct ViewModePicker: View {
    @Binding var selection: ViewMode

    var body: some View {
        HStack(spacing: 2) {
            pill("すべての写真", mode: .all)
            pill("デイリー",     mode: .daily)
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
            .help(store.performUndoTitle ?? "Undo (⌘Z)")

            if !store.viewerMode && !store.compareMode {
                Menu {
                    Picker("", selection: $settings.sortKey) {
                        Text("ファイル名 別").tag(SortKey.filename)
                        Text("撮影日時 別").tag(SortKey.exifDate)
                        Text("作成日 別").tag(SortKey.createdDate)
                        Text("修正日 別").tag(SortKey.modifiedDate)
                        Text("サイズ 別").tag(SortKey.fileSize)
                        Text("レーティング 別").tag(SortKey.rating)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(settings.sortKey.localizedName) で並べ替え")
                }
                .onChange(of: settings.sortKey) { store.applyOrder() }

                Button(action: { settings.sortAscending.toggle() }) {
                    Image(systemName: settings.sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(settings.sortAscending ? "昇順" : "降順")
                .onChange(of: settings.sortAscending) { store.applyOrder() }

                Toggle(isOn: $store.showSidebar) {
                    Label("Metadata", systemImage: "sidebar.right")
                }
            }
        }
    }
}
