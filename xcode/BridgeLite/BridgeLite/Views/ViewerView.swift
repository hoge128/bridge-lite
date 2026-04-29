import CoreGraphics
import ImageIO
import SwiftUI

struct ViewerView: View {
    @Environment(LibraryStore.self) private var store
    @State private var fullResImage: CGImage?
    @State private var isLoadingFullRes = false
    @State private var keyMonitor: Any?

    private var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    private var thumbnail: CGImage? {
        store.selectedID.flatMap { store.thumbnailImages[$0] }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = fullResImage {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else if let thumb = thumbnail {
                // While loading: blurred + dimmed thumbnail as spatial placeholder.
                // After failure (not loading): plain thumbnail as best-effort fallback.
                Image(decorative: thumb, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: isLoadingFullRes ? 24 : 0)
                    .opacity(isLoadingFullRes ? 0.35 : 1.0)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }

            if isLoadingFullRes, let entry = selectedEntry {
                LoadingCard(filename: entry.filename, sizeText: entry.formattedFileSize)
            }

            VStack {
                HStack {
                    Button("Close") { store.viewerMode = false }
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
        .onAppear {
            let s = store
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event } // Escape
                s.viewerMode = false
                return nil // consume して GroupCompareView の Escape が連鎖しないようにする
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
        if entry.isRaw,
           let data = await BridgeCore.extractRawJpeg(url: entry.url, quality: .full),
           let img = CGImage.fromJPEGData(data) {
            return img
        }
        // Non-RAW path, or RAW fallback when IFD2 JPEG is absent (e.g. DxO PureRAW DNG)
        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }.value
    }
}

private struct LoadingCard: View {
    let filename: String
    let sizeText: String
    @State private var ringRotation: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 4)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(ringRotation))
            }
            Text(filename)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }
}
