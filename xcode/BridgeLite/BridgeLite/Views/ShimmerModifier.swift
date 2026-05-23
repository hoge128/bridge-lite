import SwiftUI

/// ローディング中の骨格プレースホルダーに波打つハイライトを重ねる modifier。
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear,               location: 0.0),
                        .init(color: .white.opacity(0.28), location: 0.5),
                        .init(color: .clear,               location: 1.0),
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
