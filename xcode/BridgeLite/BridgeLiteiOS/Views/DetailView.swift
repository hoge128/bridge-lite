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
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            // 画像
            if let data = thumbnails[entry.id],
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // メンバー切り替えタブ（グループに複数ある場合）
            if members.count > 1 {
                memberStrip
            }

            // レーティングバー
            ratingBar(entry: entry)
                .background(.ultraThinMaterial)
        }
    }

    private var memberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(members.enumerated()), id: \.element.id) { idx, member in
                    Button {
                        currentIndex = idx
                    } label: {
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
                                    .fill(Color(.systemGray4))
                                    .frame(width: 44, height: 44)
                            }
                            Text(member.fileExtension)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(idx == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
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
                await BridgeCore.writeXmp(
                    url: entry.url,
                    xmp: newXmp,
                    db: db,
                    jpgWriteMode: .sidecar,
                    captionPresent: false
                )
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
