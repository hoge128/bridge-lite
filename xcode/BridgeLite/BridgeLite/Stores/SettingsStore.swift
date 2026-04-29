import Foundation

enum GridMode: String, CaseIterable {
    case strict, dense
}

enum CompareNavMode: String {
    case memberFirst  // ←→ = グループ内メンバー移動 / Ctrl+Tab = グループ間移動
    case groupFirst   // ←→ = グループ間移動 / Ctrl+Tab = グループ内メンバー移動
}

enum SortKey: String, CaseIterable {
    case filename, createdDate, modifiedDate, fileSize, rating

    var localizedName: String {
        switch self {
        case .filename:     return "ファイル名"
        case .createdDate:  return "作成日"
        case .modifiedDate: return "修正日"
        case .fileSize:     return "サイズ"
        case .rating:       return "レーティング"
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
        }
        return result
    }
}

@Observable @MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    var defaultPath: String = UserDefaults.standard.string(forKey: "defaultPath") ?? "" {
        didSet { UserDefaults.standard.set(defaultPath, forKey: "defaultPath") }
    }
    var language: String = UserDefaults.standard.string(forKey: "language") ?? "ja" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var theme: String = UserDefaults.standard.string(forKey: "theme") ?? "system" {
        didSet { UserDefaults.standard.set(theme, forKey: "theme") }
    }
    var gridMode: GridMode = (UserDefaults.standard.string(forKey: "gridMode")
                               .flatMap(GridMode.init(rawValue:))) ?? .strict {
        didSet { UserDefaults.standard.set(gridMode.rawValue, forKey: "gridMode") }
    }
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
}

// UserDefaults.object が nil のとき `default` を返す (Bool には bool(forKey:) が 0 扱いするため)。
private func bool(_ key: String, default value: Bool) -> Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? value
}
