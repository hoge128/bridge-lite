import CoreGraphics
import ImageIO
import SwiftUI

struct ViewerView: View {
    @Environment(LibraryStore.self) private var store
    @State private var fullResImage: CGImage?
    @State private var isLoadingFullRes = false

    var previewImage: CGImage? {
        store.selectedID.flatMap { store.thumbnailImages[$0] }
    }

    var displayImage: CGImage? { fullResImage ?? previewImage }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = displayImage {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }

            if isLoadingFullRes {
                ProgressView()
                    .tint(.white)
                    .frame(width: 40, height: 40)
            }

            VStack {
                HStack {
                    Button("Close") { store.viewerMode = false }
                        .keyboardShortcut(.escape, modifiers: [])
                        .padding()
                    Spacer()
                    HStack(spacing: 16) {
                        Button("Prev") { store.navigatePrev() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next") { store.navigateNext() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding()
                }
                Spacer()
            }
        }
        .task(id: store.selectedID) {
            fullResImage = nil
            guard let id = store.selectedID,
                  let entry = store.entries[id] else { return }
            isLoadingFullRes = true
            defer { isLoadingFullRes = false }
            fullResImage = await loadFullRes(entry: entry)
        }
    }

    private func loadFullRes(entry: PhotoEntry) async -> CGImage? {
        if entry.isRaw {
            // RAW: extract full embedded JPEG via Rust
            guard let data = await BridgeCore.extractRawJpeg(url: entry.url, quality: .full) else { return nil }
            return CGImage.fromJPEGData(data)
        } else {
            // Non-RAW: use ImageIO directly
            return await Task.detached(priority: .userInitiated) {
                guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(src, 0, nil)
            }.value
        }
    }
}
