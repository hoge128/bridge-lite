import SwiftUI

struct ContentView: View {
    @State private var scanStore = ScanStore()
    @State private var ratingStore = RatingStore()
    @State private var showFolderPicker = false

    var body: some View {
        if scanStore.folderURL != nil {
            ThumbnailGridView(scanStore: scanStore, ratingStore: ratingStore)
        } else {
            welcomeView
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 32) {
            Image(systemName: "sdcard")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("BridgeLite")
                    .font(.largeTitle.bold())
                Text("SD カードの写真をセレクト")
                    .foregroundStyle(.secondary)
            }

            Button {
                showFolderPicker = true
            } label: {
                Label("SD カードを開く", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                showFolderPicker = false
                scanStore.scan(url: url)
            }
        }
        .onAppear {
            if let url = BookmarkStore.restore() {
                scanStore.scan(url: url)
            }
        }
    }
}
