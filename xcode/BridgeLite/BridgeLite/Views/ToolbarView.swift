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

// MARK: - Native search field (NSSearchField wrapper)

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 最近の検索履歴ドロップダウンを無効化（矢印アイコンが消える）
        field.searchMenuTemplate = nil
        field.maximumRecents = 0
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.focusSearch),
            name: .bridgeLiteFocusSearch,
            object: nil
        )
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField

        init(_ parent: NativeSearchField) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        // cancelButton（✕）クリック時
        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            parent.text = ""
        }

        @objc func focusSearch(_ notification: Notification) {
            guard let window = NSApp.keyWindow else { return }
            if let sf = window.contentView?.findFirstSearchField() {
                window.makeFirstResponder(sf)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                control.window?.makeFirstResponder(nil)
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return true
            }
            return false
        }
    }
}

// NSView ツリーから最初の NSSearchField を探すユーティリティ
private extension NSView {
    func findFirstSearchField() -> NSSearchField? {
        if let sf = self as? NSSearchField { return sf }
        for sub in subviews {
            if let found = sub.findFirstSearchField() { return found }
        }
        return nil
    }
}

// MARK: - Search field container

private struct SearchFieldContainer: View {
    @Environment(LibraryStore.self) private var store
    @State private var localText: String = ""

    var body: some View {
        NativeSearchField(
            text: $localText,
            placeholder: String(localized: "Search filename or caption")
        )
        .frame(minWidth: 160, maxWidth: 260)
        .onChange(of: localText) { _, new in store.setNameSearch(new) }
        .onChange(of: store.filter.nameSearch) { _, new in
            if new != localText { localText = new }
        }
    }
}

// MARK: -

struct ToolbarView: ToolbarContent {
    @Environment(LibraryStore.self) private var store

    var body: some ToolbarContent {
        @Bindable var store = store
        @Bindable var settings = store.settings

        ToolbarItemGroup(placement: .navigation) {
            if !store.viewerMode && !store.compareMode {
                Button(action: { store.requestOpenFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
            }
            Button(action: { store.undoManager.undo() }) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)
            .help(store.undoActionTitle ?? String(localized: "Undo (⌘Z)"))
        }

        ToolbarItemGroup(placement: .principal) {
            if settings.boostNoticeVisible {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.orange)
                    Text("Boost Mode active")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .transition(.opacity)
            } else if let msg = store.undoMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: {
                settings.burstMode.toggle()
                if settings.burstMode {
                    settings.showBoostNotice()
                } else {
                    settings.hideBoostNotice()
                }
            }) {
                Image(systemName: settings.burstMode ? "bolt.fill" : "bolt")
                    .foregroundStyle(settings.burstMode ? Color.orange : Color.primary)
            }
            .help(String(localized: "Boost Mode"))

            if !store.viewerMode && !store.compareMode {
                SearchFieldContainer()
            }

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

