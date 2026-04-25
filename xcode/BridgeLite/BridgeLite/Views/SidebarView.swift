import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store

    var selectedEntry: PhotoEntry? {
        store.selectedID.flatMap { store.entries[$0] }
    }

    var previewImage: CGImage? {
        store.selectedID.flatMap { store.thumbnailImages[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PreviewImageView(image: previewImage)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipped()

                if let entry = selectedEntry {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("File", value: entry.filename)
                            LabeledContent("Size", value: entry.formattedFileSize)
                            LabeledContent("Type", value: entry.fileExtension)
                        }
                        .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)

                    ExifSectionView(entryID: entry.id)
                    XmpSectionView(entryID: entry.id)
                }
            }
        }
        .frame(minWidth: 260)
    }
}

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

struct ExifSectionView: View {
    let entryID: UInt64
    @Environment(LibraryStore.self) private var store

    var exif: ExifData? { store.exifData[entryID] }

    var body: some View {
        GroupBox("EXIF") {
            VStack(alignment: .leading, spacing: 4) {
                if let exif {
                    if let cam = exif.cameraName {
                        LabeledContent("Camera", value: cam)
                    }
                    if let dt = exif.datetime {
                        LabeledContent("Date", value: dt)
                    }
                    if let exp = exif.exposureTime {
                        LabeledContent("Exposure", value: exp)
                    }
                    if let fn = exif.fnumber {
                        LabeledContent("F-Number", value: fn)
                    }
                    if let iso = exif.iso {
                        LabeledContent("ISO", value: "\(iso)")
                    }
                    if let fl = exif.focalLength {
                        LabeledContent("Focal", value: fl)
                    }
                    if let res = exif.resolutionString {
                        LabeledContent("Resolution", value: res)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

struct XmpSectionView: View {
    let entryID: UInt64
    @Environment(LibraryStore.self) private var store

    var xmp: XmpData? { store.xmpData[entryID] }

    var body: some View {
        GroupBox("Rating") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0...5, id: \.self) { n in
                        Image(systemName: n == 0 ? "xmark.circle" : (n <= (xmp?.rating ?? 0) ? "star.fill" : "star"))
                            .foregroundStyle(n == 0 ? Color.red.opacity(0.7) : Color.yellow.opacity(0.8))
                            .onTapGesture { store.applyRating(n) }
                    }
                }
                HStack(spacing: 6) {
                    ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                        Circle()
                            .fill(label.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().stroke(
                                    xmp?.label == label ? Color.primary : Color.clear,
                                    lineWidth: 2
                                )
                            )
                            .onTapGesture { store.applyLabel(label.rawValue) }
                    }
                }
                HStack(spacing: 8) {
                    Button(xmp?.flag == .pick ? "✓ Pick" : "Pick") { store.togglePick() }
                        .foregroundStyle(xmp?.flag == .pick ? Color.accentColor : Color.primary)
                    Button(xmp?.flag == .reject ? "✕ Reject" : "Reject") { store.toggleReject() }
                        .foregroundStyle(xmp?.flag == .reject ? Color.red : Color.primary)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}
