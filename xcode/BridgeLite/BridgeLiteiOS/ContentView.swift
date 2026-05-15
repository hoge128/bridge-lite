import SwiftUI

struct ContentView: View {
    @State private var scanStore = ScanStore()
    @State private var ratingStore = RatingStore()
    @State private var showFolderPicker = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if scanStore.folderURL != nil {
                ThumbnailGridView(scanStore: scanStore, ratingStore: ratingStore)
            } else {
                welcomeView
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await scanStore.verifyFolderReachability() }
            }
        }
    }

    private var welcomeView: some View {
        ZStack {
            LinearGradient(
                colors: [Color(.systemGray5), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "sdcard")
                    .font(.system(size: 72))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("BridgeLite")
                        .font(.largeTitle.bold())
                    Text("SD カードの写真をセレクト")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showFolderPicker = true
                } label: {
                    Label("SD カードを開く", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                }
                .prominentGlassButton()
            }
            .padding(40)
            .adaptiveGlass(cornerRadius: 28)
            .padding(.horizontal, 28)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPickerView { url in
                showFolderPicker = false
                scanStore.scan(url: url)
            }
        }
    }
}
