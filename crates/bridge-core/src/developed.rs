/// RAW 現像ソフトウェアの判定キーワード。
/// EXIF Software タグや XMP xmpMM:History/stEvt:softwareAgent、xmp:CreatorTool に
/// 含まれていれば現像済みと判定。
pub const DEVELOPED_SOFTWARE_KEYWORDS: &[&str] = &[
    "lightroom",
    "dxo",
    "pureraw",       // DxO PureRAW (standalone name without "dxo" prefix)
    "capture one",
    "captureone",
    "photoshop",
    "camera raw",
    "topaz",
    "on1",
    "luminar",
    "affinity",
    "darktable",
    "rawtherapee",
    "silkypix",      // Silkypix Developer Studio (Fujifilm/Pentax users)
    "rawpower",      // RawPower (Mac)
    "picktorial",    // Picktorial
    "iridient",      // Iridient Developer / X-Transformer
    "exposure x",    // Exposure X (Alien Skin / Exposure Software)
];
