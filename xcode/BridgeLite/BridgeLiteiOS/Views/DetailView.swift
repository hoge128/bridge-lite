import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

// iOS 専用のフルサイズデコード用リミッター（IOSurface 枯渇防止）
private let fullResLimiter = ConcurrencyLimiter(maxConcurrent: 1)

private struct FullResEntry: Sendable {
    let id: UInt64
    let image: UIImage
}

struct DetailView: View {
    let groups: [ShotGroup]
    let entries: [UInt64: PhotoEntry]
    let thumbnails: [UInt64: Data]
    let exifs: [UInt64: ExifData]
    @Binding var ratings: [UInt64: XmpData]
    let db: BridgeCoreDatabase?
    let jpgWriteMode: JpgWriteMode
    @Environment(\.dismiss) private var dismiss

    @State private var currentGroupIndex: Int
    @State private var currentIndex: Int
    @State private var swipeDirection = 0
    @State private var isImageZoomed = false
    @State private var isFullscreen = false
    @State private var showRatingPopup = false
    @State private var showEmbedWarning = false
    @State private var pendingWriteEntry: (id: UInt64, url: URL, xmp: XmpData, previousXmp: XmpData?)?

    // フルサイズキャッシュ（最大3枚 FIFO: prev / current / next）
    @State private var fullResCache: [FullResEntry] = []
    @State private var isLoadingFullRes = false

    // RAW レンダリング
    @State private var rawRendered: UIImage? = nil
    @State private var isRendering = false
    @State private var showRendered = false

    private var isLimitedRawPreview: Bool {
        current?.url.pathExtension.lowercased() == "cr2"
    }

    init(groups: [ShotGroup],
         initialGroup: ShotGroup,
         entries: [UInt64: PhotoEntry],
         thumbnails: [UInt64: Data],
         exifs: [UInt64: ExifData],
         ratings: Binding<[UInt64: XmpData]>,
         db: BridgeCoreDatabase?,
         jpgWriteMode: JpgWriteMode = .embed) {
        self.groups = groups
        self.entries = entries
        self.thumbnails = thumbnails
        self.exifs = exifs
        self._ratings = ratings
        self.db = db
        self.jpgWriteMode = jpgWriteMode
        let groupIdx = groups.firstIndex(where: { $0.id == initialGroup.id }) ?? 0
        self._currentGroupIndex = State(initialValue: groupIdx)
        let g = groups.isEmpty ? initialGroup : groups[groupIdx]
        let repIdx = g.representativeID.flatMap { g.memberIDs.firstIndex(of: $0) } ?? 0
        self._currentIndex = State(initialValue: repIdx)
    }

    private var group: ShotGroup { groups[currentGroupIndex] }

    private var members: [PhotoEntry] {
        group.memberIDs.compactMap { entries[$0] }
    }

    private var current: PhotoEntry? { members[safe: currentIndex] }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if let entry = current {
                    VStack(spacing: 0) {
                        ZStack {
                            photoImage(entry: entry)
                                .id(currentGroupIndex)
                                .transition(.asymmetric(
                                    insertion: .move(edge: swipeDirection >= 0 ? .trailing : .leading),
                                    removal: .move(edge: swipeDirection >= 0 ? .leading : .trailing)
                                ))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                        if !isFullscreen {
                            if members.count > 1 {
                                memberStrip
                            }

                            PhotoInfoCard(
                                entry: entry,
                                exif: exifs[entry.id],
                                xmp: ratings[entry.id],
                                thumbnailData: thumbnails[entry.id]
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 88)
                        }
                    }

                    if !isFullscreen {
                        floatingRatingButton(entry: entry)
                            .padding(.bottom, 20)
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 60)
                    .onEnded { value in
                        guard !isImageZoomed else { return }
                        let h = value.translation.height
                        let w = value.translation.width
                        if abs(h) > abs(w) {
                            if h > 60 { dismiss() }
                        } else if w < -60, currentGroupIndex < groups.count - 1 {
                            swipeDirection = 1
                            withAnimation(.easeOut(duration: 0.25)) {
                                currentGroupIndex += 1
                            }
                        } else if w > 60, currentGroupIndex > 0 {
                            swipeDirection = -1
                            withAnimation(.easeOut(duration: 0.25)) {
                                currentGroupIndex -= 1
                            }
                        }
                    }
            )
            .onChange(of: currentIndex) { isImageZoomed = false }
            .onChange(of: currentGroupIndex) {
                currentIndex = group.representativeID.flatMap { group.memberIDs.firstIndex(of: $0) } ?? 0
            }
            .task(id: current?.id) {
                rawRendered = nil
                showRendered = false
                guard let entry = current else { return }
                await loadAndCache(entry: entry)
                prefetchNeighbors()
            }
            .onChange(of: isFullscreen) {
                allowLandscape = isFullscreen
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                scene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: isFullscreen ? .all : .portrait)
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .glassNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        guard let entry = current else { return }
                        let preview = thumbnails[entry.id].flatMap { UIImage(data: $0) }
                        presentShareSheet(urls: [entry.url], previewImage: preview, title: entry.filename)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(current == nil)
                }
            }
            .alert(
                String(localized: "alert.jpg_embed_first.title",
                       defaultValue: "Write Metadata into JPEG?"),
                isPresented: $showEmbedWarning
            ) {
                Button(String(localized: "Yes"), role: .destructive) {
                    UserDefaults.standard.set(true, forKey: JpgMetadataDefaults.hasShownJpgEmbedWarningKey)
                    if let pending = pendingWriteEntry, let db {
                        pendingWriteEntry = nil
                        Task {
                            _ = await BridgeCore.writeXmp(url: pending.url, xmp: pending.xmp,
                                                          db: db, jpgWriteMode: .embed,
                                                          captionPresent: false)
                        }
                    }
                }
                Button(String(localized: "No"), role: .cancel) {
                    cancelPendingWrite()
                }
            } message: {
                Text(String(localized: "alert.jpg_embed_first.message",
                            defaultValue: "Rating will be written directly into the JPEG file. The original file will be modified. You can switch to Sidecar mode in Settings."))
            }
        }
        .statusBarHidden(isFullscreen)
    }

    @ViewBuilder
    private func photoImage(entry: PhotoEntry) -> some View {
        let cached = showRendered ? rawRendered : fullResCache.first(where: { $0.id == entry.id })?.image
        let thumb  = thumbnails[entry.id].flatMap { UIImage(data: $0) }
        let display = cached ?? thumb

        ZStack(alignment: .bottomLeading) {
            if let img = display {
                ZoomableImageView(uiImage: img, isZoomed: $isImageZoomed) {
                    withAnimation(.easeInOut(duration: 0.2)) { isFullscreen.toggle() }
                }
                .id(entry.id)
                .blur(radius: (cached == nil && isLoadingFullRes) ? 8 : 0)
                .opacity((cached == nil && isLoadingFullRes) ? 0.6 : 1.0)
                .animation(.easeOut(duration: 0.2), value: cached == nil)
            } else {
                ProgressView()
            }

            if entry.isRaw && !isFullscreen {
                rawStateBadge(entry: entry)
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func rawStateBadge(entry: PhotoEntry) -> some View {
        if isLimitedRawPreview {
            // 非対応フォーマット
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.85))
                Text(String(localized: "raw.limited.preview.ios.notice",
                            defaultValue: "Embedded thumbnail only — RAW rendering is not supported"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        } else if isRendering {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(String(localized: "render.loading", defaultValue: "Rendering…"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        } else {
            // 埋め込み / レンダリング済 切り替えバッジ
            Button {
                if rawRendered != nil {
                    showRendered.toggle()
                } else {
                    triggerRender(entry: entry)
                }
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
        }
    }

    private var memberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(members.enumerated()), id: \.element.id) { idx, member in
                    Button { currentIndex = idx } label: {
                        VStack(spacing: 2) {
                            if let data = thumbnails[member.id],
                               let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipped()
                            } else {
                                Rectangle()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(width: 44, height: 44)
                            }
                            Text(member.fileExtension)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .padding(3)
                        .adaptiveGlass(cornerRadius: 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(idx == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .adaptiveGlass(cornerRadius: 0)
        .colorScheme(.dark)
    }

    @ViewBuilder
    private func floatingRatingButton(entry: PhotoEntry) -> some View {
        let rating = ratings[entry.id]?.rating ?? 0
        let labelColor = ratings[entry.id]?.label?.color

        Button { showRatingPopup = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: rating > 0 ? "star.fill" : "star")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(rating > 0 ? Color.yellow : Color.white)
                    .frame(width: 56, height: 56)
                if let c = labelColor {
                    Circle()
                        .fill(c)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 2, y: 2)
                }
            }
            .adaptiveGlass(cornerRadius: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Rating and Label"))
        .popover(isPresented: $showRatingPopup) {
            let previousXmp = ratings[entry.id]
            let binding = Binding<XmpData>(
                get: { ratings[entry.id] ?? XmpData() },
                set: { ratings[entry.id] = $0 }
            )
            RatingBarView(entry: entry, xmp: binding) { newXmp in
                guard let db else { return }
                let url = entry.url
                let isJpg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
                if jpgWriteMode == .embed && isJpg
                    && !JpgMetadataDefaults.hasShownJpgEmbedWarning() {
                    pendingWriteEntry = (id: entry.id, url: url, xmp: newXmp, previousXmp: previousXmp)
                    showEmbedWarning = true
                } else {
                    Task {
                        _ = await BridgeCore.writeXmp(url: url, xmp: newXmp, db: db,
                                                      jpgWriteMode: jpgWriteMode,
                                                      captionPresent: false)
                    }
                }
            }
            .padding(8)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func triggerRender(entry: PhotoEntry) {
        guard let db else { return }
        Task {
            isRendering = true
            defer { isRendering = false }
            if let (cgImage, _) = await RAWRenderPipeline.shared.render(
                url: entry.url, target: .viewer, db: db
            ) {
                rawRendered = UIImage(cgImage: cgImage)
                showRendered = true
            }
        }
    }

    private func cancelPendingWrite() {
        guard let pending = pendingWriteEntry else { return }
        pendingWriteEntry = nil
        if let previousXmp = pending.previousXmp {
            ratings[pending.id] = previousXmp
        } else {
            ratings.removeValue(forKey: pending.id)
        }
    }

    // MARK: - Full-resolution loading

    /// キャッシュミス時のみロードし、最大3枚 FIFO で保持する。
    @MainActor
    private func loadAndCache(entry: PhotoEntry) async {
        if fullResCache.contains(where: { $0.id == entry.id }) { return }
        isLoadingFullRes = true
        defer { isLoadingFullRes = false }
        if let img = await decodeFullRes(entry: entry) {
            if fullResCache.count >= 3 { fullResCache.removeFirst() }
            fullResCache.append(FullResEntry(id: entry.id, image: img))
        }
    }

    /// 前後グループの代表画像をバックグラウンドで先読み。
    /// Task は @MainActor context を継承するため、loadAndCache は Main Actor 上で実行される。
    private func prefetchNeighbors() {
        for delta in [-1, 1] {
            let idx = currentGroupIndex + delta
            guard groups.indices.contains(idx) else { continue }
            let g = groups[idx]
            guard let repID = g.representativeID ?? g.memberIDs.first,
                  let entry = entries[repID],
                  !fullResCache.contains(where: { $0.id == entry.id }) else { continue }
            Task(priority: .background) {
                await loadAndCache(entry: entry)
            }
        }
    }

    /// RAW は埋め込み JPEG を抽出（limiter 外）→デコード（limiter 内）。
    /// 非 RAW は URL から直接デコード（limiter 内）。
    /// macOS LargeImageDecoder と同じ構成で IOSurface 枯渇を防ぐ。
    private func decodeFullRes(entry: PhotoEntry) async -> UIImage? {
        let url = entry.url
        if entry.isRaw {
            guard let data = await BridgeCore.extractRawJpeg(url: url, quality: .full) else { return nil }
            return try? await fullResLimiter.run {
                await Task.detached(priority: .userInitiated) {
                    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                    guard let src = CGImageSourceCreateWithData(data as CFData, opts),
                          let cgImg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
                    return UIImage(cgImage: cgImg)
                }.value
            }
        }
        return try? await fullResLimiter.run {
            await Task.detached(priority: .userInitiated) {
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
                      let cgImg = CGImageSourceCreateImageAtIndex(src, 0, opts) else { return nil }
                return UIImage(cgImage: cgImg)
            }.value
        }
    }
}

// MARK: - Info Card

private struct PhotoInfoCard: View {
    let entry: PhotoEntry
    let exif: ExifData?
    let xmp: XmpData?
    let thumbnailData: Data?

    @State private var histogram: RGBHistogram = .empty

    private static let exifFont: Font = .system(.caption2, design: .monospaced)

    // EXIF datetime は "yyyy:MM:dd HH:mm:ss" 固定フォーマット
    private static let exifDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd  HH:mm:ss"
        return f
    }()

    private var fText: String? { exif?.fnumber }
    private var ssText: String? {
        guard let s = exif?.exposureTime else { return nil }
        return s.components(separatedBy: " ").first ?? s
    }
    private var isoText: String? { exif?.iso.map { "ISO \($0)" } }
    private var focalText: String? {
        guard let mm = exif?.effectiveFocalMm else { return nil }
        let v = mm == mm.rounded() ? "\(Int(mm))" : String(format: "%.1f", mm)
        return "\(v) mm"
    }
    private var evText: String? { exif?.exposureBias }
    private var datetimeText: String? {
        guard let raw = exif?.datetime,
              let date = Self.exifDateParser.date(from: raw) else { return exif?.datetime }
        return Self.displayDateFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.filename)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                HStack {
                    Text(exif?.cameraName ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.fileExtension.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Color.white.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                if let lens = exif?.lensName {
                    HStack {
                        Text(lens)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                } else {
                    Spacer().frame(height: 10)
                }

                // Histogram (JPG/SOOC は RGB、RAW は灰色プレースホルダー)
                Color.white.opacity(0.12).frame(height: 0.5)
                Group {
                    if !entry.isRaw && !histogram.isEmpty {
                        RGBHistogramView(histogram: histogram)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.06))
                    }
                }
                .frame(height: 48)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Color.white.opacity(0.12).frame(height: 0.5)

                // ISO | focal | EV | f | SS
                HStack(spacing: 0) {
                    exifCell(isoText)
                    vSep
                    exifCell(focalText)
                    vSep
                    exifCell(evText)
                    vSep
                    exifCell(fText)
                    vSep
                    exifCell(ssText)
                }
                .padding(.vertical, 10)

                Color.white.opacity(0.12).frame(height: 0.5)
                HStack(spacing: 0) {
                    exifCell(datetimeText)
                    vSep
                    exifCell(entry.fileSize > 0 ? entry.formattedFileSize : nil)
                    vSep
                    exifCell(exif?.resolutionString)
                }
                .padding(.vertical, 10)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .task(id: entry.id) {
            guard !entry.isRaw, let data = thumbnailData,
                  let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage else {
                histogram = .empty
                return
            }
            histogram = await computeRGBHistogram(image: cgImage, bins: 64)
        }
    }

    private var vSep: some View {
        Color.white.opacity(0.15).frame(width: 0.5, height: 14)
    }

    private func exifCell(_ value: String?) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(value ?? "—")
                .font(Self.exifFont)
                .foregroundStyle(.white.opacity(value != nil ? 0.92 : 0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - RGB Histogram

private struct RGBHistogram {
    let r: [Int]
    let g: [Int]
    let b: [Int]
    var isEmpty: Bool { r.isEmpty }
    static let empty = RGBHistogram(r: [], g: [], b: [])
}

private struct RGBHistogramView: View {
    let histogram: RGBHistogram

    private var maxVal: Int {
        let all = histogram.r + histogram.g + histogram.b
        return max(all.max() ?? 1, 1)
    }

    var body: some View {
        Canvas { ctx, size in
            guard !histogram.isEmpty else { return }
            let mv = CGFloat(maxVal)
            let n = histogram.r.count
            guard n > 0 else { return }

            func points(_ counts: [Int]) -> [CGPoint] {
                let barW = size.width / CGFloat(n)
                return counts.enumerated().map { i, c in
                    CGPoint(x: (CGFloat(i) + 0.5) * barW,
                            y: size.height - size.height * CGFloat(c) / mv)
                }
            }

            ctx.fill(areaPath(points(histogram.b), size: size), with: .color(.blue.opacity(0.85)))
            ctx.blendMode = .screen
            ctx.fill(areaPath(points(histogram.g), size: size), with: .color(.green.opacity(0.85)))
            ctx.fill(areaPath(points(histogram.r), size: size), with: .color(.red.opacity(0.85)))
        }
        .background(.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func areaPath(_ pts: [CGPoint], size: CGSize) -> Path {
        var ext = [CGPoint(x: 0, y: size.height)]
        ext.append(contentsOf: pts)
        ext.append(CGPoint(x: size.width, y: size.height))
        guard ext.count >= 2 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: ext[0])
        for i in 0..<(ext.count - 1) {
            let (c1, c2) = catmullRomCP(ext, i: i, height: size.height)
            path.addCurve(to: ext[i + 1], control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func catmullRomCP(_ pts: [CGPoint], i: Int, height: CGFloat) -> (CGPoint, CGPoint) {
        let p0 = pts[max(0, i - 1)]
        let p1 = pts[i]
        let p2 = pts[i + 1]
        let p3 = pts[min(pts.count - 1, i + 2)]
        let clamp = { (y: CGFloat) in max(0, min(height, y)) }
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: clamp(p1.y + (p2.y - p0.y) / 6))
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: clamp(p2.y - (p3.y - p1.y) / 6))
        return (c1, c2)
    }
}

private func computeRGBHistogram(image: CGImage, bins: Int) async -> RGBHistogram {
    return await Task.detached(priority: .utility) {
        let maxSide = 1024
        let srcW = image.width, srcH = image.height
        let scale = CGFloat(maxSide) / CGFloat(max(srcW, srcH))
        let w = max(1, Int(CGFloat(srcW) * scale))
        let h = max(1, Int(CGFloat(srcH) * scale))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue
        var raw = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &raw, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return .empty }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            b[min(Int(raw[i])     * bins / 256, bins - 1)] += 1
            g[min(Int(raw[i + 1]) * bins / 256, bins - 1)] += 1
            r[min(Int(raw[i + 2]) * bins / 256, bins - 1)] += 1
        }
        return RGBHistogram(r: r, g: g, b: b)
    }.value
}

// MARK: - Zoomable Image

private struct ZoomableImageView: View {
    let uiImage: UIImage
    @Binding var isZoomed: Bool
    var onSingleTap: (() -> Void)? = nil

    @GestureState private var liveScale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragBase: CGSize = .zero
    @State private var lastTap: (location: CGPoint, time: Date)? = nil

    private var displayScale: CGFloat { max(1.0, baseScale * liveScale) }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .scaleEffect(displayScale, anchor: .center)
                .offset(offset)
                .clipped()
                .gesture(
                    MagnificationGesture()
                        .updating($liveScale) { v, s, _ in s = v }
                        .onEnded { v in
                            baseScale = max(1.0, baseScale * v)
                            if baseScale <= 1.0 {
                                baseScale = 1.0
                                isZoomed = false
                                withAnimation(.easeOut(duration: 0.15)) {
                                    offset = .zero
                                    dragBase = .zero
                                }
                            } else {
                                isZoomed = true
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard baseScale > 1 else { return }
                            offset = CGSize(
                                width: dragBase.width + v.translation.width,
                                height: dragBase.height + v.translation.height
                            )
                        }
                        .onEnded { _ in dragBase = offset }
                )
                .gesture(
                    SpatialTapGesture(count: 1)
                        .onEnded { value in
                            let location = value.location
                            let now = Date()
                            if let last = lastTap, now.timeIntervalSince(last.time) < 0.3 {
                                lastTap = nil
                                handleDoubleTap(at: last.location, in: geo.size)
                            } else {
                                lastTap = (location: location, time: now)
                                let tapTime = now
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    guard let t = lastTap,
                                          abs(t.time.timeIntervalSince(tapTime)) < 0.01 else { return }
                                    lastTap = nil
                                    onSingleTap?()
                                }
                            }
                        }
                )
        }
    }

    private func handleDoubleTap(at location: CGPoint, in size: CGSize) {
        if baseScale <= 1.0 {
            let target: CGFloat = 3.0
            let dx = (size.width  / 2 - location.x) * (target - 1)
            let dy = (size.height / 2 - location.y) * (target - 1)
            isZoomed = true
            withAnimation(.easeOut(duration: 0.25)) {
                baseScale = target
                offset = CGSize(width: dx, height: dy)
                dragBase = offset
            }
        } else {
            isZoomed = false
            withAnimation(.easeOut(duration: 0.2)) {
                baseScale = 1.0
                offset = .zero
                dragBase = .zero
            }
        }
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
