import SwiftUI

struct SettingsSheetView: View {
    @Bindable var scanStore: ScanStore
    @State private var showCacheClearConfirm = false
    @State private var cacheSizeBytes: Int64 = 0
    var onDismiss: () -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Sort")) {
                    Picker(String(localized: "Sort by"), selection: $scanStore.sortKey) {
                        ForEach(IOSSortKey.allCases, id: \.self) { key in
                            Text(key.localizedName).tag(key)
                        }
                    }
                    Toggle(String(localized: "Ascending"), isOn: $scanStore.sortAscending)
                }

                Section(String(localized: "Cache")) {
                    LabeledContent(String(localized: "Cache Size")) {
                        Text(Self.byteFormatter.string(fromByteCount: cacheSizeBytes))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showCacheClearConfirm = true
                    } label: {
                        Label(String(localized: "Clear Cache"), systemImage: "trash")
                    }
                    .disabled(cacheSizeBytes == 0)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done")) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { cacheSizeBytes = ScanStore.cacheSizeBytes() }
        .confirmationDialog(
            String(localized: "Clear Cache?"),
            isPresented: $showCacheClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear"), role: .destructive) {
                scanStore.clearCache()
                onDismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Thumbnail cache will be deleted and regenerated on the next scan.")
        }
    }
}
