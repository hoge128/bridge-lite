import Foundation

struct ExifData: Sendable, Equatable {
    var make: String?
    var model: String?
    var datetime: String?
    var subsec: String?
    var exposureTime: String?
    var fnumber: String?
    var iso: Int?
    var focalLength: String?
    var focalLength35mm: Int?
    var lensName: String?
    var width: Int?
    var height: Int?
    var software: String?
    var artist: String?
    var exposureBias: String?
    var flash: String?
    var whiteBalance: String?
    var imageDescription: String?  // EXIF tag 0x010E, read-only
    var userComment: String?       // EXIF tag 0x9286, read-only

    // MARK: - 焦点距離の派生値（EXIF ロード時に一度だけ算出してストア）
    //
    // フィルタ・ヒストグラム・表示で頻繁に読まれるため、毎回の文字列パースや
    // クロップ算出を避け、init（= スキャン/索引フェーズの EXIF ロード時）で
    // 一度だけ確定させる。画像ファイルにもキャッシュにも書き込まない、
    // メモリ内のみの純粋な派生値（生成のたびに raw から再計算される）。

    /// レンズ実焦点距離 (mm)。"50 mm" / "50/1 mm" → 50.0
    let focalLengthMm: Double?
    /// 35mm換算の実効値（記録値 0xA405 優先、無ければ Make から算出した補完値）。
    let focalLength35mmEffective: Int?
    /// 実効値が計算による補完か（true のとき表示に "≈" を付ける）。
    let focalLength35mmIsComputed: Bool

    init(
        make: String? = nil, model: String? = nil, datetime: String? = nil,
        subsec: String? = nil, exposureTime: String? = nil, fnumber: String? = nil,
        iso: Int? = nil, focalLength: String? = nil, focalLength35mm: Int? = nil,
        lensName: String? = nil, width: Int? = nil, height: Int? = nil,
        software: String? = nil, artist: String? = nil, exposureBias: String? = nil,
        flash: String? = nil, whiteBalance: String? = nil,
        imageDescription: String? = nil, userComment: String? = nil
    ) {
        self.make = make
        self.model = model
        self.datetime = datetime
        self.subsec = subsec
        self.exposureTime = exposureTime
        self.fnumber = fnumber
        self.iso = iso
        self.focalLength = focalLength
        self.focalLength35mm = focalLength35mm
        self.lensName = lensName
        self.width = width
        self.height = height
        self.software = software
        self.artist = artist
        self.exposureBias = exposureBias
        self.flash = flash
        self.whiteBalance = whiteBalance
        self.imageDescription = imageDescription
        self.userComment = userComment

        // 派生値を一度だけ算出（以後の読み出しはストアド参照で O(1)）
        let mm = Self.parseRational(focalLength?.components(separatedBy: " ").first)
        self.focalLengthMm = mm
        let computed: Int? = {
            guard focalLength35mm == nil, let mm,
                  let crop = Self.cropFactor(make: make) else { return nil }
            return Int((mm * crop).rounded())
        }()
        self.focalLength35mmEffective = focalLength35mm ?? computed
        self.focalLength35mmIsComputed = (focalLength35mm == nil && computed != nil)
    }

    var cameraName: String? {
        guard let model = model else { return make }
        if let make = make, !model.hasPrefix(make) {
            return "\(make) \(model)"
        }
        return model
    }

    // 35mm換算が取れればそれを、なければ実焦点距離
    var effectiveFocalMm: Double? {
        if let mm = focalLength35mmEffective { return Double(mm) }
        return focalLengthMm
    }

    // MARK: - クロップファクタ
    //
    // OM System / Olympus 等のマイクロフォーサーズ機は標準 EXIF に
    // FocalLengthIn35mmFilm (0xA405) を書かない。記録値が無い場合のみ、init で
    // Make から判定したクロップファクタ × 実焦点距離で 35mm換算を補完する。

    /// Make からクロップファクタを引く。交換レンズ機が全て同一センサーで
    /// 曖昧さの無いベンダーのみ対応する（将来 Make+Model 単位に拡張可能）。
    /// - マイクロフォーサーズ (OLYMPUS / OM Digital Solutions) → 2.0
    /// Panasonic は FF(S) と MFT(G) が混在し Make だけでは判別できないため対象外
    /// （かつ Panasonic は 0xA405 を記録するので補完不要）。
    static func cropFactor(make: String?) -> Double? {
        guard let m = make?.uppercased() else { return nil }
        if m.contains("OM DIGITAL") || m.contains("OLYMPUS") { return 2.0 }
        return nil
    }

    var fnumberValue: Double? {
        guard let s = fnumber else { return nil }
        let stripped = s.hasPrefix("f/") ? String(s.dropFirst(2)) : s
        return Double(stripped.components(separatedBy: " ").first ?? stripped)
    }

    // 秒単位（例: "1/200 s" → 0.005）
    var shutterSeconds: Double? {
        Self.parseRational(exposureTime?.components(separatedBy: " ").first)
    }

    private static func parseRational(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        let parts = s.split(separator: "/")
        guard parts.count == 2,
              let n = Double(parts[0]),
              let d = Double(parts[1]),
              d != 0 else { return nil }
        return n / d
    }

    var resolutionString: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) × \(h)"
    }

    var isDeveloped: Bool {
        guard let sw = software?.lowercased() else { return false }
        return BridgeCoreConstants.developedKeywords.contains { sw.contains($0) }
    }
}

enum BridgeCoreConstants {
    // Must stay in sync with crates/bridge-core/src/developed.rs
    static let developedKeywords: [String] = [
        "lightroom", "dxo", "pureraw",
        "capture one", "captureone",
        "photoshop", "camera raw",
        "topaz", "on1", "luminar", "affinity",
        "darktable", "rawtherapee",
        "silkypix", "rawpower", "picktorial", "iridient", "exposure x",
    ]

    // 専用 RAW デコードが必要なフォーマット（ImageIO を経由せず Rust の埋め込み JPEG
    // 抽出 extractRawJpeg を使う）。crates/bridge-core/src/scanner.rs の RAW_EXTENSIONS から
    // dng を除いたもの（DNG は Apple ImageIO がネイティブにデコードできるため ImageIO に任せる）。
    // 新フォーマット追加時は Rust 側 RAW_EXTENSIONS と必ず同期すること。
    static let proprietaryRawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "crw", "nef", "nrw", "orf", "rw2", "rwl",
        "raf", "pef", "srw", "3fr", "fff", "iiq", "mos",
    ]

    // Must stay in sync with SOFTWARE_MARKERS in crates/bridge-core/src/scanner.rs
    static let softwareFilenameMarkers: [String] = [
        "-dxo", "_dxo",
        "-pureraw", "_pureraw",
        "-lightroom", "_lightroom",
        "-captureone", "-capture_one", "_captureone",
        "-photolab", "_photolab",
        "-topaz", "_topaz",
        "-on1", "_on1",
        "-luminar", "_luminar",
        "-affinity", "_affinity",
        "-silkypix", "_silkypix",
        "-denoise", "_denoise",
        "-gigapixel", "_gigapixel",
        "-sharpen", "_sharpen",
        "-processed", "_processed",
    ]
}
