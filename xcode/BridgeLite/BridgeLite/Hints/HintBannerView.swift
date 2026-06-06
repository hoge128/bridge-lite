import SwiftUI

/// `HintCenter.current` を監視して、控えめなアプリ内ヒントバナーを上部に表示する。
/// 通知許可は不要。タップで設定を開く／× で閉じる／一定時間で自動的に消える。
struct HintBannerView: View {
    @State private var hints = HintCenter.shared

    /// 自動的に消えるまでの秒数。
    private static let autoDismiss: Duration = .seconds(12)

    var body: some View {
        ZStack(alignment: .top) {
            if let hint = hints.current {
                banner(hint)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // ヒントごとにタイマーを張り直して自動クローズ。
                    .task(id: hint.id) {
                        try? await Task.sleep(for: Self.autoDismiss)
                        guard !Task.isCancelled else { return }
                        hints.dismiss()
                    }
            }
        }
        .animation(.easeOut(duration: 0.22), value: hints.current)
        .allowsHitTesting(hints.current != nil)
    }

    @ViewBuilder
    private func banner(_ hint: HintCenter.Hint) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(hint.localizedTitle)
                    .font(.callout.weight(.semibold))
                Text(hint.localizedBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // SettingsLink は macOS 14+ の公式 API で、Settings シーンを確実に開く。
                // NSApp.sendAction("showSettingsWindow:") は macOS 14 以降で開かないことが
                // あるため使わない。タップ時にバナーも閉じる。
                SettingsLink {
                    Text(String(localized: "hint.action.openSettings",
                                defaultValue: "Open Settings"))
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
                .padding(.top, 2)
                .simultaneousGesture(TapGesture().onEnded { hints.dismiss() })
            }

            Spacer(minLength: 0)

            Button {
                hints.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .modifier(GlassBannerBackground(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .frame(maxWidth: 460)
    }
}

/// バナー背景。macOS 26+ では Liquid Glass（`.glassEffect`）、旧 OS は従来の
/// Material にフォールバックする。Glass はハイライト枠・影を自前で描くので、
/// フォールバック時のみ手動で stroke/shadow を足す。
private struct GlassBannerBackground: ViewModifier {
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}
