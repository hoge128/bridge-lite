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
        .contextMenu { viewerContextMenu }
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
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard mods.isEmpty else { return event }
                switch event.keyCode {
                case 53: // Escape
                    if ref.window?.styleMask.contains(.fullScreen) == true {
                        ref.window?.toggleFullScreen(nil)
                        // Setting ON: auto-fullscreen on enter → Esc skips viewer and returns to previous state
                        if SettingsStore.shared.viewerSpaceFullscreen {
                            s.viewerMode = false
                        }
                    } else {
                        s.viewerMode = false
                    }
                    return nil
                case 49: // Space: exit viewer
                    s.viewerMode = false
                    return nil
                case 46: // m: toggle fullscreen
                    ref.window?.toggleFullScreen(nil)
                    return nil
                case 34: // i: toggle metadata overlay
                    s.viewerShowsMeta.toggle()
                    return nil
                default:
                    break
                }
                // Arrow keys: pan when zoomed, otherwise let Prev/Next shortcut handle them
                if z.scale > 1.0 {
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

    private var deleteShortcut: KeyboardShortcut {
        store.settings.deleteShortcutKey == .delete
            ? KeyboardShortcut(.delete, modifiers: [])
            : KeyboardShortcut(.delete, modifiers: .command)
    }

    @ViewBuilder
    private var viewerContextMenu: some View {
        if let entry = selectedEntry {
            Button(String(localized: "Copy")) {
                store.triggerCopy()
            }
            Button(String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
            OpenWithMenu(targetURLs: [entry.url], primaryURL: entry.url)

            Divider()

            Button(store.viewerShowsMeta
                   ? String(localized: "viewer.context.hide_details", defaultValue: "Hide Details")
                   : String(localized: "viewer.context.show_details", defaultValue: "Show Details")) {
                store.viewerShowsMeta.toggle()
            }

            Divider()

            Menu(String(localized: "Rating")) {
                let mods = store.settings.ratingShortcutModifier.swiftUIModifiers
                Button(String(localized: "No Rating")) { store.triggerRating(0) }
                    .keyboardShortcut("0", modifiers: mods)
                ForEach(1...5, id: \.self) { n in
                    Button(String(repeating: "★", count: n)) { store.triggerRating(n) }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: mods)
                }
            }
            Menu(String(localized: "Label")) {
                let mods = store.settings.ratingShortcutModifier.swiftUIModifiers
                Button(XmpLabel.red.name)    { store.applyLabel(XmpLabel.red.rawValue) }
                    .keyboardShortcut("6", modifiers: mods)
                Button(XmpLabel.yellow.name) { store.applyLabel(XmpLabel.yellow.rawValue) }
                    .keyboardShortcut("7", modifiers: mods)
                Button(XmpLabel.green.name)  { store.applyLabel(XmpLabel.green.rawValue) }
                    .keyboardShortcut("8", modifiers: mods)
                Button(XmpLabel.blue.name)   { store.applyLabel(XmpLabel.blue.rawValue) }
                    .keyboardShortcut("9", modifiers: mods)
                Button(XmpLabel.purple.name) { store.applyLabel(XmpLabel.purple.rawValue) }
                Divider()
                Button(String(localized: "Clear Label")) {
                    if let current = xmp?.label { store.applyLabel(current.rawValue) }
                }
            }

            Divider()

            Button(String(localized: "compare.context.back_to_grid",
                          defaultValue: "Back to Grid")) {
                store.viewerMode = false
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button(String(localized: "viewer.context.move_to_compare",
                          defaultValue: "Move to Compare")) {
                store.compareAnchorID = entry.id
                store.viewerMode = false
                store.compareMode = true
            }

            Divider()

            Button(role: .destructive) {
                store.triggerDelete()
            } label: {
                Text(String(localized: "Move to Trash"))
            }
            .keyboardShortcut(deleteShortcut)
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

    @Environment(LibraryStore.self) private var store
    @State private var dragRating: Int? = nil
    @State private var dragStartRating: Int = 0

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
                    let currentRating = dragRating ?? (xmp?.rating ?? 0)
                    HStack(spacing: 1) {
                        ForEach(1...5, id: \.self) { i in
                            Text(i <= currentRating ? "★" : "☆")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(
                                    i <= currentRating
                                        ? Color(red: 0.95, green: 0.55, blue: 0.05)
                                        : Color.white.opacity(0.25)
                                )
                        }
                    }
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            if dragRating == nil { dragStartRating = xmp?.rating ?? 0 }
                                            let delta = Int(value.translation.width / 18)
                                            dragRating = max(0, min(5, dragStartRating + delta))
                                        }
                                        .onEnded { value in
                                            let dx = value.translation.width
                                            let dy = value.translation.height
                                            if abs(dx) < 4 && abs(dy) < 4 {
                                                let starWidth = geo.size.width / 5
                                                let rating = Int(value.startLocation.x / starWidth) + 1
                                                store.applyRating(max(1, min(5, rating)))
                                            } else {
                                                let delta = Int(value.translation.width / 18)
                                                store.applyRating(max(0, min(5, dragStartRating + delta)))
                                            }
                                            dragRating = nil
                                        }
                                )
                        }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.resizeLeftRight.push()
                        case .ended:  NSCursor.pop()
                        }
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
