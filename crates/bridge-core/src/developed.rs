/// RAW 現像ソフトウェアの判定キーワード。
/// EXIF Software タグや XMP xmpMM:History/stEvt:softwareAgent に含まれていれば現像済みと判定。
pub const DEVELOPED_SOFTWARE_KEYWORDS: &[&str] = &[
    "lightroom",
    "dxo",
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
];
