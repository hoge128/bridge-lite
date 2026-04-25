use std::path::{Path, PathBuf};

use rusqlite::{Connection, Result, params};

use crate::metadata::ExifData;
use crate::xmp::XmpData;

// ── Schema ─────────────────────────────────────────────────────────────────

/// Bump when EXIF extraction logic changes in a way that requires re-indexing
/// existing rows. Previous DBs without this key are treated as version 1.
/// v2: software column populated.
/// v3: subsec column added (SubSecTimeOriginal for Phase 10-B timestamp grouping).
pub const EXIF_SCHEMA_VERSION: i32 = 3;

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "
        PRAGMA journal_mode = WAL;

        CREATE TABLE IF NOT EXISTS images (
            path        TEXT PRIMARY KEY,
            filename    TEXT NOT NULL,
            file_size   INTEGER,
            make        TEXT,
            model       TEXT,
            datetime    TEXT,
            subsec      TEXT,
            exposure    TEXT,
            fnumber     TEXT,
            iso         INTEGER,
            focal_len   TEXT,
            img_width   INTEGER,
            img_height  INTEGER,
            software    TEXT,
            indexed_at  INTEGER DEFAULT (strftime('%s', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_images_datetime ON images(datetime);
        CREATE INDEX IF NOT EXISTS idx_images_make     ON images(make);
        CREATE INDEX IF NOT EXISTS idx_images_model    ON images(model);
        CREATE INDEX IF NOT EXISTS idx_images_iso      ON images(iso);

        CREATE TABLE IF NOT EXISTS thumbnails (
            path  TEXT PRIMARY KEY,
            mtime INTEGER NOT NULL,
            jpeg  BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT
        );
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

pub fn db_path() -> PathBuf {
    let base = dirs_next::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("bridge-lite");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("cache.db")
}

pub fn ensure_schema(db_path: &Path) -> bool {
    Connection::open(db_path)
        .and_then(|conn| {
            init_schema(&conn)?;
            migrate_xmp_columns(&conn);
            migrate_to_current_version(&conn)?;
            Ok(())
        })
        .is_ok()
}

/// Add XMP rating columns to the images table when upgrading an existing DB.
/// ALTER TABLE fails silently on re-run (column already exists).
fn migrate_xmp_columns(conn: &Connection) {
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN rating    INTEGER;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN xmp_label TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN xmp_flag  TEXT;");
    let _ = conn.execute_batch("ALTER TABLE images ADD COLUMN software  TEXT;");
}

/// Check DB for cached EXIF. On miss, read from file and cache the result.
pub fn fetch_or_index(path: &Path, db_path: &Path) -> Option<ExifData> {
    let conn = Connection::open(db_path).ok()?;

    // Cache hit
    if let Some(exif) = query_exif(&conn, path) {
        return Some(exif);
    }

    // Cache miss: read from file
    let exif = crate::metadata::read_exif_sync(path)?;
    let _ = upsert(&conn, path, &exif);
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
/// Paths with no DB row are omitted from the result. The caller discovers misses
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
            "SELECT path, make, model, datetime, subsec, exposure, fnumber, iso, \
                    focal_len, img_width, img_height, software \
             FROM images WHERE path IN ({placeholders})"
        );
        let Ok(mut stmt) = conn.prepare(&sql) else { continue };
        let params = rusqlite::params_from_iter(
            chunk.iter().map(|p| p.to_string_lossy().into_owned()),
        );
        let Ok(rows) = stmt.query_map(params, |row| {
            let path_str: String = row.get(0)?;
            Ok((
                PathBuf::from(path_str),
                ExifData {
                    make: row.get(1)?,
                    model: row.get(2)?,
                    datetime: row.get(3)?,
                    subsec: row.get(4)?,
                    exposure_time: row.get(5)?,
                    fnumber: row.get(6)?,
                    iso: row.get(7)?,
                    focal_length: row.get(8)?,
                    width: row.get(9)?,
                    height: row.get(10)?,
                    software: row.get(11)?,
                },
            ))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            out.insert(row.0, row.1);
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
        "INSERT OR REPLACE INTO thumbnails (path, mtime, jpeg) VALUES (?1, ?2, ?3)",
        params![path.to_string_lossy().as_ref(), mtime, jpeg],
    );
}

// ── Internal helpers ───────────────────────────────────────────────────────

fn query_exif(conn: &Connection, path: &Path) -> Option<ExifData> {
    let path_str = path.to_string_lossy();
    conn.query_row(
        "SELECT make, model, datetime, subsec, exposure, fnumber, iso, focal_len,
                img_width, img_height, software
         FROM images WHERE path = ?1",
        params![path_str.as_ref()],
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
                width: row.get(8)?,
                height: row.get(9)?,
                software: row.get(10)?,
            })
        },
    )
    .ok()
}

pub fn update_xmp(path: &Path, db_path: &Path, data: &XmpData) {
    let Ok(conn) = Connection::open(db_path) else { return };
    let path_str = path.to_string_lossy();
    let label = data.label.map(|l| l.as_str().to_string());
    let flag  = data.flag.map(|f| f.as_str().to_string());
    let _ = conn.execute(
        "UPDATE images SET rating=?1, xmp_label=?2, xmp_flag=?3 WHERE path=?4",
        params![data.rating.map(|r| r as i64), label, flag, path_str.as_ref()],
    );
}

fn upsert(conn: &Connection, path: &Path, exif: &ExifData) -> Result<()> {
    let path_str = path.to_string_lossy();
    let filename = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();

    conn.execute(
        "INSERT INTO images
            (path, filename, make, model, datetime, subsec, exposure, fnumber, iso,
             focal_len, img_width, img_height, software)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
         ON CONFLICT(path) DO UPDATE SET
            make=excluded.make, model=excluded.model,
            datetime=excluded.datetime, subsec=excluded.subsec,
            exposure=excluded.exposure,
            fnumber=excluded.fnumber, iso=excluded.iso,
            focal_len=excluded.focal_len,
            img_width=excluded.img_width, img_height=excluded.img_height,
            software=excluded.software,
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
            exif.width,
            exif.height,
            exif.software,
        ],
    )?;
    Ok(())
}
