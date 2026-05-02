import CoreGraphics
import ImageIO
import SwiftUI

struct ViewerView: View {
    @Environment(LibraryStore.self) private var store
    @State private var fullRes: (CGImage, Image.Orientation)?
    @State private var isLoadingFullRes = false
    @State private var keyMonitor: Any?
    @State private var xmp: XmpData? = nil

    private var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    private var thumbnail: CGImage? {
        store.selectedID.flatMap { store.thumbnailImage(for: $0) }
    }

    private var shouldShowOverlay: Bool {
        guard store.viewerShowsMeta, selectedEntry != nil else { return false }
        return (xmp?.rating ?? 0) > 0 || xmp?.label != nil
    }

    var body: some View {
        @Bindable var store = store
        ZStack {
            Color.black.ignoresSafeArea()

            if let (img, orient) = fullRes {
                Image(decorative: img, scale: 1.0, orientation: orient)
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
                        Button {
                            store.viewerShowsMeta.toggle()
                        } label: {
                            Image(systemName: store.viewerShowsMeta ? "info.circle.fill" : "info.circle")
                        }
                        .help(store.viewerShowsMeta
                              ? String(localized: "viewer.meta.hide", defaultValue: "Hide Info (M)")
                              : String(localized: "viewer.meta.show", defaultValue: "Show Info (M)"))
                        Button("Prev") { store.navigatePrev() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next") { store.navigateNext() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding()
                }
                Spacer()

                HStack(alignment: .bottom) {
                    if shouldShowOverlay, let entry = selectedEntry {
                        ViewerMetaOverlay(entry: entry, xmp: xmp) {
                            store.viewerShowsMeta = false
                        }
                        .padding([.leading, .bottom], 16)
                        .transition(.opacity)
                    }
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.viewerShowsMeta)
        .onAppear {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            let s = store
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    s.viewerMode = false
                    return nil
                }
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 46, mods.isEmpty { // m: toggle metadata overlay
                    s.viewerShowsMeta.toggle()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .onReceive(store.xmpDidUpdate) { id in
            guard id == store.selectedID else { return }
            xmp = store.xmpData[id]
        }
        .task(id: store.selectedID) {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            fullRes = nil
            guard let id = store.selectedID,
                  let entry = store.entries[id] else { return }
            isLoadingFullRes = true
            defer { isLoadingFullRes = false }
            fullRes = await loadFullRes(entry: entry)
        }
    }

    private func loadFullRes(entry: PhotoEntry) async -> (CGImage, Image.Orientation)? {
        if entry.isRaw,
           let data = await BridgeCore.extractRawJpeg(url: entry.url, quality: .full) {
            let url = entry.url
            return await Task.detached(priority: .userInitiated) {
                // The embedded JPEG typically lacks an orientation tag; read it from the RAW source.
                // We only call CopyProperties (no pixel decode) so the macOS 26 RawCamera crash does not apply.
                let orient: CGImagePropertyOrientation
                if let rawSrc = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    orient = readOrientation(rawSrc)
                } else {
                    orient = .up
                }
                guard let jpegSrc = CGImageSourceCreateWithData(data as CFData, nil),
                      let img = CGImageSourceCreateImageAtIndex(jpegSrc, 0, nil) else { return nil }
                return (img, Image.Orientation(orient))
            }.value
        }
        // Non-RAW path, or RAW fallback when IFD2 JPEG is absent (e.g. DxO PureRAW DNG)
        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return (img, Image.Orientation(readOrientation(src)))
        }.value
    }
}

// MARK: - Metadata overlay

private struct ViewerMetaOverlay: View {
    let entry: PhotoEntry
    let xmp: XmpData?
    let onHide: () -> Void

    private var bgColor: Color {
        xmp?.label?.color.opacity(0.45) ?? Color(white: 0.08, opacity: 0.72)
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onHide) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)

            Text(entry.filename)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220)

            if let rating = xmp?.rating, rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.95))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Loading card

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
