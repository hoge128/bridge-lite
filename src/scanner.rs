use std::path::PathBuf;
use std::time::SystemTime;

use walkdir::WalkDir;

pub const SUPPORTED_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "tif", "tiff", "bmp", "webp", "gif",
];

pub const RAW_EXTENSIONS: &[&str] = &[
    "arw", "cr2", "cr3", "nef", "orf", "rw2", "dng", "raf", "3fr", "fff", "iiq", "mos", "mrw",
    "nrw", "pef", "srw", "x3f", "heic", "heif",
];

#[derive(Debug, Clone)]
pub struct ImageEntry {
    pub id: usize,
    pub path: PathBuf,
    pub filename: String,
    pub is_raw: bool,
    pub file_size: u64,
    pub modified: Option<SystemTime>,
    pub created: Option<SystemTime>,
    /// true if another entry in the same scan shares this entry's shot_id and is non-RAW.
    /// Always false for non-RAW entries.
    pub has_jpg_partner: bool,
    /// Stable identity of the "shot" this variant belongs to.
    /// All variants sharing a normalized stem get the same shot_id.
    pub shot_id: u64,
}

// ── Shot-grouping helpers ──────────────────────────────────────────────────

/// Strip known edit/copy/variant suffixes from a lowercased stem, one at a time.
/// Returns true when a suffix was removed.
fn strip_one_suffix(s: &mut String) -> bool {
    // Finder-style copy: " (N)" at the end
    if let Some(i) = s.rfind(" (") {
        let tail = &s[i + 2..];
        if tail.ends_with(')') {
            let digits = &tail[..tail.len() - 1];
            if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) {
                s.truncate(i);
                return true;
            }
        }
    }
    // Exact suffixes (may appear without trailing digits)
    for suffix in &["-copy", "_copy", "-enhanced", "-edit", "_edit"] {
        if s.ends_with(suffix) {
            let new_len = s.len() - suffix.len();
            s.truncate(new_len);
            return true;
        }
    }
    // Suffixes followed by one or more digits: -v2, _v3, -edit2, _edit3
    let no_digits = s.trim_end_matches(|c: char| c.is_ascii_digit()).to_string();
    if no_digits.len() < s.len() {
        for suffix in &["-v", "_v", "-edit", "_edit"] {
            if no_digits.ends_with(suffix) {
                let new_len = no_digits.len() - suffix.len();
                s.truncate(new_len);
                return true;
            }
        }
    }
    // Software-tool suffixes: find "-<keyword>" and strip from that point to end.
    // Matches DxO PureRAW ("DSE06384-DxO_DeepPRIME XD2s"), Lightroom exports, etc.
    const SOFTWARE_MARKERS: &[&str] = &[
        "-dxo", "_dxo",
        "-lightroom", "_lightroom",
        "-captureone", "-capture_one", "_captureone",
        "-photolab", "_photolab",
        "-topaz", "_topaz",
        "-on1", "_on1",
        "-luminar", "_luminar",
        "-affinity", "_affinity",
        "-denoise", "_denoise",
        "-gigapixel", "_gigapixel",
        "-sharpen", "_sharpen",
    ];
    for marker in SOFTWARE_MARKERS {
        if let Some(idx) = s.find(marker) {
            if idx > 0 {
                s.truncate(idx);
                return true;
            }
        }
    }
    false
}

/// Normalize a file stem for shot grouping.
/// Lowercases and strips trailing edit/copy/variant markers.
/// Falls back to the original lowercased stem when the result is very short (< 3 chars)
/// to avoid false collisions from single-letter stems.
pub fn normalize_stem(s: &str) -> String {
    let lower = s.to_lowercase();
    let mut working = lower.clone();
    while strip_one_suffix(&mut working) {}
    if working.len() < 3 {
        lower
    } else {
        working
    }
}

pub fn compute_shot_id(normalized_stem: &str) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    normalized_stem.hash(&mut h);
    h.finish()
}

pub fn scan_directory(path: PathBuf) -> Vec<ImageEntry> {
    let mut entries = Vec::new();

    for dir_entry in WalkDir::new(&path)
        .max_depth(10)
        .follow_links(true)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        let entry_path = dir_entry.path().to_path_buf();

        let ext_lower = entry_path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_lowercase());

        let Some(ext) = ext_lower else { continue };

        let is_supported = SUPPORTED_EXTENSIONS.contains(&ext.as_str());
        let is_raw = RAW_EXTENSIONS.contains(&ext.as_str());

        if !is_supported && !is_raw {
            continue;
        }

        let filename = entry_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();

        let meta = dir_entry.metadata().ok();
        let file_size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        let modified = meta.as_ref().and_then(|m| m.modified().ok());
        let created = meta.as_ref().and_then(|m| m.created().ok());

        let stem = entry_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("");
        let shot_id = compute_shot_id(&normalize_stem(stem));

        entries.push(ImageEntry {
            id: 0,
            path: entry_path,
            filename,
            is_raw,
            file_size,
            modified,
            created,
            has_jpg_partner: false,
            shot_id,
        });
    }

    // Mark RAW entries whose shot_id group contains at least one non-RAW entry.
    let non_raw_shot_ids: std::collections::HashSet<u64> = entries
        .iter()
        .filter(|e| !e.is_raw)
        .map(|e| e.shot_id)
        .collect();

    for entry in &mut entries {
        if entry.is_raw {
            entry.has_jpg_partner = non_raw_shot_ids.contains(&entry.shot_id);
        }
    }

    entries.sort_by(|a, b| {
        use std::cmp::Reverse;
        let ka = a.created.or(a.modified);
        let kb = b.created.or(b.modified);
        Reverse(ka).cmp(&Reverse(kb))
            .then_with(|| a.filename.to_lowercase().cmp(&b.filename.to_lowercase()))
    });

    for (i, entry) in entries.iter_mut().enumerate() {
        entry.id = i;
    }

    entries
}

#[cfg(test)]
mod tests {
    use super::{compute_shot_id, normalize_stem};

    fn sid(s: &str) -> u64 { compute_shot_id(&normalize_stem(s)) }

    #[test]
    fn same_stem_pairs() {
        assert_eq!(sid("DSE06419"), sid("DSE06419")); // exact same
        assert_eq!(sid("foo"), sid("foo-edit"));
        assert_eq!(sid("foo"), sid("foo_edit"));
        assert_eq!(sid("foo"), sid("foo-edit2"));
        assert_eq!(sid("foo"), sid("foo-Enhanced"));
        assert_eq!(sid("foo"), sid("foo-copy"));
        assert_eq!(sid("foo"), sid("foo_copy"));
        assert_eq!(sid("foo"), sid("foo-v2"));
        assert_eq!(sid("foo"), sid("foo_v3"));
        assert_eq!(sid("IMG"), sid("IMG (2)")); // Finder copy
        assert_eq!(sid("IMG_0001"), sid("IMG_0001-edit")); // edit on long stem
    }

    #[test]
    fn different_stems_are_distinct() {
        assert_ne!(sid("DSC_0001"), sid("DSC_0002")); // sequential shots
        assert_ne!(sid("img001"), sid("img002"));
    }

    #[test]
    fn short_stem_protection() {
        // Single-char stems: A and A-edit should NOT group (revert to original)
        assert_ne!(sid("A"), sid("A-edit"));
        // Two-char stems
        assert_ne!(sid("AB"), sid("AB-edit"));
    }

    #[test]
    fn multi_strip() {
        // Multiple suffixes are stripped in sequence
        assert_eq!(sid("foo"), sid("foo-edit-copy"));
        assert_eq!(normalize_stem("bar-v2-copy"), normalize_stem("bar"));
    }

    #[test]
    fn software_suffix_stripping() {
        // DxO PureRAW output: "DSE06384-DxO_DeepPRIME XD2s"
        assert_eq!(sid("DSE06384"), sid("DSE06384-DxO_DeepPRIME XD2s"));
        // Lightroom export
        assert_eq!(sid("DSE06384"), sid("DSE06384-Lightroom-Export"));
        // Capture One
        assert_eq!(sid("foo"), sid("foo-CaptureOne-adjusted"));
        // Negative: different shot should not merge
        assert_ne!(sid("DSE06384"), sid("DSE06385-DxO_DeepPRIME XD2s"));
        // DxO DNG output groups with original
        assert_eq!(sid("DSE06384"), sid("DSE06384-DxO_DeepPRIME XD2s"));
    }
}
