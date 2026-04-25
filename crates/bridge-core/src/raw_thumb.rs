/// Extract embedded JPEG preview data from TIFF-based RAW files.
///
/// Sony ARW, Canon CR2, Nikon NEF, and DNG files are TIFF-based and embed
/// JPEG previews at multiple quality levels in their IFD chain.
///
/// Verified offsets for Sony ARW (DSE06383.ARW):
///   IFD1  (In(1)) =   8 KB  – small thumbnail  ← use for grid thumbs
///   IFD0  (In(0)) = 174 KB  – medium preview    ← use for sidebar preview
///   IFD2  (In(2)) =   3 MB  – full-size JPEG    ← reserved for Phase 5

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use exif::{In, Tag, Value};

/// Quality / size of the requested embedded JPEG.
pub enum Quality {
    /// Small (~8 KB) thumbnail stored in IFD1. Fastest to decode.
    Thumbnail,
    /// Medium (~174 KB) preview stored in IFD0. Good for sidebar display.
    Preview,
    /// Full-size (~3 MB) JPEG stored in IFD2. Best quality without LibRaw.
    Full,
}

/// Returns raw JPEG bytes extracted from the RAW file.
/// Returns `None` if the format is unsupported or extraction fails.
pub fn extract(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let ifd = match quality {
        Quality::Thumbnail => In::THUMBNAIL, // In(1)
        Quality::Preview   => In::PRIMARY,   // In(0)
        Quality::Full      => In(2),         // IFD2 – full-size embedded JPEG (~3 MB)
    };
    extract_from_ifd(path, ifd)
}

fn extract_from_ifd(path: &Path, ifd: In) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut reader = std::io::BufReader::new(file);

    let exif = exif::Reader::new()
        .read_from_container(&mut reader)
        .ok()?;

    let offset = exif
        .get_field(Tag::JPEGInterchangeFormat, ifd)
        .and_then(|f| match &f.value {
            Value::Long(v) => v.first().copied(),
            _ => None,
        })? as u64;

    let length = exif
        .get_field(Tag::JPEGInterchangeFormatLength, ifd)
        .and_then(|f| match &f.value {
            Value::Long(v) => v.first().copied(),
            _ => None,
        })? as usize;

    if length < 10 || offset + length as u64 > file_len {
        return None;
    }

    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(offset)).ok()?;
    let mut buf = vec![0u8; length];
    file.read_exact(&mut buf).ok()?;

    // Verify JPEG SOI marker
    if buf.starts_with(&[0xFF, 0xD8]) {
        Some(buf)
    } else {
        None
    }
}
