import AppKit
import Foundation
import SwiftUI

/// 軽量なヒント（Tips）システム。
///
/// 設定変更で体験が改善する状況をアプリが検知したら、**アプリ内バナー**でヒントを
/// 提示する（macOS 通知ではないので通知許可は不要）。スパムを避けるため「起動毎
/// 1 回 + クールダウン日数」でレート制限し、`SettingsStore.showHints` のマスター
/// トグルで一括無効化できる。
///
/// 新しいヒントを足すときは `Hint` に case と表示文字列（ja/en）を追加するだけ。
/// 発火条件は各検知元（例: ThumbnailDecodeCache の eviction）から `fire(_:)` を呼ぶ。
/// バナー描画は `HintBannerView` が `current` を監視して行う。
@MainActor
@Observable
final class HintCenter {
    static let shared = HintCenter()

    /// 同じヒントを再表示するまでのクールダウン（起動をまたいだ抑制）。
    /// 本番は 1 時間。これより短い間隔の連発は「1 起動 1 回」ラッチ側で防ぐ。
    private static let cooldown: TimeInterval = 60 * 60

    /// 現在表示中のヒント。nil ならバナー非表示。`HintBannerView` が監視する。
    private(set) var current: Hint?

    /// この起動セッション中に既に出したヒント（永続クールダウンに加えての二重抑止）。
    @ObservationIgnored private var shownThisLaunch: Set<String> = []

    enum Hint: String, Identifiable {
        /// サムネイルキャッシュの eviction が多発（= 大量読み込みでワーキングセットが
        /// キャッシュ上限を大きく超過）したときのヒント。
        case cacheThrashing
        /// 初回ダブルクリック時に「Space とダブルクリックの割り当ては入替可能」と案内する。
        /// fireOnce(_:) 経由で一度だけ表示する。
        case openGestureSwap

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .cacheThrashing:
                return String(localized: "hint.cacheThrashing.title",
                              defaultValue: "Loading a lot of files")
            case .openGestureSwap:
                return String(localized: "hint.openGestureSwap.title",
                              defaultValue: "Double-click and Space are customizable")
            }
        }

        var localizedBody: String {
            switch self {
            case .cacheThrashing:
                return String(localized: "hint.cacheThrashing.body",
                              defaultValue: "Raising the thumbnail memory cache makes scrolling smoother. Adjust it in Settings → Performance.")
            case .openGestureSwap:
                return String(localized: "hint.openGestureSwap.body",
                              defaultValue: "By default, double-click opens Compare and Space opens the Viewer. You can swap them in Settings → General → Viewer.")
            }
        }
    }

    private init() {}

    /// 条件成立時に検知元から呼ぶ。レート制限・マスタートグルをまとめて面倒見る。
    func fire(_ hint: Hint) {
        // マスタートグル。
        guard SettingsStore.shared.showHints else { return }
        // 既にバナー表示中なら割り込まない。
        guard current == nil else { return }
        // 起動毎 1 回。
        guard !shownThisLaunch.contains(hint.rawValue) else { return }
        // 起動をまたいだクールダウン。
        let key = Self.lastShownKey(hint)
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if last > 0, now - last < Self.cooldown { return }

        shownThisLaunch.insert(hint.rawValue)
        UserDefaults.standard.set(now, forKey: key)
        current = hint
    }

    /// 一度表示したら以後二度と出さないヒント（初回操作時の案内など）。
    /// クールダウンではなく永続ラッチで管理する。
    func fireOnce(_ hint: Hint) {
        guard SettingsStore.shared.showHints else { return }
        guard current == nil else { return }
        let key = "hintShownOnce.\(hint.rawValue)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        current = hint
    }

    /// バナーを閉じる。
    func dismiss() {
        current = nil
    }

    private static func lastShownKey(_ hint: Hint) -> String { "hintLastShown.\(hint.rawValue)" }
}
