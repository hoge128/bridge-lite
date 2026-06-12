import AppKit
import Foundation
import SwiftUI

enum FilterSection: String, CaseIterable, Codable, Identifiable {
    case fileType, camera, artist, lens, rating, label, flag
    case iso, focal, shutter, aperture, date, luminance

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .fileType:   return String(localized: "File Type")
        case .camera:     return String(localized: "Camera")
        case .artist:     return String(localized: "Photographer")
        case .lens:       return String(localized: "Lens")
        case .rating:     return String(localized: "Rating")
        case .label:      return String(localized: "Label")
        case .flag:       return String(localized: "Flag")
        case .iso:        return String(localized: "ISO")
        case .focal:      return String(localized: "Focal Length")
        case .shutter:    return String(localized: "Shutter")
        case .aperture:   return String(localized: "Aperture")
        case .date:       return String(localized: "Date")
        case .luminance:  return String(localized: "Luminance")
        }
    }
}

// [BETA DISABLED] .daily はスキャン中フリーズ未解決のため UI から非公開。
// ViewModePicker を ToolbarView に戻すことで再有効化できる。
enum ViewMode: String, CaseIterable {
    case all, daily
}

enum CompareNavMode: String {
    case memberFirst  // ←→ = グループ内メンバー移動 / Ctrl+Tab = グループ間移動
    case groupFirst   // ←→ = グループ間移動 / Ctrl+Tab = グループ内メンバー移動
}

enum GroupScopeMode: String, CaseIterable, Identifiable {
    case allInGroup
    case representative
    case askEachTime

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .allInGroup:   return String(localized: "Entire group")
        case .representative: return String(localized: "Representative")
        case .askEachTime:  return String(localized: "Ask each time")
        }
    }
}

enum RatingShortcutModifier: String, CaseIterable, Identifiable {
    case none, command, control

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .none:    return String(localized: "shortcut.modifier.none", defaultValue: "Number keys (0–9)")
        case .command: return String(localized: "shortcut.modifier.command", defaultValue: "⌘ + Number (⌘0–⌘9)")
        case .control: return String(localized: "shortcut.modifier.control", defaultValue: "⌃ + Number (⌃0–⌃9)")
        }
    }

    var nsEventModifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .none:    return []
        case .command: return .command
        case .control: return .control
        }
    }

    var swiftUIModifiers: SwiftUI.EventModifiers {
        switch self {
        case .none:    return []
        case .command: return .command
        case .control: return .control
        }
    }
}

enum DeleteShortcutKey: String, CaseIterable, Identifiable {
    case delete
    case commandDelete

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .delete:        return String(localized: "shortcut.delete.plain",   defaultValue: "⌫ Delete")
        case .commandDelete: return String(localized: "shortcut.delete.command", defaultValue: "⌘⌫ Command+Delete")
        }
    }
}

enum JpgWriteMode: String, CaseIterable, Identifiable {
    case embed, sidecar

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .embed:   return String(localized: "jpg_write_mode.embed",   defaultValue: "Embed")
        case .sidecar: return String(localized: "jpg_write_mode.sidecar", defaultValue: "Sidecar")
        }
    }
}

enum JpgSidecarConflictPolicy: String, CaseIterable, Identifiable {
    case ask, alwaysPropagate, neverPropagate

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .ask:             return String(localized: "jpg_conflict_policy.ask",              defaultValue: "Ask each time")
        case .alwaysPropagate: return String(localized: "jpg_conflict_policy.always_propagate", defaultValue: "Always propagate")
        case .neverPropagate:  return String(localized: "jpg_conflict_policy.never_propagate",  defaultValue: "Never propagate")
        }
    }
}

enum SortKey: String, CaseIterable {
    case filename, createdDate, modifiedDate, fileSize, rating, exifDate

    var localizedName: String {
        switch self {
        case .filename:     return String(localized: "sort.filename", defaultValue: "Filename")
        case .createdDate:  return String(localized: "sort.created_date", defaultValue: "Created")
        case .modifiedDate: return String(localized: "sort.modified_date", defaultValue: "Modified")
        case .fileSize:     return String(localized: "sort.file_size", defaultValue: "Size")
        case .rating:       return String(localized: "sort.rating", defaultValue: "Rating")
        case .exifDate:     return String(localized: "sort.exif_date", defaultValue: "Shot Date")
        }
    }
}

/// 写真種別ペアごとに評価/ラベルの伝播可否を管理する。
/// 対角 (同種 → 同種) は常に true のためフィールドを持たない。
struct PropagationMatrix: Sendable, Equatable {
    var soocToRaw:       Bool
    var soocToDeveloped: Bool
    var rawToSooc:       Bool
    var rawToDeveloped:  Bool
    var developedToSooc: Bool
    var developedToRaw:  Bool

    func targets(for source: PhotoKind) -> Set<PhotoKind> {
        var result: Set<PhotoKind> = [source]
        switch source {
        case .sooc:
            if soocToRaw       { result.insert(.raw) }
            if soocToDeveloped { result.insert(.developed) }
        case .raw:
            if rawToSooc       { result.insert(.sooc) }
            if rawToDeveloped  { result.insert(.developed) }
        case .developed:
            if developedToSooc { result.insert(.sooc) }
            if developedToRaw  { result.insert(.raw) }
        case .indeterminate:
            break
        }
        return result
    }
}

@Observable @MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    init() {
        let split = UserDefaults.standard.integer(forKey: "groupingSplitThresholdSecs")
        let phash = UserDefaults.standard.integer(forKey: "groupingPhashHammingThreshold")
        self.appliedGroupingSplitThresholdSecs = split > 0 ? split : 2
        self.appliedGroupingPhashHammingThreshold = phash > 0 ? phash : 15
        // 旧 confirmCopy / confirmDelete キーを削除（プロパティ初期化時に移行済み）
        UserDefaults.standard.removeObject(forKey: "confirmCopy")
        UserDefaults.standard.removeObject(forKey: "confirmDelete")
        // autoRenderRawThumbnails は根本解決まで毎起動で強制 OFF（UI 上も disabled）
        UserDefaults.standard.set(false, forKey: "autoRenderRawThumbnails")
        // autoRenderRawSidebar / Compare を一度だけ強制 OFF（IOSurface 枯渇対策）
        if !UserDefaults.standard.bool(forKey: "autoRenderRawSidebarMigrated_v1") {
            UserDefaults.standard.set(false, forKey: "autoRenderRawSidebar")
            UserDefaults.standard.set(false, forKey: "autoRenderRawCompare")
            UserDefaults.standard.set(true, forKey: "autoRenderRawSidebarMigrated_v1")
        }
        // e8e6e6f の緩和修正後、Compare のみ再度デフォルト ON に戻す（Sidebar は引き続き手動）
        if !UserDefaults.standard.bool(forKey: "autoRenderRawCompareMigrated_v2") {
            UserDefaults.standard.set(true, forKey: "autoRenderRawCompare")
            UserDefaults.standard.set(true, forKey: "autoRenderRawCompareMigrated_v2")
        }
    }

    var language: String = UserDefaults.standard.string(forKey: "language") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }

    /// ヒント通知のマスタートグル（既定 ON）。OFF にすると HintCenter は一切発火しない。
    var showHints: Bool = UserDefaults.standard.object(forKey: "showHints") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHints, forKey: "showHints") }
    }
    // [BETA DISABLED] UserDefaults を読まず常に .all で起動する。
    // 再有効化時は下記に戻す:
    // (UserDefaults.standard.string(forKey: "viewMode").flatMap(ViewMode.init(rawValue:))) ?? .all
    var viewMode: ViewMode = .all
    var thumbnailSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "thumbnailSize")
        return v > 0 ? CGFloat(v) : 180
    }() {
        didSet { UserDefaults.standard.set(Double(thumbnailSize), forKey: "thumbnailSize") }
    }
    var sortKey: SortKey = (UserDefaults.standard.string(forKey: "sortKey")
                             .flatMap(SortKey.init(rawValue:))) ?? .filename {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey") }
    }
    var sortAscending: Bool = (UserDefaults.standard.object(forKey: "sortAscending") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
    }
    var compareNavMode: CompareNavMode = (UserDefaults.standard.string(forKey: "compareNavMode")
                                           .flatMap(CompareNavMode.init(rawValue:))) ?? .memberFirst {
        didSet { UserDefaults.standard.set(compareNavMode.rawValue, forKey: "compareNavMode") }
    }
    var ratingShortcutModifier: RatingShortcutModifier = (UserDefaults.standard.string(forKey: "ratingShortcutModifier")
                                                          .flatMap(RatingShortcutModifier.init(rawValue:))) ?? .none {
        didSet { UserDefaults.standard.set(ratingShortcutModifier.rawValue, forKey: "ratingShortcutModifier") }
    }
    var deleteShortcutKey: DeleteShortcutKey = (UserDefaults.standard.string(forKey: "deleteShortcutKey")
                                                .flatMap(DeleteShortcutKey.init(rawValue:))) ?? .delete {
        didSet { UserDefaults.standard.set(deleteShortcutKey.rawValue, forKey: "deleteShortcutKey") }
    }
    var preventViewerDelete: Bool = (UserDefaults.standard.object(forKey: "preventViewerDelete") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(preventViewerDelete, forKey: "preventViewerDelete") }
    }
    var viewerSpaceFullscreen: Bool = (UserDefaults.standard.object(forKey: "viewerSpaceFullscreen") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(viewerSpaceFullscreen, forKey: "viewerSpaceFullscreen") }
    }
    /// 単体ビューの上部ボタンをマウス静止 1 秒で自動非表示にする（マウスを動かすと再表示）。
    var viewerAutoHideControls: Bool = bool("viewerAutoHideControls", default: true) {
        didSet { UserDefaults.standard.set(viewerAutoHideControls, forKey: "viewerAutoHideControls") }
    }
    var calendarMaxMonths: Int = {
        let v = UserDefaults.standard.integer(forKey: "calendarMaxMonths")
        return v > 0 ? v : 5
    }() {
        didSet { UserDefaults.standard.set(calendarMaxMonths, forKey: "calendarMaxMonths") }
    }
    var filterSectionOrder: [FilterSection] = {
        guard let data = UserDefaults.standard.data(forKey: "filterSectionOrder"),
              let saved = try? JSONDecoder().decode([FilterSection].self, from: data),
              !saved.isEmpty else { return FilterSection.allCases }
        var result = saved.filter { FilterSection.allCases.contains($0) }
        // 保存済み並び順に無い新セクションは、allCases 上の直前セクションの後ろに挿入する
        // （例: 後から追加された .flag は .label の直後に並ぶ）。
        for (i, s) in FilterSection.allCases.enumerated() where !result.contains(s) {
            if i > 0, let idx = result.firstIndex(of: FilterSection.allCases[i - 1]) {
                result.insert(s, at: idx + 1)
            } else {
                result.append(s)
            }
        }
        return result
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(filterSectionOrder) {
                UserDefaults.standard.set(data, forKey: "filterSectionOrder")
            }
        }
    }

    // MARK: - 伝播マトリクス (非対角 6 セル)

    var soocToRaw: Bool = bool("propagate.soocToRaw", default: true) {
        didSet { UserDefaults.standard.set(soocToRaw, forKey: "propagate.soocToRaw") }
    }
    var soocToDeveloped: Bool = bool("propagate.soocToDeveloped", default: false) {
        didSet { UserDefaults.standard.set(soocToDeveloped, forKey: "propagate.soocToDeveloped") }
    }
    var rawToSooc: Bool = bool("propagate.rawToSooc", default: true) {
        didSet { UserDefaults.standard.set(rawToSooc, forKey: "propagate.rawToSooc") }
    }
    var rawToDeveloped: Bool = bool("propagate.rawToDeveloped", default: false) {
        didSet { UserDefaults.standard.set(rawToDeveloped, forKey: "propagate.rawToDeveloped") }
    }
    var developedToSooc: Bool = bool("propagate.developedToSooc", default: false) {
        didSet { UserDefaults.standard.set(developedToSooc, forKey: "propagate.developedToSooc") }
    }
    var developedToRaw: Bool = bool("propagate.developedToRaw", default: false) {
        didSet { UserDefaults.standard.set(developedToRaw, forKey: "propagate.developedToRaw") }
    }

    var propagationMatrix: PropagationMatrix {
        PropagationMatrix(
            soocToRaw:       soocToRaw,
            soocToDeveloped: soocToDeveloped,
            rawToSooc:       rawToSooc,
            rawToDeveloped:  rawToDeveloped,
            developedToSooc: developedToSooc,
            developedToRaw:  developedToRaw
        )
    }

    // MARK: - グルーピング閾値

    var groupingSplitThresholdSecs: Int = {
        let v = UserDefaults.standard.integer(forKey: "groupingSplitThresholdSecs")
        return v > 0 ? v : 2
    }() {
        didSet { UserDefaults.standard.set(groupingSplitThresholdSecs, forKey: "groupingSplitThresholdSecs") }
    }
    var groupingPhashHammingThreshold: Int = {
        let v = UserDefaults.standard.integer(forKey: "groupingPhashHammingThreshold")
        return v > 0 ? v : 15
    }() {
        didSet { UserDefaults.standard.set(groupingPhashHammingThreshold, forKey: "groupingPhashHammingThreshold") }
    }

    /// 直近に reindex を適用したときの値。永続化しない（実行時のみ）。
    /// 起動直後は current と一致させて Re-group ボタンをグレーアウトさせる。
    var appliedGroupingSplitThresholdSecs: Int
    var appliedGroupingPhashHammingThreshold: Int

    /// Stepper の現在値が、直近に適用された値と異なるか。Re-group ボタンの有効/無効に使う。
    var groupingNeedsApply: Bool {
        appliedGroupingSplitThresholdSecs != groupingSplitThresholdSecs
            || appliedGroupingPhashHammingThreshold != groupingPhashHammingThreshold
    }

    // MARK: - グループスコープ
    var copyScopeMode: GroupScopeMode = {
        if let raw = UserDefaults.standard.string(forKey: "copyScopeMode"),
           let mode = GroupScopeMode(rawValue: raw) { return mode }
        if let old = UserDefaults.standard.object(forKey: "confirmCopy") as? Bool {
            return old ? .askEachTime : .representative
        }
        return .askEachTime
    }() {
        didSet { UserDefaults.standard.set(copyScopeMode.rawValue, forKey: "copyScopeMode") }
    }
    var dndScopeMode: GroupScopeMode = {
        if let raw = UserDefaults.standard.string(forKey: "dndScopeMode"),
           let mode = GroupScopeMode(rawValue: raw) { return mode }
        return .representative
    }() {
        didSet { UserDefaults.standard.set(dndScopeMode.rawValue, forKey: "dndScopeMode") }
    }
    var deleteScopeMode: GroupScopeMode = {
        if let raw = UserDefaults.standard.string(forKey: "deleteScopeMode"),
           let mode = GroupScopeMode(rawValue: raw) { return mode }
        if let old = UserDefaults.standard.object(forKey: "confirmDelete") as? Bool {
            return old ? .askEachTime : .allInGroup
        }
        return .askEachTime
    }() {
        didSet { UserDefaults.standard.set(deleteScopeMode.rawValue, forKey: "deleteScopeMode") }
    }

    // MARK: - 確認ダイアログ
    var confirmBulkRating: Bool = bool("confirmBulkRating", default: true) {
        didSet { UserDefaults.standard.set(confirmBulkRating, forKey: "confirmBulkRating") }
    }
    var hasShownJpgEmbedWarning: Bool = bool("hasShownJpgEmbedWarning", default: false) {
        didSet { UserDefaults.standard.set(hasShownJpgEmbedWarning, forKey: "hasShownJpgEmbedWarning") }
    }
    var warnSlowStorage: Bool = bool("warnSlowStorage", default: true) {
        didSet { UserDefaults.standard.set(warnSlowStorage, forKey: "warnSlowStorage") }
    }
    var folderWatchEnabled: Bool = bool("folderWatchEnabled", default: true) {
        didSet { UserDefaults.standard.set(folderWatchEnabled, forKey: "folderWatchEnabled") }
    }

    // MARK: - メタデータ書き込み
    var jpgWriteMode: JpgWriteMode = (UserDefaults.standard.string(forKey: "jpgWriteMode")
                                       .flatMap(JpgWriteMode.init(rawValue:))) ?? .embed {
        didSet {
            UserDefaults.standard.set(jpgWriteMode.rawValue, forKey: "jpgWriteMode")
            if jpgWriteMode == .sidecar {
                soocToRaw = true
                rawToSooc = true
            }
        }
    }
    var jpgSidecarConflictPolicy: JpgSidecarConflictPolicy = (UserDefaults.standard.string(forKey: "jpgSidecarConflictPolicy")
                                                               .flatMap(JpgSidecarConflictPolicy.init(rawValue:))) ?? .ask {
        didSet { UserDefaults.standard.set(jpgSidecarConflictPolicy.rawValue, forKey: "jpgSidecarConflictPolicy") }
    }

    // MARK: - パフォーマンス
    var burstMode: Bool = bool("burstMode", default: false) {
        didSet { UserDefaults.standard.set(burstMode, forKey: "burstMode") }
    }

    // Boost Mode 通知バナー: ON 切替時に true になり、数秒後に自動クリアされる。
    var boostNoticeVisible: Bool = false
    // @ObservationIgnored: タスク生成のたびに @Observable が反応してツールバーが再描画されるのを防ぐ
    @ObservationIgnored private var boostNoticeTask: Task<Void, Never>?

    func showBoostNotice() {
        boostNoticeTask?.cancel()
        boostNoticeVisible = true
        boostNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.boostNoticeVisible = false
        }
    }

    func hideBoostNotice() {
        boostNoticeTask?.cancel()
        boostNoticeVisible = false
    }

    // MARK: - RAW レンダリング
    var autoRenderRawThumbnails: Bool = bool("autoRenderRawThumbnails", default: false) {
        didSet { UserDefaults.standard.set(autoRenderRawThumbnails, forKey: "autoRenderRawThumbnails") }
    }
    var autoRenderRawCompare: Bool = bool("autoRenderRawCompare", default: true) {
        didSet { UserDefaults.standard.set(autoRenderRawCompare, forKey: "autoRenderRawCompare") }
    }
    var autoRenderRawSidebar: Bool = bool("autoRenderRawSidebar", default: false) {
        didSet { UserDefaults.standard.set(autoRenderRawSidebar, forKey: "autoRenderRawSidebar") }
    }

    // MARK: - キャッシュ
    var thumbnailCacheMB: Int = {
        let v = UserDefaults.standard.integer(forKey: "thumbnailCacheMB")
        let maxMB = Int(ProcessInfo.processInfo.physicalMemory / 10 / (1024 * 1024))
        // 512MB デフォルト。キャッシュ上限は常駐 RAM のみに影響し、IOSurface 枯渇とは無関係
        // （並列度で制御済み）。低 RAM 機では maxMB にクランプ。
        // 経緯: knowledge/thumbnail-cache-iosurface.md
        return v >= 100 ? min(v, maxMB) : min(512, maxMB)
    }() {
        didSet {
            UserDefaults.standard.set(thumbnailCacheMB, forKey: "thumbnailCacheMB")
            ThumbnailDecodeCache.shared.updateLimit(mb: thumbnailCacheMB)
        }
    }

    var cacheTTLDays: Int = {
        let v = UserDefaults.standard.integer(forKey: "cacheTTLDays")
        return v > 0 ? v : 90
    }() {
        didSet { UserDefaults.standard.set(cacheTTLDays, forKey: "cacheTTLDays") }
    }

    // MARK: - お気に入りアプリ (Open With)

    var favoriteApps: [URL] = {
        guard let data = UserDefaults.standard.data(forKey: "favoriteApps"),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }() {
        didSet {
            let paths = favoriteApps.map(\.path)
            if let data = try? JSONEncoder().encode(paths) {
                UserDefaults.standard.set(data, forKey: "favoriteApps")
            }
        }
    }
}

// UserDefaults.object が nil のとき `default` を返す (Bool には bool(forKey:) が 0 扱いするため)。
private func bool(_ key: String, default value: Bool) -> Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? value
}
