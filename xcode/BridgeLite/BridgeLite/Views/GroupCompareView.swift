import CoreGraphics
import SwiftUI

struct GroupCompareView: View {
    @Environment(LibraryStore.self) private var store
    @State private var currentRepID: UInt64
    @State private var imageFilesOnly: Bool = false

    init(initialID: UInt64) {
        _currentRepID = State(initialValue: initialID)
    }

    private var allGroupMembers: [UInt64] {
        guard let entry = store.entries[currentRepID],
              let members = store.shotGroups[entry.shotId],
              members.count > 1 else {
            return [currentRepID]
        }
        return members.sorted {
            let da = store.entries[$0]?.createdDate ?? .distantPast
            let db = store.entries[$1]?.createdDate ?? .distantPast
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

                HStack(alignment: .top, spacing: 8) {
                    ForEach(groupMembers, id: \.self) { memberID in
                        CompareMemberColumn(
                            memberID: memberID,
                            isFocused: store.primaryID == memberID
                        )
                        .onTapGesture { store.selectEntry(memberID) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity)
            }
        }
        .background {
            Group {
                Button("") {
                    if store.primaryID != nil { store.viewerMode = true }
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
            Button("閉じる") { closeCompare() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.8))

            Spacer()

            if let idx = store.visibleIDs.firstIndex(of: currentRepID) {
                Text("\(idx + 1) / \(store.visibleIDs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { imageFilesOnly.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: imageFilesOnly ? "photo.fill" : "photo")
                    Text(store.settings.language == "ja" ? "画像のみ" : "Image only")
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
                        navMode == .memberFirst ? "メンバー" : "グループ",
                        systemImage: navMode == .memberFirst ? "rectangle.stack" : "arrow.left.and.right"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.7))
                .help(navMode == .memberFirst
                      ? "←→: メンバー移動 / Ctrl+Tab: グループ移動"
                      : "←→: グループ移動 / Ctrl+Tab: メンバー移動")

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
            members = group.sorted {
                let da = store.entries[$0]?.createdDate ?? .distantPast
                let db = store.entries[$1]?.createdDate ?? .distantPast
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

    private func closeCompare() {
        store.selectEntry(currentRepID)
        store.compareMode = false
    }
}

// MARK: - Column

private struct CompareMemberColumn: View {
    let memberID: UInt64
    let isFocused: Bool
    @Environment(LibraryStore.self) private var store
    @State private var previewImage: CGImage?
    @State private var isLoadingPreview = false

    private var entry: PhotoEntry? { store.entries[memberID] }
    private var thumbnail: CGImage? { store.thumbnailImages[memberID] }
    private var xmp: XmpData? { store.xmpData[memberID] }
    private var exif: ExifData? { store.exifData[memberID] }

    private var isJa: Bool { store.settings.language == "ja" }

    private var kindLabel: (text: String, color: Color) {
        guard let entry else { return ("", .clear) }
        if entry.isRaw { return ("RAW", .orange) }
        let isDev = (xmp?.developed == true) || (exif?.isDeveloped == true)
        if isDev { return (isJa ? "現像済" : "Retouched", .green) }
        return (isJa ? "カメラ出力" : "SOOC", Color.primary.opacity(0.4))
    }

    // Displayed image: high-res preview when ready, thumbnail as placeholder.
    private var displayImage: CGImage? { previewImage ?? thumbnail }

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
            guard let entry = store.entries[memberID] else { return }
            isLoadingPreview = true
            defer { isLoadingPreview = false }
            previewImage = await loadPreview(entry: entry)
        }
    }

    private func loadPreview(entry: PhotoEntry) async -> CGImage? {
        if entry.isRaw {
            if let data = await BridgeCore.extractRawJpeg(url: entry.url, quality: .full),
               let img = CGImage.fromJPEGData(data) {
                return img
            }
        }
        // Non-RAW (SOOC JPEG, DNG, etc.): load full resolution
        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }.value
    }

    private var imageArea: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = displayImage {
                    Image(decorative: img, scale: 1.0)
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
