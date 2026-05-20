use bridge_core::db::{ensure_schema, fetch_exif_batch, open_connection, update_xmp};
use bridge_core::xmp::{Flag, Label, XmpData};
use std::path::{Path, PathBuf};

fn setup(tag: &str) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("bridge_db_{tag}"));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("cache.db");
    let _ = std::fs::remove_file(&db); // start fresh
    assert!(ensure_schema(&db), "ensure_schema failed");
    (dir, db)
}

fn make_fake_image(dir: &Path, name: &str) -> PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, b"fake image data").unwrap();
    p
}

fn current_mtime(path: &Path) -> i64 {
    std::fs::metadata(path)
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn insert_row(db: &Path, img: &Path, mtime: Option<i64>, make: &str) {
    use rusqlite::{params, Connection};
    let conn = Connection::open(db).unwrap();
    conn.execute(
        "INSERT OR REPLACE INTO images (path, filename, make, mtime) VALUES (?1,?2,?3,?4)",
        params![
            img.to_string_lossy().as_ref(),
            img.file_name().unwrap().to_string_lossy().as_ref(),
            make,
            mtime,
        ],
    )
    .unwrap();
}

fn path_mtime(path: &Path) -> (PathBuf, i64) {
    (path.to_path_buf(), current_mtime(path))
}

// ── mtime 検証テスト ──────────────────────────────────────────────────────────

#[test]
fn cache_hit_with_matching_mtime() {
    let (dir, db) = setup("hit");
    let img = make_fake_image(&dir, "img.arw");
    let mtime = current_mtime(&img);

    insert_row(&db, &img, Some(mtime), "Sony");

    let conn = open_connection(&db).unwrap();
    let result = fetch_exif_batch(&[path_mtime(&img)], &conn);
    assert!(
        result.contains_key(&img),
        "matching mtime must return cached row"
    );
    assert_eq!(result[&img].make.as_deref(), Some("Sony"));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_miss_with_stale_mtime() {
    let (dir, db) = setup("stale");
    let img = make_fake_image(&dir, "img.arw");

    // Insert with obviously wrong mtime
    insert_row(&db, &img, Some(9999), "Nikon");

    let conn = open_connection(&db).unwrap();
    let result = fetch_exif_batch(&[path_mtime(&img)], &conn);
    assert!(result.is_empty(), "stale mtime row must not be returned");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cache_miss_with_null_mtime_legacy_row() {
    let (dir, db) = setup("null");
    let img = make_fake_image(&dir, "legacy.arw");

    // Simulate a pre-migration row with NULL mtime
    insert_row(&db, &img, None, "Leica");

    let conn = open_connection(&db).unwrap();
    let result = fetch_exif_batch(&[path_mtime(&img)], &conn);
    assert!(
        result.is_empty(),
        "NULL mtime (legacy) row must be treated as stale"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn batch_filters_stale_among_multiple() {
    let (dir, db) = setup("multi");
    let fresh = make_fake_image(&dir, "fresh.arw");
    let stale = make_fake_image(&dir, "stale.arw");

    insert_row(&db, &fresh, Some(current_mtime(&fresh)), "Canon");
    insert_row(&db, &stale, Some(9999), "Fuji");

    let conn = open_connection(&db).unwrap();
    let result = fetch_exif_batch(&[path_mtime(&fresh), path_mtime(&stale)], &conn);
    assert!(result.contains_key(&fresh), "fresh entry must be included");
    assert!(!result.contains_key(&stale), "stale entry must be excluded");

    let _ = std::fs::remove_dir_all(&dir);
}

// ── マイグレーション互換性テスト ──────────────────────────────────────────────

#[test]
fn migration_preserves_xmp_columns() {
    let (dir, db) = setup("migrate");

    // Insert a row with XMP data (simulating an existing user DB)
    {
        use rusqlite::{params, Connection};
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "INSERT INTO images (path, filename, make, rating, xmp_label)
             VALUES (?1,'photo.arw','Olympus',4,'Red')",
            params!["/test/photo.arw"],
        )
        .unwrap();
    }

    // Re-running ensure_schema (migration) must preserve existing data
    assert!(ensure_schema(&db));

    {
        use rusqlite::Connection;
        let conn = Connection::open(&db).unwrap();
        let (rating, label): (Option<i64>, Option<String>) = conn
            .query_row(
                "SELECT rating, xmp_label FROM images WHERE path = '/test/photo.arw'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(rating, Some(4), "rating must survive migration");
        assert_eq!(
            label.as_deref(),
            Some("Red"),
            "xmp_label must survive migration"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

// ── XMP DB 同期テスト ─────────────────────────────────────────────────────────

#[test]
fn update_xmp_syncs_rating_label_flag() {
    let (dir, db) = setup("xmp_sync");
    let img = make_fake_image(&dir, "shot.arw");

    insert_row(&db, &img, Some(current_mtime(&img)), "Canon");

    let xmp = XmpData {
        rating: Some(3),
        label: Some(Label::Green),
        flag: Some(Flag::Pick),
        ..Default::default()
    };
    let conn = open_connection(&db).unwrap();
    update_xmp(&img, &conn, &xmp);

    {
        use rusqlite::Connection;
        let conn = Connection::open(&db).unwrap();
        let (rating, label, flag): (Option<i64>, Option<String>, Option<String>) = conn
            .query_row(
                "SELECT rating, xmp_label, xmp_flag FROM images WHERE path = ?1",
                [img.to_string_lossy().as_ref()],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(rating, Some(3));
        assert_eq!(label.as_deref(), Some("Green"));
        assert_eq!(flag.as_deref(), Some("Pick"));
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn update_xmp_clears_fields_when_none() {
    let (dir, db) = setup("xmp_clear");
    let img = make_fake_image(&dir, "shot.arw");

    // Seed with a rating
    {
        use rusqlite::{params, Connection};
        let conn = Connection::open(&db).unwrap();
        conn.execute(
            "INSERT INTO images (path, filename, make, mtime, rating, xmp_label)
             VALUES (?1,'shot.arw','Sony',?2,5,'Red')",
            params![img.to_string_lossy().as_ref(), current_mtime(&img)],
        )
        .unwrap();
    }

    // Clear everything
    let xmp = XmpData {
        ..Default::default()
    };
    let conn = open_connection(&db).unwrap();
    update_xmp(&img, &conn, &xmp);

    {
        use rusqlite::Connection;
        let conn = Connection::open(&db).unwrap();
        let (rating, label): (Option<i64>, Option<String>) = conn
            .query_row(
                "SELECT rating, xmp_label FROM images WHERE path = ?1",
                [img.to_string_lossy().as_ref()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert!(rating.is_none(), "rating must be cleared");
        assert!(label.is_none(), "xmp_label must be cleared");
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn update_xmp_no_panic_without_images_row() {
    let (dir, db) = setup("xmp_no_row");
    // Image file exists but no EXIF row in DB. fetch_or_index inside
    // update_xmp tries to read EXIF from the fake file (returns None),
    // so the row is never inserted. The subsequent UPDATE silently affects
    // 0 rows. This must not panic.
    let img = make_fake_image(&dir, "new.arw");
    let xmp = XmpData {
        rating: Some(2),
        ..Default::default()
    };
    let conn = open_connection(&db).unwrap();
    update_xmp(&img, &conn, &xmp); // must not panic

    let _ = std::fs::remove_dir_all(&dir);
}
