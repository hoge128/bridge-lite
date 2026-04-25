// Re-export from bridge-core::scanner
#[allow(unused_imports)]
pub use bridge_core::scanner::{
    ImageEntry,
    SUPPORTED_EXTENSIONS,
    RAW_EXTENSIONS,
    normalize_stem,
    compute_shot_id,
    scan_directory,
    is_raw,
};
