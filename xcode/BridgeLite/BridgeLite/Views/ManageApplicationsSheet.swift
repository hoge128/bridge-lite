import SwiftUI
import AppKit

struct ManageApplicationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                if settings.favoriteApps.isEmpty {
                    Text("No favorite applications yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.favoriteApps, id: \.path) { app in
                        row(for: app)
                    }
                    .onMove { src, dst in
                        settings.favoriteApps.move(fromOffsets: src, toOffset: dst)
                    }
                    .onDelete { offsets in
                        settings.favoriteApps.remove(atOffsets: offsets)
                    }
                }
            }
            .navigationTitle("Manage Applications")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Application…") {
                        if let app = OpenWithService.presentAddApplicationPanel(),
                           !settings.favoriteApps.contains(app) {
                            settings.favoriteApps.append(app)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder
    private func row(for app: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: app.path)
        HStack(spacing: 8) {
            Image(nsImage: OpenWithService.applicationIcon(at: app))
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(OpenWithService.applicationName(at: app))
                    .foregroundStyle(exists ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
                Text(app.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !exists {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button(role: .destructive) {
                settings.favoriteApps.removeAll { $0 == app }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
