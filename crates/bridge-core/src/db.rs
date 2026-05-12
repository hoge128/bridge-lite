use std::path::{Path, PathBuf};

use rusqlite::{Connection, Result, params};

use crate::metadata::ExifData;
use crate::xmp::XmpData;

// ── Schema ─────────────────────────────────────────────────────────────────

/// Bump only when EXIF *extraction logic* changes and existing rows must be
/// re-read from source files (triggers DELETE FROM images in migration).
/// Adding nullable columns via migrate_image_columns() does NOT require a bump —
/// stale rows are identified by mtime mismatch and re-indexed lazily.
/// v2: software column populated.
/// v3: subsec column added (SubSecTimeOriginal for timestamp grouping).
/// v4: artist column added (EXIF Artist tag).
/// v5: exposure_bias, flash, white_balance added; forced re-index to populate new fields.
pub const EXIF_SCHEMA_VERSION: i32 = 6;

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        PRAGMA journal_mode = WAL;

        CREATE TABLE IF NOT EXISTS images (
            path          TEXT PRIMARY KEY,
            filename      TEXT NOT NULL,
            file_size     INTEGER,
            make          TEXT,
            model         TEXT,
            datetime      TEXT,
            subsec        TEXT,
            exposure      TEXT,
            fnumber       TEXT,
            iso           INTEGER,
            focal_len     TEXT,
            img_width     INTEGER,
            img_height    INTEGER,
            software      TEXT,
            artist        TEXT,
            exposure_bias TEXT,
            flash         TEXT,
            white_balance TEXT,
            mtime         INTEGER,
            indexed_at    INTEGER DEFAULT (strftime('%s', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_images_datetime ON images(datetime);
        CREATE INDEX IF NOT EXISTS idx_images_make     ON images(make);
        CREATE INDEX IF NOT EXISTS idx_images_model    ON images(model);
        CREATE INDEX IF NOT EXISTS idx_images_iso      ON images(iso);

        CREATE TABLE IF NOT EXISTS thumbnails (
            path      TEXT PRIMARY KEY,
            mtime     INTEGER NOT NULL,
            jpeg      BLOB NOT NULL,
            cached_at INTEGER DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_thumbnails_cached_at ON thumbnails(cached_at);

        CREATE TABLE IF NOT EXISTS phashes (
            path      TEXT PRIMARY KEY,
            mtime     INTEGER NOT NULL,
            phash     INTEGER NOT NULL,
            cached_at INTEGER DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_phashes_cached_at ON phashes(cached_at);

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS rendered_thumbnails (
            path   TEXT NOT NULL,
            mtime  INTEGER NOT NULL,
            engine TEXT NOT NULL,
            width  INTEGER NOT NULL,
            jpeg   BLOB NOT NULL,
            PRIMARY KEY (path, engine, width)
        );

        CREATE TABLE IF NOT EXISTS file_hashes (
            path      TEXT PRIMARY KEY,
            mtime     INTEGER NOT NULL,
            sha256    BLOB NOT NULL,
            cached_at INTEGER DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_file_hashes_sha       ON file_hashes(sha256);
        CREATE INDEX IF NOT EXISTS idx_file_hashes_cached_at ON file_hashes(cached_at);
        ",
    )
}

fn migrate_to_current_version(conn: &Connection) -> Result<()> {
    let current: i32 = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'exif_schema_version'",
            [],
            |r| r.get::<_, String>(0),
        )
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1); // pre-versioning DBs treated as v1

    if current < EXIF_SCHEMA_VERSION {
        // Purge stale EXIF rows so they get re-indexed with full software data.
        // Thumbnails have independent mtime-based validation and are kept.
        conn.execute_batch("DELETE FROM images;")?;
    }

    conn.execute(
        "INSERT INTO meta (key, value) VALUES ('exif_schema_version', ?1)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![EXIF_SCHEMA_VERSION.to_string()],
    )?;
    Ok(())
}

// ── Public API ─────────────────────────────────────────────────────────────

pub fn ensure_schema(db_path: &Path) -> bool {
    Connection::open(db_path)
        .and_then(|conn| {
            init_schema(&conn)?;
            migrate_image_columns(&conn);
            migrate_to_current_version(&conn)?;
            Ok(())
        })
        .is_ok()
}

/// Add new nullable columns to the images table on existing DBs.
/// ALTER TABLE fails silently when the column already exists, making this safe
/// to call on every startup regardless of the current schema state.
fn migrate_image_columns(conn: &Connection) {
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN rating                  INTEGER;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN xmp_label              TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN xmp_flag               TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN xmp_caption            TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN exif_image_description TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN exif_user_comment      TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN software        TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN mtime           INTEGER;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN focal_len_35mm  INTEGER;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN lens_model      TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN artist          TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN exposure_bias  TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN flash          TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN white_balance  TEXT;");
    let _ = conn.execute_batch("ALTER TABLE thumbnails ADD COLUMN cached_at  INTEGER;");
    let _ = conn.execute_batch("ALTER TABLE phashes    ADD COLUMN cached_at  INTEGER;");
    let _ = conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_thumbnails_cached_at ON thumbnails(cached_at);"
    );
    let _ = conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_phashes_cached_at ON phashes(cached_at);"
    );
}

/// Check DB for cached EXIF. On miss (or mtime mismatch), read from file and cache.
pub fn fetch_or_index(path: &Path, db_path: &Path) -> Option<ExifData> {
    let conn = Connection::open(db_path).ok()?;
    let mtime = file_mtime(path);

    if let Some(exif) = query_exif(&conn, path, mtime) {
        return Some(exif);
    }

    let exif = crate::metadata::read_exif_sync(path)?;
    let _ = upsert(&conn, path, &exif, mtime);
    Some(exif)
}

/// Async wrapper that runs `fetch_or_index` on the blocking thread pool.
pub async fn fetch_or_index_async(
    id: usize,
    path: PathBuf,
    db_path: PathBuf,
) -> (usize, Option<ExifData>) {
    let result = tokio::task::spawn_blocking(move || fetch_or_index(&path, &db_path))
        .await
        .ok()
        .flatten();
    (id, result)
}

/// Fetch all already-cached EXIF rows for the given paths in a single connection.
/// Rows whose mtime no longer matches the file on disk are excluded (stale cache).
/// Paths with no DB row or a stale mtime are omitted; the caller discovers misses
/// by comparing the returned keys against the full path list.
pub fn fetch_exif_batch(
    paths: &[PathBuf],
    db_path: &Path,
) -> std::collections::HashMap<PathBuf, ExifData> {
    let mut out = std::collections::HashMap::new();
    let Ok(conn) = Connection::open(db_path) else { return out };
    // SQLite IN-clause limit is 999; chunk to stay well below it.
    for chunk in paths.chunks(500) {
        let placeholders = std::iter::repeat("?")
            .take(chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT path, mtime, make, model, datetime, subsec, exposure, fnumber, iso, \
                    focal_len, focal_len_35mm, lens_model, img_width, img_height, software, artist, \
                    exposure_bias, flash, white_balance, \
                    exif_image_description, exif_user_comment \
             FROM images WHERE path IN ({placeholders})"
        );
        let Ok(mut stmt) = conn.prepare(&sql) else { continue };
        let params = rusqlite::params_from_iter(
            chunk.iter().map(|p| p.to_string_lossy().into_owned()),
        );
        let Ok(rows) = stmt.query_map(params, |row| {
            let path_str: String = row.get(0)?;
            let stored_mtime: Option<i64> = row.get(1)?;
            Ok((
                PathBuf::from(path_str),
                stored_mtime,
                ExifData {
                    make: row.get(2)?,
                    model: row.get(3)?,
                    datetime: row.get(4)?,
                    subsec: row.get(5)?,
                    exposure_time: row.get(6)?,
                    fnumber: row.get(7)?,
                    iso: row.get(8)?,
                    focal_length: row.get(9)?,
                    focal_length_35mm: row.get(10)?,
                    lens_model: row.get(11)?,
                    width: row.get(12)?,
                    height: row.get(13)?,
                    software: row.get(14)?,
                    artist: row.get(15)?,
                    exposure_bias: row.get(16)?,
                    flash: row.get(17)?,
                    white_balance: row.get(18)?,
                    image_description: row.get(19)?,
                    user_comment: row.get(20)?,
                },
            ))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            let (path, stored_mtime, exif) = row;
            if stored_mtime.map_or(false, |m| m == file_mtime(&path)) {
                out.insert(path, exif);
            }
        }
    }
    out
}

/// Async wrapper for `fetch_exif_batch`.
pub async fn fetch_exif_batch_async(
    paths: Vec<PathBuf>,
    db_path: PathBuf,
) -> std::collections::HashMap<PathBuf, ExifData> {
    tokio::task::spawn_blocking(move || fetch_exif_batch(&paths, &db_path))
        .await
        .unwrap_or_default()
}

/// Index newly discovered files in parallel.
///
/// Strategy A: read cache hits with one IN-clause query (fast), then parse
/// EXIF for misses in parallel via rayon, finally write all new rows in one
/// BEGIN/COMMIT transaction (one SQLite writer, no contention).
pub fn index_new_entries(paths: &[PathBuf], db_path: &Path) {
    use rayon::prelude::*;
    let cached = fetch_exif_batch(paths, db_path);
    let misses: Vec<&PathBuf> = paths.iter().filter(|p| !cached.contains_key(*p)).collect();
    if misses.is_empty() {
        return;
    }
    let new_data: Vec<(PathBuf, i64, ExifData)> = crate::runtime::background_pool().install(|| {
        misses
            .par_iter()
            .filter_map(|path| {
                let mtime = file_mtime(path);
                let exif = crate::metadata::read_exif_sync(path)?;
                Some(((*path).clone(), mtime, exif))
            })
            .collect()
    });
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.execute_batch("BEGIN");
    for (path, mtime, exif) in &new_data {
        let _ = upsert(&conn, path, exif, *mtime);
    }
    let _ = conn.execute_batch("COMMIT");
}

// ── Thumbnail blob cache ───────────────────────────────────────────────────

fn file_mtime(path: &Path) -> i64 {
    std::fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Return cached thumbnail JPEG bytes if the file's mtime still matches.
pub fn fetch_thumb(path: &Path, db_path: &Path) -> Option<Vec<u8>> {
    let conn = Connection::open(db_path).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    conn.query_row(
        "SELECT jpeg FROM thumbnails WHERE path = ?1 AND mtime = ?2",
        params![path.to_string_lossy().as_ref(), mtime],
        |row| row.get(0),
    )
    .ok()
}

/// Persist a thumbnail JPEG blob for the given file path.
pub fn store_thumb(path: &Path, db_path: &Path, jpeg: &[u8]) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    let _ = conn.execute(
        "INSERT OR REPLACE INTO thumbnails (path, mtime, jpeg, cached_at)
         VALUES (?1, ?2, ?3, strftime('%s','now'))",
        params![path.to_string_lossy().as_ref(), mtime, jpeg],
    );
}

// ── Rendered thumbnail cache ───────────────────────────────────────────────

/// Return a rendered JPEG if the cached entry matches both the file's current mtime
/// and the given engine/width combination.
pub fn fetch_rendered(path: &Path, db_path: &Path, engine: &str, width: u32) -> Option<Vec<u8>> {
    let conn = Connection::open(db_path).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    conn.query_row(
        "SELECT jpeg FROM rendered_thumbnails WHERE path = ?1 AND mtime = ?2 AND engine = ?3 AND width = ?4",
        params![path.to_string_lossy().as_ref(), mtime, engine, width as i64],
        |row| row.get(0),
    )
    .ok()
}

/// Persist a rendered JPEG blob.  Overwrites any prior entry with the same
/// (path, engine, width) key.
pub fn store_rendered(path: &Path, db_path: &Path, engine: &str, width: u32, jpeg: &[u8]) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    let _ = conn.execute(
        "INSERT OR REPLACE INTO rendered_thumbnails (path, mtime, engine, width, jpeg) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![path.to_string_lossy().as_ref(), mtime, engine, width as i64, jpeg],
    );
}

/// Delete all rows from rendered_thumbnails.
pub fn clear_rendered(db_path: &Path) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let _ = conn.execute("DELETE FROM rendered_thumbnails", []);
}

// ── Internal helpers ───────────────────────────────────────────────────────

/// Returns cached EXIF only when the stored mtime matches the file's current mtime.
/// Rows with NULL mtime (legacy, pre-migration) never match and trigger re-indexing.
fn query_exif(conn: &Connection, path: &Path, mtime: i64) -> Option<ExifData> {
    let path_str = path.to_string_lossy();
    conn.query_row(
        "SELECT make, model, datetime, subsec, exposure, fnumber, iso, focal_len,
                focal_len_35mm, lens_model, img_width, img_height, software, artist,
                exposure_bias, flash, white_balance,
                exif_image_description, exif_user_comment
         FROM images WHERE path = ?1 AND mtime = ?2",
        params![path_str.as_ref(), mtime],
        |row| {
            Ok(ExifData {
                make: row.get(0)?,
                model: row.get(1)?,
                datetime: row.get(2)?,
                subsec: row.get(3)?,
                exposure_time: row.get(4)?,
                fnumber: row.get(5)?,
                iso: row.get(6)?,
                focal_length: row.get(7)?,
                focal_length_35mm: row.get(8)?,
                lens_model: row.get(9)?,
                width: row.get(10)?,
                height: row.get(11)?,
                software: row.get(12)?,
                artist: row.get(13)?,
                exposure_bias: row.get(14)?,
                flash: row.get(15)?,
                white_balance: row.get(16)?,
                image_description: row.get(17)?,
                user_comment: row.get(18)?,
            })
        },
    )
    .ok()
}

pub fn update_xmp(path: &Path, db_path: &Path, data: &XmpData) {
    // Guarantee the images row exists before updating XMP columns.
    // fetch_or_index is a fast no-op when EXIF is already cached with a valid mtime.
    let _ = fetch_or_index(path, db_path);

    let Ok(conn) = Connection::open(db_path) else { return };
    let path_str = path.to_string_lossy();
    let label = data.label.map(|l| l.as_str().to_string());
    let flag  = data.flag.map(|f| f.as_str().to_string());
    let _ = conn.execute(
        "UPDATE images SET rating=?1, xmp_label=?2, xmp_flag=?3, xmp_caption=?4 WHERE path=?5",
        params![data.rating.map(|r| r as i64), label, flag, data.caption, path_str.as_ref()],
    );
}

// ── pHash cache ───────────────────────────────────────────────────────────

/// Return cached pHash if the file's mtime still matches.
pub fn fetch_phash(path: &Path, db_path: &Path) -> Option<u64> {
    let conn = Connection::open(db_path).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    conn.query_row(
        "SELECT phash FROM phashes WHERE path = ?1 AND mtime = ?2",
        params![path.to_string_lossy().as_ref(), mtime],
        |row| row.get::<_, i64>(0),
    )
    .ok()
    .map(|v| v as u64)
}

/// Persist a pHash for the given file path.
pub fn store_phash(path: &Path, db_path: &Path, phash: u64) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(1));
    let mtime = file_mtime(path);
    let _ = conn.execute(
        "INSERT OR REPLACE INTO phashes (path, mtime, phash, cached_at)
         VALUES (?1, ?2, ?3, strftime('%s','now'))",
        params![path.to_string_lossy().as_ref(), mtime, phash as i64],
    );
}

/// Fetch all cached pHashes for the given paths in a single connection.
/// Only entries whose mtime still matches the current file mtime are returned.
pub fn fetch_phash_batch(
    paths: &[PathBuf],
    db_path: &Path,
) -> std::collections::HashMap<PathBuf, u64> {
    let mut out = std::collections::HashMap::new();
    let Ok(conn) = Connection::open(db_path) else { return out };
    for chunk in paths.chunks(500) {
        let placeholders = std::iter::repeat("?")
            .take(chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT path, mtime, phash FROM phashes WHERE path IN ({placeholders})"
        );
        let Ok(mut stmt) = conn.prepare(&sql) else { continue };
        let params_iter = rusqlite::params_from_iter(
            chunk.iter().map(|p| p.to_string_lossy().into_owned()),
        );
        let Ok(rows) = stmt.query_map(params_iter, |row| {
            let path_str: String = row.get(0)?;
            let stored_mtime: i64 = row.get(1)?;
            let phash: i64 = row.get(2)?;
            Ok((PathBuf::from(path_str), stored_mtime, phash as u64))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            let (path, stored_mtime, phash) = row;
            if file_mtime(&path) == stored_mtime {
                out.insert(path, phash);
            }
        }
    }
    out
}

/// Async wrapper for `fetch_phash_batch`.
pub async fn fetch_phash_batch_async(
    paths: Vec<PathBuf>,
    db_path: PathBuf,
) -> std::collections::HashMap<PathBuf, u64> {
    tokio::task::spawn_blocking(move || fetch_phash_batch(&paths, &db_path))
        .await
        .unwrap_or_default()
}

/// Delete thumbnail and pHash cache entries older than `max_age_days` days.
///
/// Only rows with a valid `cached_at` value are considered; rows where
/// `cached_at IS NULL` (migrated from a pre-TTL schema) are kept so that a
/// schema upgrade alone does not silently evict the entire thumbnail cache.
/// VACUUM is intentionally omitted: in WAL mode SQLite reclaims pages
/// incrementally, and running VACUUM here would briefly hold an exclusive lock
/// that blocks concurrent thumbnail generation during startup.
pub fn prune_cache(db_path: &Path, max_age_days: u32) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(5));
    let cutoff = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
        - (max_age_days as i64 * 86_400);
    let _ = conn.execute_batch(&format!(
        "DELETE FROM thumbnails   WHERE cached_at IS NOT NULL AND cached_at < {cutoff};
         DELETE FROM phashes      WHERE cached_at IS NOT NULL AND cached_at < {cutoff};
         DELETE FROM file_hashes  WHERE cached_at IS NOT NULL AND cached_at < {cutoff};"
    ));
}

// ── SHA-256 cache ─────────────────────────────────────────────────────────

/// Fetch all cached SHA-256 hashes for the given paths.
/// Only entries whose mtime still matches the current file mtime are returned.
pub fn fetch_sha_batch(
    paths: &[PathBuf],
    db_path: &Path,
) -> std::collections::HashMap<PathBuf, [u8; 32]> {
    let mut out = std::collections::HashMap::new();
    let Ok(conn) = Connection::open(db_path) else { return out };
    for chunk in paths.chunks(500) {
        let placeholders = std::iter::repeat("?")
            .take(chunk.len())
            .collect::<Vec<_>>()
            .join(",");
        let sql = format!(
            "SELECT path, mtime, sha256 FROM file_hashes WHERE path IN ({placeholders})"
        );
        let Ok(mut stmt) = conn.prepare(&sql) else { continue };
        let params_iter = rusqlite::params_from_iter(
            chunk.iter().map(|p| p.to_string_lossy().into_owned()),
        );
        let Ok(rows) = stmt.query_map(params_iter, |row| {
            let path_str: String = row.get(0)?;
            let stored_mtime: i64 = row.get(1)?;
            let sha_blob: Vec<u8> = row.get(2)?;
            Ok((PathBuf::from(path_str), stored_mtime, sha_blob))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            let (path, stored_mtime, sha_blob) = row;
            if file_mtime(&path) == stored_mtime {
                if sha_blob.len() == 32 {
                    let mut arr = [0u8; 32];
                    arr.copy_from_slice(&sha_blob);
                    out.insert(path, arr);
                }
            }
        }
    }
    out
}

/// Persist SHA-256 hashes in a single transaction.
pub fn store_sha_batch(items: &[(PathBuf, i64, [u8; 32])], db_path: &Path) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let _ = conn.busy_timeout(std::time::Duration::from_secs(5));
    let Ok(tx) = conn.unchecked_transaction() else { return };
    for (path, mtime, sha) in items {
        let _ = tx.execute(
            "INSERT OR REPLACE INTO file_hashes (path, mtime, sha256, cached_at)
             VALUES (?1, ?2, ?3, strftime('%s','now'))",
            rusqlite::params![path.to_string_lossy().as_ref(), mtime, sha.as_ref()],
        );
    }
    let _ = tx.commit();
}

fn upsert(conn: &Connection, path: &Path, exif: &ExifData, mtime: i64) -> Result<()> {
    let path_str = path.to_string_lossy();
    let filename = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    conn.execute(
        "INSERT INTO images
            (path, filename, make, model, datetime, subsec, exposure, fnumber, iso,
             focal_len, focal_len_35mm, lens_model, img_width, img_height, software, artist,
             exposure_bias, flash, white_balance, mtime,
             exif_image_description, exif_user_comment)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)
         ON CONFLICT(path) DO UPDATE SET
            make=excluded.make, model=excluded.model,
            datetime=excluded.datetime, subsec=excluded.subsec,
            exposure=excluded.exposure,
            fnumber=excluded.fnumber, iso=excluded.iso,
            focal_len=excluded.focal_len,
            focal_len_35mm=excluded.focal_len_35mm,
            lens_model=excluded.lens_model,
            img_width=excluded.img_width, img_height=excluded.img_height,
            software=excluded.software,
            artist=excluded.artist,
            exposure_bias=excluded.exposure_bias,
            flash=excluded.flash,
            white_balance=excluded.white_balance,
            mtime=excluded.mtime,
            exif_image_description=excluded.exif_image_description,
            exif_user_comment=excluded.exif_user_comment,
            indexed_at=strftime('%s','now')",
        params![
            path_str.as_ref(),
            filename,
            exif.make,
            exif.model,
            exif.datetime,
            exif.subsec,
            exif.exposure_time,
            exif.fnumber,
            exif.iso,
            exif.focal_length,
            exif.focal_length_35mm,
            exif.lens_model,
            exif.width,
            exif.height,
            exif.software,
            exif.artist,
            exif.exposure_bias,
            exif.flash,
            exif.white_balance,
            mtime,
            exif.image_description,
            exif.user_comment,
        ],
    )?;
    Ok(())
}
