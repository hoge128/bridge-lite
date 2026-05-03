/// Extract embedded JPEG preview data from various RAW file formats.
///
/// Supported formats and extraction strategies:
///
/// | Format | Magic / Header             | Strategy                                     |
/// |--------|----------------------------|----------------------------------------------|
/// | ARW    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | CR2    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | CR3    | ftyp (ISOBMFF)             | Walk MP4 boxes → uuid PRVW (UUID eaf42b5e…) |
/// | DNG    | II + 0x002A (TIFF)         | kamadak-exif → fallback SubIFD Compression=7 |
/// | NEF    | II + 0x002A (TIFF)         | kamadak-exif → fallback SubIFD JpegOffset    |
/// | ORF    | II + 0x4F52 (Olympus TIFF) | Scan file for JPEG SOI/EOI pairs             |
/// | PEF    | II + 0x002A (TIFF)         | kamadak-exif → IFD1 JPEGInterchangeFormat    |
/// | RAF    | FUJIFILMCCD-RAW header     | Read JPEG offset/size from bytes [84:92]     |
/// | RW2    | II + 0x0055 (Panasonic)    | Walk IFD0 tag 0x002E → scan blob            |

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use exif::{In, Tag, Value};

/// Quality / size of the requested embedded JPEG.
pub enum Quality {
    /// Small thumbnail (IFD1 or smallest SubIFD). Fastest to decode.
    Thumbnail,
    /// Medium preview (IFD0 or mid-size SubIFD). Good for sidebar display.
    Preview,
    /// Full-size JPEG (IFD2 or largest SubIFD).
    Full,
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry point
// ─────────────────────────────────────────────────────────────────────────────

/// Returns raw JPEG bytes extracted from the RAW file, or `None` on failure.
pub fn extract(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let mut header = [0u8; 16];
    {
        let mut f = std::fs::File::open(path).ok()?;
        f.read_exact(&mut header).ok()?;
    }

    // RAF: proprietary "FUJIFILMCCD-RAW " header
    if &header[..16] == b"FUJIFILMCCD-RAW " {
        return extract_raf(path);
    }

    // CR3: ISOBMFF container (ftyp box at offset 0)
    if &header[4..8] == b"ftyp" {
        return extract_cr3(path, quality);
    }

    // TIFF-based: determine endianness and magic
    let is_le = &header[..2] == b"II";
    let magic = if is_le {
        u16::from_le_bytes([header[2], header[3]])
    } else {
        u16::from_be_bytes([header[2], header[3]])
    };

    match magic {
        0x0055 => extract_rw2(path, quality),    // Panasonic RW2
        0x4F52 => extract_orf(path, quality),    // Olympus ORF
        0x002A => {
            // Standard TIFF: try kamadak-exif IFDs, fall back to SubIFD walk.
            //
            // IFD layout varies by format:
            //   CR2  – IFD1=small JPEG (~18 KB); IFD2=uncompressed RGB (no JPEG)
            //   PEF  – IFD1=small JPEG (~7 KB);  IFD2=large JPEG (~4 MB)
            //   ARW  – IFD1=small JPEG;           SubIFDs=large previews
            //   NEF  – IFD1=small JPEG;           SubIFDs=large previews
            //
            // Quality::Preview should return the best-quality JPEG available:
            //   1. In::PRIMARY (IFD0) — standard EXIF
            //   2. In(2)             — PEF IFD2 large preview
            //   3. In::THUMBNAIL     — CR2/PEF IFD1 small thumbnail (last resort)
            //   4. SubIFD walk       — NEF/DNG/ARW
            match quality {
                Quality::Thumbnail =>
                    extract_from_ifd(path, In::THUMBNAIL)
                        .or_else(|| extract_tiff_subifd(path, is_le, quality)),
                Quality::Preview =>
                    extract_from_ifd(path, In::PRIMARY)
                        .or_else(|| extract_from_ifd(path, In(2)))
                        .or_else(|| extract_from_ifd(path, In::THUMBNAIL))
                        .or_else(|| extract_tiff_subifd(path, is_le, quality)),
                Quality::Full =>
                    extract_from_ifd(path, In(2))
                        .or_else(|| extract_from_ifd(path, In::PRIMARY))
                        .or_else(|| extract_from_ifd(path, In::THUMBNAIL))
                        .or_else(|| extract_tiff_subifd(path, is_le, quality)),
            }
        }
        _ => None,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Standard TIFF path (ARW, CR2, PEF, …)
// ─────────────────────────────────────────────────────────────────────────────

fn extract_from_ifd(path: &Path, ifd: In) -> Option<Vec<u8>> {
    let file = std::fs::File::open(path).ok()?;
    let file_len = file.metadata().ok()?.len();
    let mut reader = std::io::BufReader::new(file);

    let exif = exif::Reader::new().read_from_container(&mut reader).ok()?;

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

    let mut f = std::fs::File::open(path).ok()?;
    f.seek(SeekFrom::Start(offset)).ok()?;
    let mut buf = vec![0u8; length];
    f.read_exact(&mut buf).ok()?;

    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// SubIFD fallback (NEF / DNG)
// ─────────────────────────────────────────────────────────────────────────────
//
// Nikon NEF stores JPEG previews in SubIFDs (tag 0x014A) with standard
// JPEGInterchangeFormat / JPEGInterchangeFormatLength tags.
//
// DNG stores JPEG previews in SubIFDs with Compression=7 (JPEG) and the
// offset/length via StripOffsets / StripByteCounts instead.
//
// kamadak-exif only checks the standard IFD chain (IFD0 + IFD1), so SubIFDs
// are invisible to it. We walk them manually.

fn extract_tiff_subifd(path: &Path, is_le: bool, quality: Quality) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;
    let file_len = data.len() as u64;

    let r16 = |off: usize| -> Option<u16> {
        let b = data.get(off..off + 2)?;
        Some(if is_le { u16::from_le_bytes([b[0], b[1]]) } else { u16::from_be_bytes([b[0], b[1]]) })
    };
    let r32 = |off: usize| -> Option<u32> {
        let b = data.get(off..off + 4)?;
        Some(if is_le { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) } else { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) })
    };

    let ifd0_off = r32(4)? as usize;

    // Collect all JPEG candidates from SubIFDs
    // Each entry: (jpeg_offset, jpeg_length)
    let mut candidates: Vec<(u64, usize)> = Vec::new();

    // Walk IFD0 to find tag 0x014A (SubIFDs)
    let entry_count = r16(ifd0_off)? as usize;
    let mut subifd_offsets: Vec<usize> = Vec::new();

    for i in 0..entry_count {
        let base = ifd0_off + 2 + i * 12;
        let tag = r16(base)?;
        if tag == 0x014A {
            // SubIFDs: array of LONG offsets
            let count = r32(base + 4)? as usize;
            let val_or_off = r32(base + 8)?;
            // If count * 4 > 4, val_or_off is an offset; otherwise inline
            if count * 4 > 4 {
                for j in 0..count {
                    if let Some(sub) = r32(val_or_off as usize + j * 4) {
                        subifd_offsets.push(sub as usize);
                    }
                }
            } else {
                subifd_offsets.push(val_or_off as usize);
            }
            break;
        }
    }

    for sub_off in subifd_offsets {
        if sub_off + 2 > data.len() {
            continue;
        }
        let sub_count = match r16(sub_off) {
            Some(c) => c as usize,
            None => continue,
        };

        let mut jpeg_off: Option<u64> = None;
        let mut jpeg_len: Option<usize> = None;
        let mut strip_off: Option<u64> = None;
        let mut strip_len: Option<usize> = None;
        let mut compression: u32 = 1;

        for i in 0..sub_count {
            let base = sub_off + 2 + i * 12;
            if base + 12 > data.len() {
                break;
            }
            let tag = match r16(base) { Some(t) => t, None => break };
            let val = match r32(base + 8) { Some(v) => v, None => break };

            match tag {
                0x0201 => jpeg_off  = Some(val as u64),  // JPEGInterchangeFormat
                0x0202 => jpeg_len  = Some(val as usize), // JPEGInterchangeFormatLength
                0x0111 => strip_off = Some(val as u64),   // StripOffsets
                0x0117 => strip_len = Some(val as usize), // StripByteCounts
                0x0103 => compression = val,               // Compression (7 = JPEG)
                _ => {}
            }
        }

        // NEF style: explicit JPEG pointer
        if let (Some(off), Some(len)) = (jpeg_off, jpeg_len) {
            if len >= 10 && off + len as u64 <= file_len {
                candidates.push((off, len));
            }
        }
        // DNG style: Compression=7 with strip offsets
        if compression == 7 {
            if let (Some(off), Some(len)) = (strip_off, strip_len) {
                if len >= 10 && off + len as u64 <= file_len {
                    candidates.push((off, len));
                }
            }
        }
    }

    if candidates.is_empty() {
        return None;
    }

    // Sort by JPEG length
    candidates.sort_by_key(|&(_, len)| len);

    let (off, len) = match quality {
        Quality::Thumbnail => candidates[0],
        Quality::Preview   => candidates[candidates.len() / 2], // middle size
        Quality::Full      => *candidates.last()?,
    };

    let buf = data.get(off as usize..off as usize + len)?.to_vec();
    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// Panasonic RW2
// ─────────────────────────────────────────────────────────────────────────────

fn extract_rw2(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let mut file = std::fs::File::open(path).ok()?;

    let mut hdr = [0u8; 8];
    file.read_exact(&mut hdr).ok()?;
    let ifd0_off = u32::from_le_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]) as u64;

    // Walk IFD0 to find tag 0x002E (Panasonic preview blob)
    file.seek(SeekFrom::Start(ifd0_off)).ok()?;
    let mut cnt_buf = [0u8; 2];
    file.read_exact(&mut cnt_buf).ok()?;
    let entry_count = u16::from_le_bytes(cnt_buf) as usize;

    let mut blob_offset: u64 = 0;
    let mut blob_size: usize = 0;

    for _ in 0..entry_count {
        let mut entry = [0u8; 12];
        if file.read_exact(&mut entry).is_err() { break; }
        let tag = u16::from_le_bytes([entry[0], entry[1]]);
        let count = u32::from_le_bytes([entry[4], entry[5], entry[6], entry[7]]);
        let val_or_off = u32::from_le_bytes([entry[8], entry[9], entry[10], entry[11]]);

        if tag == 0x002E {
            blob_offset = val_or_off as u64;
            blob_size = count as usize;
            break;
        }
    }

    if blob_size == 0 { return None; }

    let mut file = std::fs::File::open(path).ok()?;
    file.seek(SeekFrom::Start(blob_offset)).ok()?;
    let mut blob = vec![0u8; blob_size];
    file.read_exact(&mut blob).ok()?;

    let jpegs = collect_jpegs(&blob);
    if jpegs.is_empty() { return None; }

    let (rel_off, jpeg_len) = match quality {
        Quality::Thumbnail => jpegs[0],
        Quality::Preview | Quality::Full => *jpegs.last()?,
    };

    Some(blob[rel_off..rel_off + jpeg_len].to_vec())
}

// ─────────────────────────────────────────────────────────────────────────────
// Olympus ORF (magic 0x4F52)
// ─────────────────────────────────────────────────────────────────────────────
//
// ORF uses the same TIFF structure as standard files but with magic 0x4F52
// ('OR'). Preview JPEGs are not referenced by standard IFD tags; instead we
// scan the first portion of the file for JPEG SOI/EOI pairs.

fn extract_orf(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;

    // Scan for JPEG SOIs in the first 10% of the file to avoid raw image data
    let scan_limit = (data.len() / 10).max(128 * 1024);
    let jpegs = collect_jpegs(&data[..scan_limit]);
    if jpegs.is_empty() { return None; }

    let (rel_off, jpeg_len) = match quality {
        Quality::Thumbnail => jpegs[0],
        Quality::Preview | Quality::Full => *jpegs.last()?,
    };

    Some(data[rel_off..rel_off + jpeg_len].to_vec())
}

// ─────────────────────────────────────────────────────────────────────────────
// Fujifilm RAF
// ─────────────────────────────────────────────────────────────────────────────
//
// RAF header layout (all fields big-endian):
//   [  0..16] "FUJIFILMCCD-RAW " signature
//   [ 16..20] Format version string
//   [ 20..28] Camera model ID
//   [ 28..60] Camera model string
//   [ 60..84] (various fields)
//   [ 84..88] JPEG preview offset (from file start)
//   [ 88..92] JPEG preview size

fn extract_raf(path: &Path) -> Option<Vec<u8>> {
    let mut f = std::fs::File::open(path).ok()?;

    let mut hdr = [0u8; 92];
    f.read_exact(&mut hdr).ok()?;

    let jpeg_off = u32::from_be_bytes([hdr[84], hdr[85], hdr[86], hdr[87]]) as u64;
    let jpeg_len = u32::from_be_bytes([hdr[88], hdr[89], hdr[90], hdr[91]]) as usize;

    if jpeg_len < 10 { return None; }

    f.seek(SeekFrom::Start(jpeg_off)).ok()?;
    let mut buf = vec![0u8; jpeg_len];
    f.read_exact(&mut buf).ok()?;

    if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
}

// ─────────────────────────────────────────────────────────────────────────────
// Canon CR3 (ISOBMFF / MP4 container)
// ─────────────────────────────────────────────────────────────────────────────
//
// CR3 wraps RAW data in an ISO Base Media File Format container. Canon stores
// preview JPEGs in top-level `uuid` boxes with specific GUIDs:
//
//   eaf42b5e1c984b88b9fbb7dc406e4d16  — PRVW (preview JPEG)
//   be7acfcb97a942e89c71999491e3afac  — XPacket metadata (no JPEG)
//
// Within the PRVW uuid box, the JPEG starts at offset +56 from the box start.

const CR3_PRVW_UUID: [u8; 16] = [
    0xea, 0xf4, 0x2b, 0x5e, 0x1c, 0x98, 0x4b, 0x88,
    0xb9, 0xfb, 0xb7, 0xdc, 0x40, 0x6e, 0x4d, 0x16,
];
const CR3_THMB_UUID: [u8; 16] = [
    0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0,
    0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48,
];

fn extract_cr3(path: &Path, quality: Quality) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;
    let file_len = data.len();

    let mut offset = 0usize;
    let mut prvw: Option<(usize, usize)> = None; // (offset, size) of PRVW JPEG
    let mut thmb: Option<(usize, usize)> = None; // (offset, size) of THMB JPEG

    while offset + 8 <= file_len {
        let box_size = u32::from_be_bytes([
            data[offset], data[offset+1], data[offset+2], data[offset+3],
        ]) as usize;
        let box_type = &data[offset+4..offset+8];

        if box_size < 8 || offset + box_size > file_len {
            break;
        }

        if box_type == b"uuid" && offset + 24 <= file_len {
            let uuid = &data[offset+8..offset+24];

            if uuid == CR3_PRVW_UUID {
                // JPEG size is stored at box+52 (big-endian u32); JPEG data at box+56.
                if offset + 56 <= file_len {
                    let sz_bytes = &data[offset+52..offset+56];
                    let jpeg_size = u32::from_be_bytes([sz_bytes[0], sz_bytes[1], sz_bytes[2], sz_bytes[3]]) as usize;
                    let jpeg_start = offset + 56;
                    if jpeg_size >= 10 && jpeg_start + jpeg_size <= file_len
                        && data[jpeg_start..jpeg_start+2] == [0xFF, 0xD8]
                    {
                        prvw = Some((jpeg_start, jpeg_size));
                    }
                }
            } else if uuid == CR3_THMB_UUID {
                // Thumbnail JPEG: scan the inner content of this uuid
                let inner = &data[offset+24..offset+box_size];
                let found = collect_jpegs(inner);
                if let Some(&(rel, sz)) = found.last() {
                    thmb = Some((offset + 24 + rel, sz));
                }
            }
        }

        offset += box_size;
    }

    match quality {
        Quality::Thumbnail => {
            // Use THMB if available, otherwise PRVW
            let (jpeg_off, jpeg_len) = thmb.or(prvw)?;
            let buf = data.get(jpeg_off..jpeg_off + jpeg_len)?.to_vec();
            if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
        }
        Quality::Preview | Quality::Full => {
            let (jpeg_off, jpeg_len) = prvw?;
            let buf = data.get(jpeg_off..jpeg_off + jpeg_len)?.to_vec();
            if buf.starts_with(&[0xFF, 0xD8]) { Some(buf) } else { None }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// JPEG helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Scan a byte slice for JPEG SOI/EOI pairs. Returns (offset, length) pairs
/// sorted by ascending length.
fn collect_jpegs(data: &[u8]) -> Vec<(usize, usize)> {
    let mut results = Vec::new();
    let mut i = 0;
    while i + 3 < data.len() {
        if data[i] == 0xFF && data[i + 1] == 0xD8 && data[i + 2] == 0xFF {
            if let Some(eoi) = find_jpeg_eoi(data, i) {
                let size = eoi - i + 2;
                if size > 512 {
                    results.push((i, size));
                }
                i = eoi + 2;
                continue;
            }
        }
        i += 1;
    }
    results.sort_by_key(|&(_, size)| size);
    results
}

/// Walk JPEG markers from `start` to locate the EOI (0xFF 0xD9).
/// Returns the byte offset of the EOI, or None if not found.
fn find_jpeg_eoi(data: &[u8], start: usize) -> Option<usize> {
    let mut pos = start + 2; // skip SOI
    while pos + 1 < data.len() {
        if data[pos] != 0xFF {
            pos += 1;
            continue;
        }
        let marker_byte = *data.get(pos + 1)?;
        match marker_byte {
            0x00 | 0xFF => { pos += 1; }  // stuffed / fill byte
            0xD9 => return Some(pos),      // EOI
            0xD8 => return None,           // unexpected nested SOI
            0xD0..=0xD7 => { pos += 2; }  // RST (no length field)
            _ => {
                let len = if pos + 3 < data.len() {
                    u16::from_be_bytes([data[pos + 2], data[pos + 3]]) as usize
                } else {
                    return None;
                };
                if len < 2 { return None; }
                pos += 2 + len;
            }
        }
    }
    None
}
