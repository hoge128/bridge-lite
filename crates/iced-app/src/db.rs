use std::path::PathBuf;

// Re-export DB functions from bridge-core
#[allow(unused_imports)]
pub use bridge_core::db::{
    EXIF_SCHEMA_VERSION,
    ensure_schema,
    fetch_or_index,
    fetch_or_index_async,
    fetch_exif_batch,
    fetch_exif_batch_async,
    fetch_thumb,
    store_thumb,
    update_xmp,
    fetch_phash,
    store_phash,
    fetch_phash_batch,
    fetch_phash_batch_async,
};

/// Returns the default SQLite database path for bridge-lite.
/// Located in the platform data-local directory to avoid iCloud sync.
pub fn db_path() -> PathBuf {
    let base = dirs_next::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("bridge-lite");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("cache.db")
}
