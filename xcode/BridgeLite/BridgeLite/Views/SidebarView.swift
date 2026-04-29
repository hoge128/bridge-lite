import AppKit
import SwiftUI

// MARK: - RGB Histogram data

struct RGBHistogram {
    let r: [Int]
    let g: [Int]
    let b: [Int]
    var isEmpty: Bool { r.isEmpty }
    static let empty = RGBHistogram(r: [], g: [], b: [])
}

// MARK: - Shared

struct MetaRow: View {
    let key: String
    let value: String

    var body: some View {
        GridRow {
            Text(key)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: true, vertical: false)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    var isExpanded: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        GroupBox {
            if let b = isExpanded {
                if b.wrappedValue { content() }
            } else {
                content()
            }
        } label: {
            if let b = isExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { b.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: b.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(title)
                            .font(.caption2)
                            .kerning(1.2)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(.caption2)
                    .kerning(1.2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
        }
    }
}

// MARK: - Main

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @State private var highResPreview: CGImage? = nil
    @State private var rgbHistogram: RGBHistogram = .empty
    @State private var gpsCoordinate: (lat: Double, lon: Double)? = nil

    private var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    var body: some View {
        Group {
            if let entry = selectedEntry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        PreviewImageView(image: highResPreview ?? store.thumbnailImages[entry.id])
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipped()

                        Group {
                            if !entry.isRaw, !rgbHistogram.isEmpty {
                                RGBHistogramView(histogram: rgbHistogram)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.08))
                            }
                        }
                        .frame(height: 52)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                        if let members = store.shotGroups[entry.shotId], members.count > 1 {
                            VariationStripView(selectedID: entry.id, members: members)
                        }

                        PosixSectionView(entry: entry)
                        ExifSectionView(entryID: entry.id)
                        if let gps = gpsCoordinate {
                            GpsSectionView(coordinate: gps)
                        }
                        XmpSectionView(entryID: entry.id)
                    }
                }
                .task(id: entry.id) {
                    highResPreview = nil
                    rgbHistogram = .empty
                    gpsCoordinate = nil
                    let url = entry.url
                    let isRaw = entry.isRaw
                    let thumbFallback = store.thumbnailImages[entry.id]
                    if isRaw {
                        if let jpeg = await BridgeCore.extractRawJpeg(url: url, quality: .preview) {
                            highResPreview = CGImage.fromJPEGData(jpeg)
                        }
                    } else {
                        async let preview = ThumbnailPipeline.generateWithImageIO(url: url, maxPixels: 800)
                        async let gps = Self.extractGPS(url: url)
                        let (p, g) = await (preview, gps)
                        highResPreview = p
                        gpsCoordinate = g
                        if let img = p {
                            rgbHistogram = await Self.computeRGBHistogram(image: img, bins: 64)
                        } else if let thumb = thumbFallback {
                            rgbHistogram = await Self.computeRGBHistogram(image: thumb, bins: 64)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("写真を選択してください")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 260)
    }

    private static func extractGPS(url: URL) async -> (lat: Double, lon: Double)? {
        return await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
                  let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
                  let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double
            else { return nil }
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            return (lat: latRef == "S" ? -lat : lat, lon: lonRef == "W" ? -lon : lon)
        }.value
    }

    private static func computeRGBHistogram(image: CGImage, bins: Int) async -> RGBHistogram {
        return await Task.detached(priority: .utility) {
            let side = 256
            let cs = CGColorSpaceCreateDeviceRGB()
            // BGRA little-endian: raw[i]=B, raw[i+1]=G, raw[i+2]=R, raw[i+3]=A
            let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                                   | CGBitmapInfo.byteOrder32Little.rawValue
            var raw = [UInt8](repeating: 0, count: side * side * 4)
            guard let ctx = CGContext(
                data: &raw, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: cs, bitmapInfo: bitmapInfo
            ) else { return .empty }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var r = [Int](repeating: 0, count: bins)
            var g = [Int](repeating: 0, count: bins)
            var b = [Int](repeating: 0, count: bins)
            for i in stride(from: 0, to: side * side * 4, by: 4) {
                b[min(Int(raw[i])     * bins / 256, bins - 1)] += 1
                g[min(Int(raw[i + 1]) * bins / 256, bins - 1)] += 1
                r[min(Int(raw[i + 2]) * bins / 256, bins - 1)] += 1
            }
            return RGBHistogram(r: r, g: g, b: b)
        }.value
    }
}

// MARK: - Preview image

struct PreviewImageView: View {
    let image: CGImage?

    var body: some View {
        if let img = image {
            Image(decorative: img, scale: 1.0)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 220)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .overlay(
                    Image(systemName: "photo.artframe")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                )
        }
    }
}

// MARK: - RGB Histogram (JPG only)

struct RGBHistogramView: View {
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

            // Blue drawn first in normal blend mode
            ctx.fill(areaPath(points(histogram.b), size: size), with: .color(.blue.opacity(0.85)))
            // Green and Red in screen blend mode — overlaps produce cyan/yellow/magenta/white
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

// MARK: - GPS

struct GpsSectionView: View {
    let coordinate: (lat: Double, lon: Double)
    @State private var isExpanded = true

    var body: some View {
        SectionBox("GPS", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    MetaRow(key: "Latitude",  value: formatted(coordinate.lat, axis: .lat))
                    MetaRow(key: "Longitude", value: formatted(coordinate.lon, axis: .lon))
                }
                Button {
                    let s = "maps://?ll=\(coordinate.lat),\(coordinate.lon)"
                    if let url = URL(string: s) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Maps で開く", systemImage: "map")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private enum Axis { case lat, lon }

    private func formatted(_ v: Double, axis: Axis) -> String {
        let a = abs(v)
        let d = Int(a)
        let mf = (a - Double(d)) * 60
        let m = Int(mf)
        let s = (mf - Double(m)) * 60
        let dir = axis == .lat ? (v >= 0 ? "N" : "S") : (v >= 0 ? "E" : "W")
        return String(format: "%d° %d′ %.1f″ %@", d, m, s, dir)
    }
}

// MARK: - Variation Strip

struct VariationStripView: View {
    let selectedID: UInt64
    let members: [UInt64]
    @Environment(LibraryStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(members, id: \.self) { memberId in
                    if let member = store.entries[memberId] {
                        VariationThumbView(entry: member, isSelected: memberId == selectedID)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 66)
        .padding(.top, 8)
    }
}

struct VariationThumbView: View {
    let entry: PhotoEntry
    let isSelected: Bool
    @Environment(LibraryStore.self) private var store

    private var thumbnail: CGImage? { store.thumbnailImages[entry.id] }
    private var isDev: Bool {
        (store.xmpData[entry.id]?.developed == true) ||
        (store.exifData[entry.id]?.isDeveloped == true)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ThumbnailImageView(cgImage: thumbnail)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            let badge = entry.isRaw ? "R" : (isDev ? "DEV" : "J")
            Text(badge)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle((entry.isRaw || isDev) ? Color.white : Color.primary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background {
                    if entry.isRaw {
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.8))
                    } else if isDev {
                        RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.8))
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(.ultraThinMaterial)
                    }
                }
                .padding(2)
        }
        .onTapGesture { store.selectEntry(entry.id) }
        .contextMenu {
            Button("元のファイルを表示") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }
}

// MARK: - POSIX

struct PosixSectionView: View {
    let entry: PhotoEntry
    @State private var showFullPath = false
    @State private var isExpanded = true

    private static let dateStyle: Date.FormatStyle = .dateTime
        .year(.defaultDigits)
        .month(.twoDigits)
        .day(.twoDigits)
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)

    private func fmt(_ date: Date) -> String {
        date.formatted(Self.dateStyle)
    }

    var body: some View {
        SectionBox("POSIX", isExpanded: $isExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Path")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: true, vertical: false)
                        .gridColumnAlignment(.leading)
                    pathValueView
                        .gridColumnAlignment(.leading)
                }
                MetaRow(key: "Size", value: entry.formattedFileSize)
                if let created = entry.createdDate {
                    MetaRow(key: "Created", value: fmt(created))
                }
                if let modified = entry.modifiedDate {
                    MetaRow(key: "Modified", value: fmt(modified))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .onChange(of: entry.id) { _, _ in showFullPath = false }
    }

    @ViewBuilder
    private var pathValueView: some View {
        if showFullPath {
            Text(entry.url.path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { showFullPath = false }
                .help("ダブルクリックで短縮表示")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.filename)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text(entry.url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture(count: 2) { showFullPath = true }
            .help("ダブルクリックでフルパスを表示")
        }
    }
}

// MARK: - EXIF

struct ExifSectionView: View {
    let entryID: UInt64
    @State private var isExpanded = true
    @Environment(LibraryStore.self) private var store

    var exif: ExifData? { store.exifData[entryID] }

    var body: some View {
        SectionBox("EXIF", isExpanded: $isExpanded) {
            if let exif {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    if let cam = exif.cameraName {
                        MetaRow(key: "Camera", value: cam)
                    }
                    if let lens = exif.lensName {
                        MetaRow(key: "Lens", value: lens)
                    }
                    if let dt = exif.datetime {
                        MetaRow(key: "Date", value: dt)
                    }
                    if let exp = exif.exposureTime {
                        MetaRow(key: "Exposure", value: exp)
                    }
                    if let fn = exif.fnumber {
                        MetaRow(key: "F-Number", value: fn)
                    }
                    if let iso = exif.iso {
                        MetaRow(key: "ISO", value: "\(iso)")
                    }
                    if let fl = exif.focalLength {
                        MetaRow(key: "Focal", value: fl)
                    }
                    if let res = exif.resolutionString {
                        MetaRow(key: "Resolution", value: res)
                    }
                    if let sw = exif.software {
                        MetaRow(key: "Software", value: sw)
                    }
                }
            } else {
                Text("—").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

// MARK: - XMP

struct XmpSectionView: View {
    let entryID: UInt64
    @State private var isExpanded = true
    @Environment(LibraryStore.self) private var store

    var xmp: XmpData? { store.xmpData[entryID] }

    var body: some View {
        SectionBox("XMP", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0...5, id: \.self) { n in
                        Image(systemName: n == 0 ? "xmark.circle" : (n <= (xmp?.rating ?? 0) ? "star.fill" : "star"))
                            .foregroundStyle(n == 0 ? Color.red.opacity(0.7) : Color.yellow.opacity(0.8))
                            .onTapGesture { store.applyRating(n) }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                        ZStack {
                            Circle()
                                .fill(label.color)
                                .frame(width: 20, height: 20)
                            if xmp?.label == label {
                                Circle()
                                    .stroke(Color.white.opacity(0.9), lineWidth: 2.5)
                                    .frame(width: 20, height: 20)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .onTapGesture { store.applyLabel(label.rawValue) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}
