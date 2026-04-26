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
                    // Variation strip — only when group has multiple members
                    if let members = store.shotGroups[entry.shotId], members.count > 1 {
                        VariationStripView(selectedID: entry.id, members: members)
                    }

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

            let badge = isDev ? "DEV" : (entry.isRaw ? "R" : "J")
            Text(badge)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isDev ? Color.white : Color.primary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background {
                    if isDev {
                        RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.8))
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(.ultraThinMaterial)
                    }
                }
                .padding(2)
        }
        .onTapGesture { store.selectEntry(entry.id) }
    }
}

// MARK: - EXIF

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

// MARK: - XMP

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
