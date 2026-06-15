import SwiftUI

// MARK: - Key badge

private struct KeyBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.20), radius: 0, x: 0, y: 1.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5)
                    )
            )
            .fixedSize()
    }
}

// MARK: - Row

private struct ShortcutRow: View {
    let keys: [String]
    let description: LocalizedStringKey

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    KeyBadge(label: key)
                }
            }
            .frame(width: 160, alignment: .leading)
            Text(description)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Section

private struct ShortcutSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            content()
        }
    }
}

// MARK: - Main view

struct ShortcutCheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    private var ratingKeys: [String] {
        switch SettingsStore.shared.ratingShortcutModifier {
        case .none:    return ["0–5"]
        case .command: return ["⌘", "0–5"]
        case .control: return ["⌃", "0–5"]
        }
    }

    private var labelKeys: [String] {
        switch SettingsStore.shared.ratingShortcutModifier {
        case .none:    return ["6–9"]
        case .command: return ["⌘", "6–9"]
        case .control: return ["⌃", "6–9"]
        }
    }

    private var deleteKeys: [String] {
        switch SettingsStore.shared.deleteShortcutKey {
        case .delete:        return ["⌫"]
        case .commandDelete: return ["⌘", "⌫"]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label(String(localized: "shortcut.sheet.title", defaultValue: "Keyboard Shortcuts"),
                      systemImage: "keyboard")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // View Modes (most important — placed first)
                    ShortcutSection(title: "shortcut.section.view_modes") {
                        ShortcutRow(keys: ["Space"],         description: "shortcut.viewer_enter")
                        ShortcutRow(keys: ["↩ Return"],      description: "shortcut.compare_enter")
                        ShortcutRow(keys: ["Double-click"],  description: "shortcut.compare_enter")
                        ShortcutRow(keys: ["Tab"],           description: "shortcut.cycle_variant")
                        ShortcutRow(keys: ["⇧", "Tab"],      description: "shortcut.cycle_variant_reverse")
                        ShortcutRow(keys: ["Esc"],           description: "shortcut.exit_mode")
                        ShortcutRow(keys: ["F"],             description: "shortcut.toggle_filters")
                        ShortcutRow(keys: ["I"],             description: "shortcut.toggle_metadata")
                    }

                    Divider().padding(.vertical, 10)

                    // Compare mode
                    ShortcutSection(title: "shortcut.section.compare") {
                        ShortcutRow(keys: ["⌃", "Tab"],      description: "shortcut.compare_next")
                        ShortcutRow(keys: ["⌃", "⇧", "Tab"], description: "shortcut.compare_prev")
                    }

                    Divider().padding(.vertical, 10)

                    // Navigation
                    ShortcutSection(title: "shortcut.section.navigation") {
                        ShortcutRow(keys: ["←", "→"],        description: "shortcut.nav_prev_next")
                        ShortcutRow(keys: ["↑", "↓"],        description: "shortcut.nav_up_down")
                        ShortcutRow(keys: ["⇧ ←↑→↓"],       description: "shortcut.nav_range")
                        ShortcutRow(keys: ["⌘", "←", "→"],   description: "shortcut.nav_jump")
                    }

                    Divider().padding(.vertical, 10)

                    // Selection
                    ShortcutSection(title: "shortcut.section.selection") {
                        ShortcutRow(keys: ["⌘", "A"],        description: "shortcut.select_all")
                        ShortcutRow(keys: ["⌘", "⌥", "A"],  description: "shortcut.deselect_all")
                    }

                    Divider().padding(.vertical, 10)

                    // Rating & Labels
                    ShortcutSection(title: "shortcut.section.rating") {
                        ShortcutRow(keys: ratingKeys,        description: "shortcut.rating_stars")
                        ShortcutRow(keys: labelKeys,         description: "shortcut.rating_label")
                        ShortcutRow(keys: ["P"],             description: "shortcut.flag_pick")
                        ShortcutRow(keys: ["X"],             description: "shortcut.flag_reject")
                    }

                    Divider().padding(.vertical, 10)

                    // File
                    ShortcutSection(title: "shortcut.section.file") {
                        ShortcutRow(keys: ["⌘", "C"],        description: "shortcut.copy")
                        ShortcutRow(keys: deleteKeys,        description: "shortcut.trash")
                        ShortcutRow(keys: ["⌘", "Z"],        description: "shortcut.undo")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: 600)
    }
}

#Preview {
    ShortcutCheatSheetView()
}
