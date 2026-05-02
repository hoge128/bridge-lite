import AppKit
import Foundation

enum FilterSection: String, CaseIterable, Codable, Identifiable {
    case fileType, camera, artist, lens, rating, label
    case iso, focal, shutter, aperture, date

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .fileType: return String(localized: "File Type")
        case .camera:   return String(localized: "Camera")
        case .artist:   return String(localized: "Photographer")
        case .lens:     return String(localized: "Lens")
        case .rating:   return String(localized: "Rating")
        case .label:    return String(localized: "Label")
        case .iso:      return String(localized: "ISO")
        case .focal:    return String(localized: "Focal Length")
        case .shutter:  return String(localized: "Shutter")
        case .aperture: return String(localized: "Aperture")
        case .date:     return String(localized: "Date")
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
        // 起動直後は applied = current として Re-group ボタンを無効状態で開始する。
        let split = UserDefaults.standard.integer(forKey: "groupingSplitThresholdSecs")
        let phash = UserDefaults.standard.integer(forKey: "groupingPhashHammingThreshold")
        self.appliedGroupingSplitThresholdSecs = split > 0 ? split : 2
        self.appliedGroupingPhashHammingThreshold = phash > 0 ? phash : 15
    }

    var language: String = UserDefaults.standard.string(forKey: "language") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
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
    var filterSectionOrder: [FilterSection] = {
        guard let data = UserDefaults.standard.data(forKey: "filterSectionOrder"),
              let saved = try? JSONDecoder().decode([FilterSection].self, from: data),
              !saved.isEmpty else { return FilterSection.allCases }
        var result = saved.filter { FilterSection.allCases.contains($0) }
        for s in FilterSection.allCases where !result.contains(s) { result.append(s) }
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

    // MARK: - 確認ダイアログ
    var confirmCopy: Bool = bool("confirmCopy", default: true) {
        didSet { UserDefaults.standard.set(confirmCopy, forKey: "confirmCopy") }
    }
    var confirmDelete: Bool = bool("confirmDelete", default: true) {
        didSet { UserDefaults.standard.set(confirmDelete, forKey: "confirmDelete") }
    }
    var confirmBulkRating: Bool = bool("confirmBulkRating", default: true) {
        didSet { UserDefaults.standard.set(confirmBulkRating, forKey: "confirmBulkRating") }
    }
    var warnSlowStorage: Bool = bool("warnSlowStorage", default: true) {
        didSet { UserDefaults.standard.set(warnSlowStorage, forKey: "warnSlowStorage") }
    }
}

// UserDefaults.object が nil のとき `default` を返す (Bool には bool(forKey:) が 0 扱いするため)。
private func bool(_ key: String, default value: Bool) -> Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? value
}
