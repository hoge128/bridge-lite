import SwiftUI

struct ViewerView: View {
    @Environment(LibraryStore.self) private var store

    var currentImage: CGImage? {
        store.selectedID.flatMap { store.thumbnailImages[$0] }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = currentImage {
                Image(decorative: img, scale: 1.0)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }

            VStack {
                HStack {
                    Button("Close") { store.viewerMode = false }
                        .keyboardShortcut(.escape, modifiers: [])
                        .padding()
                    Spacer()
                    HStack(spacing: 16) {
                        Button("Prev") { store.navigatePrev() }
                            .keyboardShortcut(.leftArrow, modifiers: [])
                        Button("Next") { store.navigateNext() }
                            .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}
