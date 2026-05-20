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

    // MARK: - Strict mode (square tile, info strip inside frame)
    // サムネイル上部 + 情報ストリップ下部をすべて cellSize×cellSize の丸枠内に収める

    private static let infoStripHeight: CGFloat = 30

    // ファイル名・評価ストリップ（カラーラベルはサムネイル直下に別配置）
    private var infoStrip: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.filename)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let rating = xmp?.rating, rating > 0 {
                Text(String(repeating: "★", count: rating))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.yellow.opacity(0.75))
            } else {
                Color.clear.frame(height: 11)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .frame(width: cellSize, height: Self.infoStripHeight - 4, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var strictBody: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            VStack(spacing: 0) {
                ThumbnailImageView(cgImage: thumbnail, orientation: thumbnailOrientation)
                    .frame(width: cellSize, height: cellSize - Self.infoStripHeight)
                // カラーラベル帯：サムネイル画像の直下
                Group {
                    if let label = xmp?.label {
                        label.color.opacity(0.85)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: cellSize, height: 4)
                infoStrip
            }
        }
        .frame(width: cellSize, height: cellSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            identifierBadge
                .padding(4)
                .opacity(store.filter.flatten ? 0 : (photoKind == .sooc ? (isHovered ? 1 : 0) : 1))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .overlay { selectionStroke(cornerRadius: 6) }
        .onAppear { loadCell() }
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
        .onHover { isHovered = $0 }
        .contextMenu { cellContextMenu }
        .overlay {
            RightClickOverlay {
                if !store.selectedIDs.contains(entry.id) { store.selectEntry(entry.id) }
            }
        }
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

    // MARK: - Cell state loader

    private func loadCell() {
        thumbnail = nil
        thumbnailOrientation = .up
        xmp = nil
        exif = nil
        let id = entry.id
        let url = entry.url
        thumbnailOrientation = entry.isRaw ? (store.thumbnailOrientations[id] ?? .up) : .up
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
            store.triggerCopy()
        }

        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }

        let targetURLs = store.selectedIDs.compactMap { store.entries[$0]?.url }
        let primaryURL = store.entries[store.primaryID ?? entry.id]?.url ?? entry.url
        OpenWithMenu(targetURLs: targetURLs, primaryURL: primaryURL)

        Divider()

        Menu("Rating") {
            Button("No Rating") { store.triggerRating(0) }
            ForEach(1...5, id: \.self) { n in
                Button(String(repeating: "★", count: n)) { store.triggerRating(n) }
            }
        }

        Menu("Label") {
            ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                Button(label.name) { store.applyLabel(label.rawValue) }
            }
            Divider()
            Button("Clear Label") {
                if let current = store.xmpData[store.primaryID ?? entry.id]?.label {
                    store.applyLabel(current.rawValue)
                }
            }
        }

        Divider()

        Button(String(localized: "viewer.context.move_to_compare",
                      defaultValue: "Move to Compare")) {
            store.selectEntry(entry.id)
            store.compareAnchorID = entry.id
            store.compareMode = true
        }

        Button(String(localized: "thumbnail.context.move_to_viewer",
                      defaultValue: "Move to Viewer")) {
            store.selectEntry(entry.id)
            store.viewerMode = true
        }

        Divider()

        Button(role: .destructive) {
            store.triggerDelete()
        } label: {
            Text("Move to Trash")
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

@MainActor
private final class RightClickOverlayNSView: NSView {
    var onRightMouseDown: (() -> Void)?
    private var isForwarding = false

    // Intercept hit testing only for right-click events; pass through everything else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isForwarding,
              NSApp.currentEvent?.type == .rightMouseDown else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?()
        // Re-dispatch via the normal AppKit pipeline so SwiftUI's contextMenu fires.
        // isForwarding prevents us from intercepting our own re-dispatch.
        isForwarding = true
        defer { isForwarding = false }
        window?.sendEvent(event)
    }
}

private struct RightClickOverlay: NSViewRepresentable {
    var onRightMouseDown: () -> Void

    func makeNSView(context: Context) -> RightClickOverlayNSView {
        let v = RightClickOverlayNSView()
        v.onRightMouseDown = onRightMouseDown
        return v
    }
    func updateNSView(_ v: RightClickOverlayNSView, context: Context) {
        v.onRightMouseDown = onRightMouseDown
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
