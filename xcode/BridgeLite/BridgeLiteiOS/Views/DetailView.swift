import SwiftUI

struct DetailView: View {
    let group: ShotGroup
    let entries: [UInt64: PhotoEntry]
    let thumbnails: [UInt64: Data]
    @Binding var ratings: [UInt64: XmpData]
    let db: BridgeCoreDatabase?
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var showExport = false

    private var members: [PhotoEntry] {
        group.memberIDs.compactMap { entries[$0] }
    }

    private var current: PhotoEntry? { members[safe: currentIndex] }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let entry = current {
                    photoView(entry: entry)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .glassNavigationBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("エクスポート", systemImage: "square.and.arrow.up") {
                            showExport = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showExport) {
                if let entry = current {
                    ExportSheet(urls: [entry.url]) { showExport = false }
                        .presentationDetents([.medium])
                }
            }
        }
    }

    @ViewBuilder
    private func photoView(entry: PhotoEntry) -> some View {
        VStack(spacing: 0) {
            photoImage(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if members.count > 1 {
                memberStrip
            }

            ratingBar(entry: entry)
        }
    }

    @ViewBuilder
    private func photoImage(entry: PhotoEntry) -> some View {
        if let data = thumbnails[entry.id], let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView()
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
    private func ratingBar(entry: PhotoEntry) -> some View {
        let binding = Binding<XmpData>(
            get: { ratings[entry.id] ?? XmpData() },
            set: { ratings[entry.id] = $0 }
        )
        RatingBarView(entry: entry, xmp: binding) { newXmp in
            guard let db else { return }
            Task {
                _ = await BridgeCore.writeXmp(
                    url: entry.url,
                    xmp: newXmp,
                    db: db,
                    jpgWriteMode: .sidecar,
                    captionPresent: false
                )
            }
        }
        .adaptiveGlass(cornerRadius: 0)
        .colorScheme(.dark)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
