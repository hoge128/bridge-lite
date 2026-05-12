import AppKit
import Combine
import SwiftUI

struct ThumbnailCellView: View {
    let entry: PhotoEntry
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false
    @State private var dragSource = CellDragSource()
    @State private var dragInFlight = false

    // @State で自分の id 分だけ保持し、dict 全体への @Observable 依存を排除
    @State private var thumbnail: CGImage? = nil
    @State private var thumbnailOrientation: Image.Orientation = .up
    @State private var xmp: XmpData? = nil
    @State private var exif: ExifData? = nil
    @State private var duplicateCount: Int = 0
    @State private var isRecommendedOriginal: Bool = false

    private var cellSize: CGFloat { store.settings.thumbnailSize }
    private var isSelected: Bool { store.selectedIDs.contains(entry.id) }

    private var photoKind: PhotoKind {
        if entry.isRaw { return .raw }
        if entry.hasDevelopedSuffix || (xmp?.developed == true) || (exif?.isDeveloped == true) { return .developed }
        if let exif = exif, (exif.make ?? "").isEmpty && (exif.model ?? "").isEmpty { return .indeterminate }
        return .sooc
    }

    private var identifierText: String { photoKind.localizedBadgeName }

    var body: some View {
        strictBody
    }

    // MARK: - Strict mode (square tile sized by slider, filename + rating below)

    private var strictBody: some View {
        VStack(spacing: 4) {
            ZStack {
                // scaledToFit でアスペクト比が合わない場合に生じるレターボックス部分の地色
                Color.secondary.opacity(0.08)
                ThumbnailImageView(cgImage: thumbnail, orientation: thumbnailOrientation)
                    .frame(width: cellSize, height: cellSize)
                colorLabelStrip
            }
            .frame(width: cellSize, height: cellSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                identifierBadge
                    .padding(4)
                    .opacity(store.filter.flatten ? 0 : (photoKind == .sooc ? (isHovered ? 1 : 0) : 1))
                    .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
            .overlay(alignment: .bottomLeading) {
                if duplicateCount > 1 {
                    HStack(spacing: 2) {
                        if isRecommendedOriginal {
                            Image(systemName: "star.fill").font(.system(size: 9))
                        }
                        Text("×\(duplicateCount)").font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.85)))
                    .foregroundStyle(.white)
                    .padding(4)
                }
            }
            .overlay { selectionStroke(cornerRadius: 6) }

            HStack(spacing: 3) {
                if let rating = xmp?.rating, rating > 0 {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow.opacity(0.75))
                }
                Text(entry.filename)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: cellSize)
        }
        .onAppear {
            let id = entry.id
            let url = entry.url

            let orient: Image.Orientation = entry.isRaw ? (store.thumbnailOrientations[id] ?? .up) : .up
            thumbnailOrientation = orient
            if let cached = ThumbnailDecodeCache.shared.peek(url: url) {
                thumbnail = cached
            } else if let blob = store.thumbnailBlobs[id] {
                Task { @MainActor in
                    let decoded = await Task.detached(priority: .userInitiated) {
                        ThumbnailDecodeCache.shared.decode(url: url, blob: blob)
                    }.value
                    thumbnail = decoded
                }
            }
            xmp = store.xmpData[id]
            exif = store.exifData[id]
            updateDuplicateBadge()
        }
        .onReceive(store.thumbnailDidUpdate.filter { $0 == self.entry.id }) { _ in
            let id = entry.id
            let url = entry.url
            let blob = store.thumbnailBlobs[id]
            let isRaw = entry.isRaw
            let orient: Image.Orientation = isRaw ? (store.thumbnailOrientations[id] ?? .up) : .up
            Task { @MainActor in
                let decoded = await Task.detached(priority: .userInitiated) {
                    ThumbnailDecodeCache.shared.decode(url: url, blob: blob)
                }.value
                thumbnail = decoded
                if isRaw { thumbnailOrientation = orient }
            }
        }
        .onReceive(store.exifDidUpdate.filter { $0 == self.entry.id }) { _ in
            exif = store.exifData[entry.id]
        }
        .onReceive(store.xmpDidUpdate.filter { $0 == self.entry.id }) { _ in
            xmp = store.xmpData[entry.id]
        }
        .onReceive(store.duplicateDidUpdate.filter { $0 == self.entry.id }) { _ in
            updateDuplicateBadge()
        }
        .onHover { isHovered = $0 }
        .contextMenu { cellContextMenu }
        .background { CellDragBackingView(source: dragSource) }
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    guard !dragInFlight, let event = NSApp.currentEvent else { return }
                    dragInFlight = true
                    let ids = store.selectedIDs.contains(entry.id) ? store.selectedIDs : [entry.id]
                    let scope = resolveDndScope()
                    dragSource.urlsProvider = { self.store.urlsFor(ids: ids, scope: scope) }
                    let img = thumbnail ?? ThumbnailDecodeCache.shared.decode(
                        url: entry.url, blob: store.thumbnailBlobs[entry.id]
                    )
                    let preview = img.map {
                        NSImage(cgImage: $0, size: NSSize(width: cellSize, height: cellSize))
                    }
                    dragSource.begin(event: event, cellSize: cellSize, preview: preview)
                }
                .onEnded { _ in dragInFlight = false }
        )
    }

    // MARK: - Shared sub-views

    @ViewBuilder
    private var colorLabelStrip: some View {
        if let label = xmp?.label {
            VStack(spacing: 0) {
                Spacer()
                label.color.opacity(0.85).frame(height: 5)
            }
        }
    }

    @ViewBuilder
    private var identifierBadge: some View {
        let kind = photoKind
        Text(identifierText)
            .font(.caption2.bold())
            .foregroundStyle(kind == .sooc ? Color.primary : Color.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                switch kind {
                case .sooc:
                    RoundedRectangle(cornerRadius: 3).fill(.ultraThinMaterial)
                case .raw:
                    RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.8))
                case .developed:
                    RoundedRectangle(cornerRadius: 3).fill(Color.green.opacity(0.8))
                case .indeterminate:
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.8))
                }
            }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var cellContextMenu: some View {
        Button("Copy") {
            if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
            store.triggerCopy()
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }

        let targetURLs: [URL] = {
            if !store.selectedIDs.contains(entry.id) { return [entry.url] }
            return store.selectedIDs.compactMap { store.entries[$0]?.url }
        }()
        let primaryURL = store.entries[store.primaryID ?? entry.id]?.url ?? entry.url
        OpenWithMenu(targetURLs: targetURLs, primaryURL: primaryURL)

        Divider()

        Menu("Rating") {
            Button("No Rating") {
                if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                store.triggerRating(0)
            }
            ForEach(1...5, id: \.self) { n in
                Button(String(repeating: "★", count: n)) {
                    if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                    store.triggerRating(n)
                }
            }
        }

        Menu("Label") {
            ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                Button(label.name) {
                    if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                    store.applyLabel(label.rawValue)
                }
            }
            Divider()
            Button("Clear Label") {
                if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
                if let current = store.xmpData[store.primaryID ?? entry.id]?.label {
                    store.applyLabel(current.rawValue)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
            store.triggerDelete()
        } label: {
            Text("Move to Trash")
        }
    }

    // MARK: - 重複バッジ更新

    private func updateDuplicateBadge() {
        if let key = store.duplicateKeyByID[entry.id],
           let members = store.duplicateGroups[key], members.count > 1 {
            duplicateCount = members.count
            isRecommendedOriginal = (store.duplicateRecommendedID[key] == entry.id)
        } else {
            duplicateCount = 0
            isRecommendedOriginal = false
        }
    }

    // MARK: - D&D scope

    /// 設定値をベースに、⌥ キーが押されていれば逆スコープを返す。
    private func resolveDndScope() -> GroupScopeMode {
        let base: GroupScopeMode = store.settings.dndScopeMode == .allInGroup ? .allInGroup : .representative
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        guard optionHeld else { return base }
        return base == .representative ? .allInGroup : .representative
    }

    private func selectionStroke(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    isSelected ? Color.accentColor : (isHovered ? Color.secondary.opacity(0.25) : Color.clear),
                    lineWidth: isSelected ? 3.0 : 1.0
                )
            if isSelected {
                RoundedRectangle(cornerRadius: max(0, cornerRadius - 1.5))
                    .stroke(Color.white.opacity(0.55), lineWidth: 1.0)
                    .padding(1.5)
            }
        }
        .animation(.easeInOut(duration: 0.08), value: isSelected)
    }
}

// MARK: - Drag source (AppKit layer)

@MainActor
final class CellDragSource: NSObject, NSDraggingSource {
    var urlsProvider: (() -> [URL])?
    weak var backingView: NSView?

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func begin(event: NSEvent, cellSize: CGFloat, preview: NSImage? = nil) {
        guard let view = backingView,
              let urls = urlsProvider?(), !urls.isEmpty else { return }
        let dragSize = cellSize * 0.4
        let frame = NSRect(origin: .zero, size: CGSize(width: dragSize, height: dragSize))
        let contents = preview.map { borderedPreview($0, size: dragSize) }
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(frame, contents: contents)
            return item
        }
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    private func borderedPreview(_ image: NSImage, size: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)),
                   from: .zero, operation: .copy, fraction: 1.0)
        let path = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: size - 2, height: size - 2),
                                xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        NSColor.white.setStroke()
        path.stroke()
        result.unlockFocus()
        return result
    }
}

private struct CellDragBackingView: NSViewRepresentable {
    let source: CellDragSource

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        source.backingView = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { source.backingView = v }
}

struct ThumbnailImageView: View {
    let cgImage: CGImage?
    var orientation: Image.Orientation = .up

    var body: some View {
        if let img = cgImage {
            Image(decorative: img, scale: 1.0, orientation: orientation)
                .resizable()
                .scaledToFit() // Fill ではなく Fit: タイル内で写真を見切れさせない
                .transition(.opacity)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .font(.title2)
                )
        }
    }
}
