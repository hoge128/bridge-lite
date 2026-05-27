import SwiftUI

extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

// MARK: - View + Glass

extension View {
    /// コンテンツの背景に Liquid Glass を適用する。
    /// iOS 26+: glassEffect / iOS 18–25: ultraThinMaterial フォールバック
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// iOS 26 ではナビゲーションバーを自動 Glass に委ねる。
    /// iOS 18–25 では ultraThinMaterial を明示的に設定する。
    @ViewBuilder
    func glassNavigationBar() -> some View {
        if #available(iOS 26, *) {
            self
                .toolbarBackground(.automatic, for: .navigationBar)
        } else {
            self
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

// MARK: - GlassButton

/// iOS 26: .glass / iOS 18–25: .bordered へフォールバックするボタンスタイル
struct AdaptiveGlassButtonStyle: ButtonStyle {
    var isActive: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, isActive: isActive)
    }

    private struct GlassButtonBody: View {
        let configuration: Configuration
        let isActive: Bool

        var body: some View {
            if #available(iOS 26, *) {
                configuration.label
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .glassEffect(.regular.interactive(true), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(
                                isActive ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                                lineWidth: isActive ? 1 : 0.5
                            )
                    )
                    .opacity(configuration.isPressed ? 0.7 : 1)
                    .scaleEffect(configuration.isPressed ? 0.98 : 1)
            } else {
                configuration.label
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        isActive
                            ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                            : AnyShapeStyle(Color(.systemGray5))
                        , in: Capsule()
                    )
                    .overlay(Capsule().stroke(isActive ? Color.accentColor : Color(.systemGray3), lineWidth: 1))
                    .opacity(configuration.isPressed ? 0.7 : 1)
            }
        }
    }
}

extension ButtonStyle where Self == AdaptiveGlassButtonStyle {
    static var adaptiveGlass: AdaptiveGlassButtonStyle { AdaptiveGlassButtonStyle() }
    static func adaptiveGlass(isActive: Bool) -> AdaptiveGlassButtonStyle {
        AdaptiveGlassButtonStyle(isActive: isActive)
    }
}

/// プロミネントな Glass ボタン（ウェルカム画面の CTA など）
extension View {
    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Shimmer

/// ローディング中の骨格プレースホルダーに波打つハイライトを重ねる modifier。
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear,                  location: 0.0),
                        .init(color: .white.opacity(0.28),    location: 0.5),
                        .init(color: .clear,                  location: 1.0),
                    ],
                    startPoint: UnitPoint(x: phase - 0.35, y: 0.5),
                    endPoint:   UnitPoint(x: phase + 0.35, y: 0.5)
                )
                .blendMode(.overlay)
                .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.6
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }

    @ViewBuilder
    func shimmer(when enabled: Bool) -> some View {
        if enabled { modifier(ShimmerModifier()) } else { self }
    }
}
