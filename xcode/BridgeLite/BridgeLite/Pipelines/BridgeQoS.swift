import Foundation

/// バックグラウンドスキャン・レンダリング処理の QoS ポリシー一元管理。
///
/// 通常モード: .utility — 他アプリへの影響を最小化（macOS がバックグラウンド処理として扱う）
/// Burst Mode: .userInitiated — 最大スループット優先（スキャン速度を重視するとき）
///
/// - Note: 並列度のハードコード値（ThumbnailPipeline.limiter 等）は static let で初期化済み。
///   Burst Mode UI 実装後に xmpConcurrency 等を参照するよう置き換える。
enum BridgeQoS {
    static var scan: TaskPriority {
        SettingsStore.shared.burstMode ? .userInitiated : .utility
    }
    static var thumbnail: TaskPriority {
        SettingsStore.shared.burstMode ? .userInitiated : .utility
    }
    static var rawRender: TaskPriority {
        SettingsStore.shared.burstMode ? .userInitiated : .utility
    }
    // 通常: 3、Burst: 8（xmpLimiter は毎スキャン時に参照するため動的に効く）
    static var xmpConcurrency: Int {
        SettingsStore.shared.burstMode ? 8 : 3
    }
}
