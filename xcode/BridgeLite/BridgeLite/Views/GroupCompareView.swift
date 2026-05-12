import CoreGraphics
import ImageIO
import SwiftUI
import CoreImage

struct GroupCompareView: View {
    @Environment(LibraryStore.self) private var store
    @State private var currentRepID: UInt64
    @State private var imageFilesOnly: Bool = false
    @State private var lastMemberTap: (id: UInt64, time: Date)?

    init(initialID: UInt64) {
        _currentRepID = State(initialValue: initialID)
    }

    private var allGroupMembers: [UInt64] {
        if store.filter.flatten { return [currentRepID] }
        guard let entry = store.entries[currentRepID],
              let members = store.shotGroups[entry.shotId],
              members.count > 1 else {
            return [currentRepID]
        }
        return members.sorted { a, b in
            let oa = store.displayKind(for: a).displayOrder
            let ob = store.displayKind(for: b).displayOrder
            if oa != ob { return oa < ob }
            let da = store.entries[a]?.createdDate ?? .distantPast
            let db = store.entries[b]?.createdDate ?? .distantPast
            return da < db
        }
    }

    private var groupMembers: [UInt64] {
        guard imageFilesOnly else { return allGroupMembers }
        let filtered = allGroupMembers.filter { store.entries[$0]?.isRaw != true }
        return filtered.isEmpty ? allGroupMembers : filtered
    }

    private var navMode: CompareNavMode { store.settings.compareNavMode }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                GeometryReader { geo in
                    let n = groupMembers.count
                    let (rows, cols) = optimalGrid(memberCount: n, viewportSize: geo.size)
                    let spacing: CGFloat = 8
                    let minCellHeight: CGFloat = 160
                    let cellHeight = max(geo.size.height / CGFloat(rows) - spacing, minCellHeight)
                    let gridColumns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: gridColumns, spacing: spacing) {
                            ForEach(groupMembers, id: \.self) { memberID in
                                CompareMemberColumn(
                                    memberID: memberID,
                                    isFocused: store.primaryID == memberID
                                )
                                .frame(height: cellHeight)
                                .onTapGesture { handleMemberTap(memberID) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background {
            Group {
                Button("") {
                    if store.primaryID != nil {
                        store.viewerCompareGroupMembers = groupMembers
                        store.viewerMode = true
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                // Ctrl+Tab: mode に応じてグループ間/メンバー間移動
                Button("") {
                    if navMode == .memberFirst { navigateNext() } else { navigateMemberNext() }
                }
                .keyboardShortcut(.tab, modifiers: .control)
                Button("") {
                    if navMode == .memberFirst { navigatePrev() } else { navigateMemberPrev() }
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onAppear {
            resolveRepAndFocus()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button("Close") { closeCompare() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            HStack(spacing: 8) {
                if let msg = store.undoMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                } else if let idx = store.visibleIDs.firstIndex(of: currentRepID) {
                    Text("\(idx + 1) / \(store.visibleIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button { imageFilesOnly.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: imageFilesOnly ? "photo.fill" : "photo")
                    Text("Image only")
                }
                .font(.callout)
                .fontWeight(imageFilesOnly ? .semibold : .regular)
                .foregroundStyle(imageFilesOnly ? .white : .white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    imageFilesOnly ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.1),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                Button {
                    store.settings.compareNavMode = navMode == .memberFirst ? .groupFirst : .memberFirst
                } label: {
                    Label(
                        navMode == .memberFirst ? "Member" : "Group",
                        systemImage: navMode == .memberFirst ? "rectangle.stack" : "arrow.left.and.right"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.7))
                .help(navMode == .memberFirst
                      ? "←→: Member navigation / Ctrl+Tab: Group navigation"
                      : "←→: Group navigation / Ctrl+Tab: Member navigation")

                HStack(spacing: 24) {
                    Button {
                        if navMode == .memberFirst { navigateMemberPrev() } else { navigatePrev() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.8))

                    Button {
                        if navMode == .memberFirst { navigateMemberNext() } else { navigateNext() }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Navigation

    private func resolveRepAndFocus() {
        // If currentRepID is not in visibleIDs (e.g., user Tab-cycled to a member),
        // find the representative of its group.
        if !store.visibleIDs.contains(currentRepID) {
            if let entry = store.entries[currentRepID],
               let members = store.shotGroups[entry.shotId] {
                let visSet = Set(store.visibleIDs)
                if let rep = members.first(where: { visSet.contains($0) }) {
                    currentRepID = rep
                }
            }
        }
        if let first = groupMembers.first {
            store.selectEntry(first)
        }
    }

    private func navigatePrev() {
        guard let idx = store.visibleIDs.firstIndex(of: currentRepID), idx > 0 else { return }
        switchToRep(store.visibleIDs[idx - 1])
    }

    private func navigateNext() {
        guard let idx = store.visibleIDs.firstIndex(of: currentRepID),
              idx + 1 < store.visibleIDs.count else { return }
        switchToRep(store.visibleIDs[idx + 1])
    }

    private func switchToRep(_ repID: UInt64) {
        currentRepID = repID
        let members: [UInt64]
        if let entry = store.entries[repID],
           let group = store.shotGroups[entry.shotId],
           group.count > 1 {
            members = group.sorted { a, b in
                let oa = store.displayKind(for: a).displayOrder
                let ob = store.displayKind(for: b).displayOrder
                if oa != ob { return oa < ob }
                let da = store.entries[a]?.createdDate ?? .distantPast
                let db = store.entries[b]?.createdDate ?? .distantPast
                return da < db
            }
        } else {
            members = [repID]
        }
        if let first = members.first { store.selectEntry(first) }
    }

    private func navigateMemberNext() {
        let members = groupMembers
        guard let current = store.primaryID,
              let idx = members.firstIndex(of: current),
              idx + 1 < members.count else { return }
        store.selectEntry(members[idx + 1])
    }

    private func navigateMemberPrev() {
        let members = groupMembers
        guard let current = store.primaryID,
              let idx = members.firstIndex(of: current),
              idx > 0 else { return }
        store.selectEntry(members[idx - 1])
    }

    private func handleMemberTap(_ memberID: UInt64) {
        if let last = lastMemberTap,
           last.id == memberID,
           Date().timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
            store.selectEntry(memberID)
            store.viewerCompareGroupMembers = groupMembers
            store.viewerMode = true
            lastMemberTap = nil
            return
        }
        lastMemberTap = (id: memberID, time: Date())
        store.selectEntry(memberID)
    }

    private func closeCompare() {
        store.selectEntry(currentRepID)
        store.compareMode = false
    }

    private func optimalGrid(memberCount n: Int, viewportSize size: CGSize) -> (rows: Int, cols: Int) {
        guard n > 0 else { return (1, 1) }
        let viewportAspect = max(0.1, size.width / max(size.height, 1))
        let imageAspect: CGFloat = 1.5
        let rawCols = (Double(n) * Double(viewportAspect) / Double(imageAspect)).squareRoot()
        let cols = min(max(Int(rawCols.rounded()), 1), n)
        let rows = Int((Double(n) / Double(cols)).rounded(.up))
        return (rows, cols)
    }
}

// MARK: - Column

private struct CompareMemberColumn: View {
    let memberID: UInt64
    let isFocused: Bool
    @Environment(LibraryStore.self) private var store
    @State private var previewImage: (CGImage, Image.Orientation)?
    @State private var isLoadingPreview = false
    @State private var rawRendered: (CGImage, Image.Orientation)?
    @State private var isRendering = false
    @State private var showRendered = false

    private var entry: PhotoEntry? { store.entries[memberID] }
    private var thumbnail: CGImage? { store.thumbnailImage(for: memberID) }
    private var xmp: XmpData? { store.xmpData[memberID] }
    private var exif: ExifData? { store.exifData[memberID] }

    // CR2 on macOS 26: CIRAWFilter unsupported; only an 18 KB embedded thumbnail is available.
    private var isLimitedRawPreview: Bool {
        entry?.url.pathExtension.lowercased() == "cr2"
    }

    private var kindLabel: (text: String, color: Color) {
        guard let entry else { return ("", .clear) }
        if entry.isRaw { return (PhotoKind.raw.localizedBadgeName, .orange) }
        let isDev = (xmp?.developed == true) || (exif?.isDeveloped == true)
        if isDev { return (PhotoKind.developed.localizedBadgeName, .green) }
        if let exif = exif, (exif.make ?? "").isEmpty && (exif.model ?? "").isEmpty {
            return (PhotoKind.indeterminate.localizedBadgeName, .purple)
        }
        return (PhotoKind.sooc.localizedBadgeName, Color.primary.opacity(0.4))
    }

    // Displayed image: rendered > high-res preview > thumbnail placeholder.
    private var displayPair: (CGImage, Image.Orientation)? {
        if showRendered, let r = rawRendered { return r }
        if let p = previewImage { return p }
        if let t = thumbnail { return (t, .up) }
        return nil
    }

    var body: some View {
        VStack(spacing: 6) {
            imageArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(entry?.filename ?? "")
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)

            ratingRow
        }
        .task(id: memberID) {
            previewImage = nil
            rawRendered = nil
            showRendered = false
            guard let entry = store.entries[memberID] else { return }
            isLoadingPreview = true
            previewImage = await loadPreview(entry: entry)
            isLoadingPreview = false
            // Auto-render for RAW: show embedded first, then replace.
            // Skip for formats with no full-res JPEG (e.g. CR2) since CIRAWFilter will return nil.
            if entry.isRaw,
               !isLimitedRawPreview,
               SettingsStore.shared.autoRenderRawCompare,
               let db = store.cacheDatabase {
                isRendering = true
                defer { isRendering = false }
                rawRendered = await RAWRenderPipeline.shared.render(
                    url: entry.url, target: .compare, db: db
                )
                if rawRendered != nil { showRendered = true }
            }
        }
    }

    private func loadPreview(entry: PhotoEntry) async -> (CGImage, Image.Orientation)? {
        if entry.isRaw,
           let data = await BridgeCore.extractRawJpeg(url: entry.url, quality: .full) {
            // Use cached orientation to avoid re-opening the RAW file (which allocates extra IOSurfaces).
            let orient = store.thumbnailOrientations[entry.id] ?? .up
            return await LargeImageDecoder.decodeFromData(data, orientation: orient)
        }
        return await LargeImageDecoder.decodeFromURL(entry.url)
    }

    private var imageArea: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let (img, orient) = displayPair {
                    Image(decorative: img, scale: 1.0, orientation: orient)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blur(radius: isLoadingPreview && previewImage == nil ? 8 : 0)
                        .animation(.easeOut(duration: 0.2), value: previewImage == nil)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isFocused ? Color.accentColor : Color.white.opacity(0.12),
                        lineWidth: isFocused ? 2.5 : 1
                    )
            }

            // Top-trailing: file kind badge
            let label = kindLabel
            if !label.text.isEmpty {
                Text(label.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(label.color.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }

            // Bottom-center: limited preview notice for formats with no full-res embedded JPEG
            if isLimitedRawPreview {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.yellow.opacity(0.85))
                        Text(String(localized: "raw.limited.preview.badge",
                                    defaultValue: "Thumbnail only"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .help(String(localized: "raw.limited.preview.tooltip",
                                 defaultValue: "This CR2 file only contains an 18 KB embedded thumbnail. Full-resolution RAW rendering is not supported on macOS 26."))
                    .padding(.bottom, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Top-leading: render status badge (RAW files only)
            if let entry = entry, entry.isRaw {
                Group {
                    if isRendering {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(String(localized: "render.loading", defaultValue: "Rendering…"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    } else if rawRendered != nil {
                        Button {
                            showRendered.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showRendered ? "wand.and.stars.inverse" : "wand.and.stars")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(showRendered
                                     ? String(localized: "render.badge.rendered", defaultValue: "Rendered")
                                     : String(localized: "render.badge.embedded", defaultValue: "Embedded"))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(showRendered
                              ? String(localized: "render.toggle.embedded", defaultValue: "Show embedded preview")
                              : String(localized: "render.toggle.rendered", defaultValue: "Show rendered preview"))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var ratingRow: some View {
        HStack(spacing: 4) {
            Button { applyRating(0) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle((xmp?.rating ?? 0) > 0 ? Color.red.opacity(0.75) : Color.white.opacity(0.2))
            }
            .buttonStyle(.plain)

            ForEach(1...5, id: \.self) { n in
                let filled = n <= (xmp?.rating ?? 0)
                Button { applyRating(n) } label: {
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.system(size: 22))
                        .foregroundStyle(filled ? Color.yellow : Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }

        }
        .padding(.vertical, 4)
    }

    private func applyRating(_ n: Int) {
        store.selectEntry(memberID)
        store.applyRating(n)
    }
}

