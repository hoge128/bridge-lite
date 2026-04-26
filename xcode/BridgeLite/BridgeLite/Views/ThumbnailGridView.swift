import SwiftUI

struct ThumbnailGridView: View {
    @Environment(LibraryStore.self) private var store
    private let cellSize: CGFloat = 180

    var body: some View {
        GeometryReader { geo in
            let cols = max(2, Int(geo.size.width / (cellSize + 8)))
            let columns = Array(repeating: GridItem(.fixed(cellSize), spacing: 8), count: cols)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(store.visibleIDs, id: \.self) { id in
                        if let entry = store.entries[id] {
                            ThumbnailCellView(entry: entry)
                                .onTapGesture { store.selectEntry(id) }
                        }
                    }
                }
                .padding(8)
            }
        }
        .onKeyPress(.leftArrow)  { store.navigatePrev(); return .handled }
        .onKeyPress(.rightArrow) { store.navigateNext(); return .handled }
        .onKeyPress(.tab)        { store.cyclePairVariant(reverse: false); return .handled }
        .onKeyPress(.space)      {
            if store.selectedID != nil { store.viewerMode = true }
            return .handled
        }
        // Rating: 0-5 stars
        .onKeyPress(characters: CharacterSet(charactersIn: "012345"), phases: .down) { press in
            if let n = Int(press.characters) { store.applyRating(n); return .handled }
            return .ignored
        }
        // Labels: 6=Red 7=Yellow 8=Green 9=Blue
        .onKeyPress(characters: CharacterSet(charactersIn: "6789"), phases: .down) { press in
            let labelMap: [Character: UInt8] = ["6": 1, "7": 2, "8": 3, "9": 4]
            if let ch = press.characters.first, let raw = labelMap[ch] {
                store.applyLabel(raw); return .handled
            }
            return .ignored
        }
        // Pick / Reject
        .onKeyPress(characters: CharacterSet(charactersIn: "pPxX"), phases: .down) { press in
            switch press.characters.lowercased() {
            case "p": store.togglePick();   return .handled
            case "x": store.toggleReject(); return .handled
            default:  return .ignored
            }
        }
    }
}
