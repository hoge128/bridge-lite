import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Filters")
                    .font(.headline)
                    .padding(.horizontal)

                // Camera
                if !store.availableCameras.isEmpty {
                    GroupBox("Camera") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.availableCameras, id: \.self) { cam in
                                Toggle(cam, isOn: Binding(
                                    get: { !store.filter.excludedCameras.contains(cam) },
                                    set: { on in
                                        if on { store.filter.excludedCameras.remove(cam) }
                                        else  { store.filter.excludedCameras.insert(cam) }
                                    }
                                ))
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }

                // Rating
                GroupBox("Rating") {
                    HStack(spacing: 4) {
                        ForEach(0...5, id: \.self) { n in
                            Button {
                                if store.filter.filterRatings.contains(n) {
                                    store.filter.filterRatings.remove(n)
                                } else {
                                    store.filter.filterRatings.insert(n)
                                }
                            } label: {
                                Image(systemName: n == 0 ? "circle.slash" : (n <= 1 ? "star.fill" : "star"))
                                    .foregroundStyle(
                                        store.filter.filterRatings.contains(n)
                                        ? Color.accentColor : Color.secondary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)

                // Label
                GroupBox("Label") {
                    HStack(spacing: 6) {
                        ForEach(XmpLabel.allCases, id: \.rawValue) { label in
                            Circle()
                                .fill(label.color)
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle().stroke(
                                        store.filter.filterLabels.contains(label)
                                        ? Color.primary : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                                .onTapGesture {
                                    if store.filter.filterLabels.contains(label) {
                                        store.filter.filterLabels.remove(label)
                                    } else {
                                        store.filter.filterLabels.insert(label)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)

                // Flag
                GroupBox("Flag") {
                    HStack(spacing: 8) {
                        ForEach([XmpFlag.pick, XmpFlag.reject], id: \.rawValue) { flag in
                            Button {
                                if store.filter.filterFlags.contains(flag) {
                                    store.filter.filterFlags.remove(flag)
                                } else {
                                    store.filter.filterFlags.insert(flag)
                                }
                            } label: {
                                Text(flag == .pick ? "✓ Pick" : "✕ Reject")
                                    .font(.caption)
                                    .foregroundStyle(
                                        store.filter.filterFlags.contains(flag)
                                        ? Color.accentColor : Color.primary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 8)

                // ISO range
                GroupBox("ISO") {
                    HStack {
                        @Bindable var store = store
                        TextField("Min", text: $store.filter.isoMin)
                            .frame(width: 50)
                        Text("–")
                        TextField("Max", text: $store.filter.isoMax)
                            .frame(width: 50)
                    }
                    .font(.caption)
                }
                .padding(.horizontal, 8)

                Divider()
                    .padding(.horizontal, 8)

                Button("Reset Filters") { store.filter.reset() }
                    .disabled(!store.filter.isActive)
                    .padding(.horizontal, 8)
            }
            .padding(.vertical)
        }
        .frame(minWidth: 180)
    }
}
