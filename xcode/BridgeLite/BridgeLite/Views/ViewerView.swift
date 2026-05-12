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
    @State private var zoom = ZoomState()
    @State private var scrollMonitor: Any?
    @State private var magnifyMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var windowRef = WindowRef()

    private var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    private var thumbnail: CGImage? {
        store.selectedID.flatMap { store.thumbnailImage(for: $0) }
    }

    private var shouldShowOverlay: Bool {
        store.viewerShowsMeta && selectedEntry != nil
    }

    // CR2 on macOS 26: CIRAWFilter unsupported; only an 18 KB embedded thumbnail is available.
    private var isLimitedRawPreview: Bool {
        selectedEntry?.url.pathExtension.lowercased() == "cr2"
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
                    ZoomableImage(image: img, orientation: orient, zoom: zoom)
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

                if isLimitedRawPreview {
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.yellow.opacity(0.85))
                            Text(String(localized: "raw.limited.preview.notice",
                                        defaultValue: "Embedded thumbnail only — CR2 RAW rendering is not available on macOS 26"))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .help(String(localized: "raw.limited.preview.tooltip",
                                     defaultValue: "This CR2 file only contains an 18 KB embedded thumbnail. Full-resolution RAW rendering is not supported on macOS 26."))
                        .padding(.bottom, 14)
                    }
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
                            Button("Prev") { store.navigateViewerPrev() }
                                .keyboardShortcut(.leftArrow, modifiers: [])
                            Button("Next") { store.navigateViewerNext() }
                                .keyboardShortcut(.rightArrow, modifiers: [])
                        }
                        .padding()
                    }
                    Spacer()

                    HStack(alignment: .bottom) {
                        if shouldShowOverlay, let entry = selectedEntry {
                            ViewerMetaOverlay(entry: entry, exif: store.exifData[entry.id], xmp: xmp) {
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
        .background(WindowAccessor(window: Binding(
            get: { windowRef.window },
            set: { windowRef.window = $0 }
        )))
        .onAppear {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            store.viewerShowsMeta = hasRatingOrLabel
            let s = store
            let z = zoom
            let ref = windowRef
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === ref.window else { return event }
                if event.keyCode == 53 || event.keyCode == 49 { // Escape / Space
                    s.viewerMode = false
                    return nil
                }
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if event.keyCode == 34, mods.isEmpty { // i: toggle metadata overlay
                    s.viewerShowsMeta.toggle()
                    return nil
                }
                // Arrow keys: pan when zoomed, otherwise let Prev/Next shortcut handle them
                if mods.isEmpty, z.scale > 1.0 {
                    let step: CGFloat = 50
                    switch event.keyCode {
                    case 123: z.offset.width  -= step; z.clampOffset(); z.baseOffset = z.offset; return nil
                    case 124: z.offset.width  += step; z.clampOffset(); z.baseOffset = z.offset; return nil
                    case 125: z.offset.height += step; z.clampOffset(); z.baseOffset = z.offset; return nil
                    case 126: z.offset.height -= step; z.clampOffset(); z.baseOffset = z.offset; return nil
                    default: break
                    }
                }
                return event
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard event.window === ref.window else { return event }
                if event.hasPreciseScrollingDeltas {
                    // Trackpad two-finger scroll → pan (only when zoomed)
                    guard z.scale > 1.0 else { return event }
                    z.offset.width  += event.scrollingDeltaX
                    z.offset.height -= event.scrollingDeltaY
                    z.clampOffset()
                    z.baseOffset = z.offset
                } else {
                    // Mouse wheel → zoom centered on cursor
                    let cursor = viewerCursorFromCenter(event)
                    z.applyScaleDelta(CGFloat(event.scrollingDeltaY) * 0.04, around: cursor)
                }
                return event
            }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
                guard event.window === ref.window else { return event }
                let cursor = viewerCursorFromCenter(event)
                z.applyScaleDelta(CGFloat(event.magnification), around: cursor)
                return event
            }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard event.window === ref.window else { return event }
                guard event.clickCount == 2 else { return event }
                let cursor = viewerCursorFromCenter(event)
                z.toggleFitOrHundred(at: cursor)
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor  { NSEvent.removeMonitor(m); keyMonitor  = nil }
            if let m = scrollMonitor  { NSEvent.removeMonitor(m); scrollMonitor  = nil }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
            if let m = clickMonitor   { NSEvent.removeMonitor(m); clickMonitor   = nil }
            infoHideTask?.cancel()
            store.viewerCompareGroupMembers = nil
        }
        .onReceive(store.xmpDidUpdate) { id in
            guard id == store.selectedID else { return }
            let newXmp = store.xmpData[id]
            xmp = newXmp
            if (newXmp?.rating ?? 0) > 0 || newXmp?.label != nil {
                store.viewerShowsMeta = true
            }
        }
        .task(id: store.selectedID) {
            xmp = store.selectedID.flatMap { store.xmpData[$0] }
            fullRes = nil
            rawRendered = nil
            showRendered = false
            zoom.reset()
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
        if let entry = selectedEntry, entry.isRaw, !isLimitedRawPreview {
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
            // Use cached orientation to avoid re-opening the RAW file (which allocates extra IOSurfaces).
            let orient = store.thumbnailOrientations[entry.id] ?? .up
            return await LargeImageDecoder.decodeFromData(data, orientation: orient)
        }
        // Non-RAW path, or RAW fallback when IFD2 JPEG is absent (e.g. DxO PureRAW DNG)
        return await LargeImageDecoder.decodeFromURL(entry.url)
    }
}

// Returns cursor position relative to the window content view center (SwiftUI coordinate: Y-down).
private func viewerCursorFromCenter(_ event: NSEvent) -> CGPoint {
    guard let window = event.window, let cv = window.contentView else { return .zero }
    let loc = event.locationInWindow
    return CGPoint(x: loc.x - cv.bounds.midX, y: cv.bounds.midY - loc.y)
}

// MARK: - Metadata overlay

private struct ViewerMetaOverlay: View {
    let entry: PhotoEntry
    let exif: ExifData?
    let xmp: XmpData?
    let onHide: () -> Void

    private static let mono: Font = .system(.caption2, design: .monospaced)

    private var bgColor: Color {
        xmp?.label?.color.opacity(0.45) ?? Color(white: 0.08, opacity: 0.72)
    }

    // Tier 1 – Exposure
    private var fText: String? { exif?.fnumber }
    private var ssText: String? {
        guard let s = exif?.exposureTime else { return nil }
        return s.components(separatedBy: " ").first ?? s
    }
    private var isoText: String? { exif?.iso.map { "ISO \($0)" } }
    private var hasTier1: Bool { fText != nil || ssText != nil || isoText != nil }

    // Tier 2 – Focal length (35mm equiv preferred)
    private var focalText: String? {
        guard let mm = exif?.effectiveFocalMm else { return nil }
        let v = mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm)
        return "\(v) mm"
    }

    // Tier 3 – Camera / Lens
    private var hasTier3: Bool { exif?.cameraName != nil || exif?.lensName != nil }

    // Horizontal separator spanning full overlay width
    private var hSep: some View {
        Color.white.opacity(0.12)
            .frame(height: 0.5)
            .padding(.vertical, 4)
    }

    // Vertical separator between tier-1 cells (fixed height prevents HStack expansion)
    private var vSep: some View {
        Color.white.opacity(0.12)
            .frame(width: 0.5, height: 14)
    }

    // Equal-width centered cell — Spacer sandwich avoids frame(maxWidth:.infinity) height expansion
    private func exifCell(_ value: String?) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(value ?? "")
                .font(Self.mono)
                .foregroundStyle(.white.opacity(value != nil ? 0.9 : 0))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: close button left, filename + rating centered in remaining space
            HStack(alignment: .top, spacing: 0) {
                Button(action: onHide) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                Spacer(minLength: 0)

                VStack(alignment: .center, spacing: 2) {
                    Text(entry.filename)
                        .font(Self.mono)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let rating = xmp?.rating, rating > 0 {
                        Text(String(repeating: "★", count: rating))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.yellow.opacity(0.95))
                    }
                }

                Spacer(minLength: 0)
            }

            // Tier 1: F値 · SS · ISO — 3 equal centered cells
            if hasTier1 {
                hSep
                HStack(spacing: 0) {
                    exifCell(fText)
                    vSep
                    exifCell(ssText)
                    vSep
                    exifCell(isoText)
                }
            }

            // Tier 2: Focal length centered
            if let fl = focalText {
                hSep
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(fl)
                        .font(Self.mono)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }

            // Tier 3: Camera + Lens centered
            if hasTier3 {
                hSep
                VStack(spacing: 3) {
                    if let cam = exif?.cameraName {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Text(cam)
                                .font(Self.mono)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    if let lens = exif?.lensName {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Text(lens)
                                .font(Self.mono)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 250)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(bgColor, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
