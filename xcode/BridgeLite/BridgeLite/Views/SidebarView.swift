import AppKit
import SwiftUI

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
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        GroupBox {
            content()
        } label: {
            Text(title)
                .font(.caption2)
                .kerning(1.2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

// MARK: - Main

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
                    if let members = store.shotGroups[entry.shotId], members.count > 1 {
                        VariationStripView(selectedID: entry.id, members: members)
                    }

                    PosixSectionView(entry: entry)
                    ExifSectionView(entryID: entry.id)
                    XmpSectionView(entryID: entry.id)
                }
            }
        }
        .frame(minWidth: 260)
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
        SectionBox("POSIX") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                MetaRow(key: "Path", value: entry.url.path(percentEncoded: false))
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
    }
}

// MARK: - EXIF

struct ExifSectionView: View {
    let entryID: UInt64
    @Environment(LibraryStore.self) private var store

    var exif: ExifData? { store.exifData[entryID] }

    var body: some View {
        SectionBox("EXIF") {
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
    @Environment(LibraryStore.self) private var store

    var xmp: XmpData? { store.xmpData[entryID] }

    var body: some View {
        SectionBox("XMP") {
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
                HStack(spacing: 12) {
                    Button(action: { store.togglePick() }) {
                        Image(systemName: xmp?.flag == .pick ? "flag.fill" : "flag")
                            .foregroundStyle(xmp?.flag == .pick ? Color.orange : Color.secondary)
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .help("Pick (P)")

                    Button(action: { store.toggleReject() }) {
                        Image(systemName: xmp?.flag == .reject ? "xmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(xmp?.flag == .reject ? Color.red : Color.secondary)
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .help("Reject (X)")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}
