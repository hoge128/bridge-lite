import AppKit
import SwiftUI

/// ローディング中の骨格プレースホルダーに波打つハイライトを重ねる modifier。
///
/// `repeatForever` の CoreAnimation はアプリが背面化しても止まらないため、背面で
/// プレースホルダーが残る（背面化時に suspend() がサムネを evict する）と WindowServer が
/// 常時コンポジットを続け Mission Control 等が重くなる。これを防ぐため、アプリが
/// 非アクティブの間はアニメーションを止め、再アクティブで再開する。
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
                if NSApp?.isActive ?? true { startAnimating() }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in
                startAnimating()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification)) { _ in
                stopAnimating()
            }
    }

    private func startAnimating() {
        withTransaction(Transaction(animation: nil)) { phase = -0.6 }
        withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
            phase = 1.6
        }
    }

    /// repeatForever を打ち切り、アニメーション無しで初期位置に固定する。
    private func stopAnimating() {
        withTransaction(Transaction(animation: nil)) { phase = -0.6 }
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
