use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use rayon::prelude::*;
use sha2::{Digest, Sha256};

use crate::db;
use crate::scanner::ImageEntry;

/// Compute the SHA-256 of the file at `path`. Returns None on I/O error.
pub fn compute_sha256(path: &Path) -> Option<[u8; 32]> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut hasher = Sha256::new();
    // IMPORTANT: rayon ワーカーのデフォルトスタックは 2MB。
    // par_iter から呼ばれるためスタック上に大きな配列を置かない (常にヒープ)。
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buf[..n]),
            Err(_) => return None,
        }
    }
    Some(hasher.finalize().into())
}

/// For all entries whose file_size collides with at least one other entry, fetch
/// their SHA-256 from cache (validated by mtime) or compute and cache them.
/// Returns a map of entry.id → sha256.
pub fn fetch_or_compute_sha_for_size_collisions(
    entries: &[ImageEntry],
    db_path: &Path,
) -> HashMap<usize, [u8; 32]> {
    // Bucket by file_size, keep only sizes with ≥2 entries.
    let mut by_size: HashMap<u64, Vec<&ImageEntry>> = HashMap::new();
    for e in entries {
        by_size.entry(e.file_size).or_default().push(e);
    }

    let collision_entries: Vec<&ImageEntry> = by_size
        .into_values()
        .filter(|v| v.len() >= 2)
        .flatten()
        .collect();

    if collision_entries.is_empty() {
        return HashMap::new();
    }

    let collision_paths: Vec<PathBuf> = collision_entries.iter().map(|e| e.path.clone()).collect();

    // Fetch cached SHAs (mtime-validated).
    let cached = db::fetch_sha_batch(&collision_paths, db_path);

    // Determine which entries need (re-)computation.
    let to_compute: Vec<&ImageEntry> = collision_entries
        .iter()
        .copied()
        .filter(|e| !cached.contains_key(&e.path))
        .collect();

    // Parallel computation (background pool: 論理コア数/2 に制限し他アプリへの影響を抑える)。
    let computed: Vec<(&ImageEntry, [u8; 32])> = crate::runtime::background_pool().install(|| {
        to_compute
            .par_iter()
            .filter_map(|e| compute_sha256(&e.path).map(|sha| (*e, sha)))
            .collect()
    });

    // Persist newly computed SHAs.
    if !computed.is_empty() {
        let items: Vec<(PathBuf, i64, [u8; 32])> = computed
            .iter()
            .map(|(e, sha)| {
                let mtime = e
                    .modified
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                (e.path.clone(), mtime, *sha)
            })
            .collect();
        db::store_sha_batch(&items, db_path);
    }

    // Merge cached + computed, keyed by entry.id.
    let mut result: HashMap<usize, [u8; 32]> = HashMap::new();
    for e in &collision_entries {
        if let Some(&sha) = cached.get(&e.path) {
            result.insert(e.id, sha);
        }
    }
    for (e, sha) in &computed {
        result.insert(e.id, *sha);
    }
    result
}

/// From a map of entry.id → sha256, return duplicate groups (≥2 members per sha).
/// The returned map uses sha256 as the key and contains only groups with ≥2 members.
pub fn group_duplicates(
    shas: &HashMap<usize, [u8; 32]>,
) -> HashMap<[u8; 32], Vec<usize>> {
    let mut by_sha: HashMap<[u8; 32], Vec<usize>> = HashMap::new();
    for (&id, sha) in shas {
        by_sha.entry(*sha).or_default().push(id);
    }
    by_sha.retain(|_, ids| ids.len() >= 2);
    by_sha
}
