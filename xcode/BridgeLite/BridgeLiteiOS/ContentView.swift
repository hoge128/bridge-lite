import SwiftUI

struct ContentView: View {
    @State private var scanStore = ScanStore()
    @State private var ratingStore = RatingStore()
    @State private var showFolderPicker = false
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var welcomeAppeared = false
    @AppStorage("ios.hasOpenedFolderBefore") private var hasOpenedFolderBefore = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if scanStore.folderURL != nil {
                ThumbnailGridView(scanStore: scanStore, ratingStore: ratingStore)
            } else {
                welcomeView
                    .opacity(welcomeAppeared ? 1 : 0)
                    .onAppear { welcomeAppeared = false }
                    .task {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        withAnimation(.easeOut(duration: 0.35)) { welcomeAppeared = true }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                BackgroundScanManager.shared.endExtendedTime()
                Task { await scanStore.verifyFolderReachability() }
            case .background:
                if scanStore.isScanning {
                    BackgroundScanManager.shared.beginExtendedTime()
                    BackgroundScanManager.shared.scheduleTask()
                }
            default:
                break
            }
        }
        .onChange(of: scanStore.isScanning) { _, isScanning in
            if !isScanning {
                BackgroundScanManager.shared.endExtendedTime()
                BackgroundScanManager.shared.cancelScheduledTask()
            }
        }
    }

    private var welcomeView: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGray5), Color(.systemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    VStack(spacing: 28) {
                        Image(systemName: "sdcard")
                            .font(.system(size: 72))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 6) {
                            Text("BridgeLite")
                                .font(.largeTitle.bold())
                            Text(String(localized: "welcome.subtitle", defaultValue: "Select photos from your SD card"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            showFolderPicker = true
                        } label: {
                            Label(String(localized: "welcome.open_folder", defaultValue: "Open SD Card"), systemImage: "folder.badge.plus")
                                .font(.headline)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 14)
                        }
                        .prominentGlassButton()
                    }
                    .padding(40)
                    .adaptiveGlass(cornerRadius: 28)
                    .padding(.horizontal, 28)

                    Button {
                        showGuide = true
                    } label: {
                        Text("guide.link", tableName: nil)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .glassNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    hasOpenedFolderBefore = true
                    showFolderPicker = false
                    scanStore.scan(url: url)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheetView(scanStore: scanStore) { showSettings = false }
            }
            .sheet(isPresented: $showGuide) {
                OnboardingGuideView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
