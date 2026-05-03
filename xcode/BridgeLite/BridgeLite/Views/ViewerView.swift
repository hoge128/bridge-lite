import CoreGraphics
import ImageIO
import SwiftUI

struct ViewerView: View {
    @Environment(LibraryStore.self) private var store
    @State private var fullRes: (CGImage, Image.Orientation)?
    @State private var isLoadingFullRes = false
    @State private var keyMonitor: Any?
    @State private var xmp: XmpData? = nil
    @State private var rawRendered: (CGImage, Image.Orientation)?
    @State private var isRendering = false
    @State private var showRendered = false
    @State private var showInfoButton = false
    @State private var infoHideTask: Task<Void, Never>?

    private var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    private var thumbnail: CGImage? {
        store.selectedID.flatMap { store.thumbnailImage(for: $0) }
    }

    private var shouldShowOverlay: Bool {
        store.viewerShowsMeta && selectedEntry != nil
    }

    private var hasRatingOrLabel: Bool {
        (xmp?.rating ?? 0) > 0 || xmp?.label != nil
    }

    private var displayPair: (CGImage, Image.Orientation)? {
        if showRendered, let r = rawRendered { return r }
        return fullRes
    }

    var body: some View {
        @Bindable var store = store
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if let (img, orient) = displayPair {
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
                            .opacity(showInfoButton ? 1 : 0)
                            .offset(x: showInfoButton ? 0 : 18)
                            .allowsHitTesting(showInfoButton)
                            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: showInfoButton)
                            renderButton
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
            .onContinuousHover { phase in
                handleInfoHover(phase: phase, size: geo.size)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.viewerShowsMeta)
        .onAppear {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            store.viewerShowsMeta = hasRatingOrLabel
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
            infoHideTask?.cancel()
        }
        .onReceive(store.xmpDidUpdate) { id in
            guard id == store.selectedID else { return }
            xmp = store.xmpData[id]
        }
        .task(id: store.selectedID) {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            fullRes = nil
            rawRendered = nil
            showRendered = false
            guard let id = store.selectedID,
                  let entry = store.entries[id] else { return }
            isLoadingFullRes = true
            defer { isLoadingFullRes = false }
            fullRes = await loadFullRes(entry: entry)
        }
    }

    private func handleInfoHover(phase: HoverPhase, size: CGSize) {
        switch phase {
        case .active(let location):
            if location.x > size.width / 2 && location.y < size.height / 2 {
                infoHideTask?.cancel()
                showInfoButton = true
                infoHideTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    showInfoButton = false
                }
            } else {
                infoHideTask?.cancel()
                infoHideTask = nil
                showInfoButton = false
            }
        case .ended:
            infoHideTask?.cancel()
            infoHideTask = nil
            showInfoButton = false
        }
    }

    @ViewBuilder
    private var renderButton: some View {
        if let entry = selectedEntry, entry.isRaw {
            if isRendering {
                ProgressView()
                    .controlSize(.small)
                    .help(String(localized: "render.loading", defaultValue: "Rendering…"))
            } else if rawRendered != nil {
                Button {
                    showRendered.toggle()
                } label: {
                    Image(systemName: showRendered ? "wand.and.stars.inverse" : "wand.and.stars")
                }
                .help(showRendered
                      ? String(localized: "render.toggle.embedded", defaultValue: "Show embedded preview")
                      : String(localized: "render.toggle.rendered", defaultValue: "Show rendered preview"))
            } else {
                Button {
                    triggerRender(entry: entry)
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help(String(localized: "render.button", defaultValue: "Render with engine"))
            }
        }
    }

    private func triggerRender(entry: PhotoEntry) {
        guard let db = store.cacheDatabase else { return }
        Task {
            isRendering = true
            defer { isRendering = false }
            rawRendered = await RAWRenderPipeline.shared.render(
                url: entry.url, target: .viewer, db: db
            )
            if rawRendered != nil { showRendered = true }
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
